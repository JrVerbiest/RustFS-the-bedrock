#!/usr/bin/env bash
# Bedrock smoke test — assert that least privilege actually holds.
#
# A policy file that *says* the publisher cannot delete is worth nothing until
# something has tried to delete and been refused. This script does the trying.
# It runs inside the minio/mc container (the `smoke` service in compose.yaml).
#
# For every PUBLISHED bucket in bootstrap/buckets.conf:
#
#   publisher   CAN  put, get, list
#   publisher   CANNOT delete an object          <- protects the archive
#   publisher   CANNOT create another bucket
#   publisher   CANNOT reach another bucket
#   consumer    CAN  get, list
#   consumer    CANNOT put                       <- read-only means read-only
#   consumer    CANNOT delete
#   anonymous   CANNOT list or get               <- nothing is public
#
# For every RESTRICTED bucket:
#
#   ingest      CAN  put, get, list
#   ingest      CANNOT delete                    <- the archive is append-only
#   ingest      CANNOT reach a published bucket
#   every consumer key of every published bucket CANNOT read it
#   anonymous   CANNOT list or get
#
# That last one is the assertion that matters most: if any credential a reader
# holds can reach a restricted bucket, the whole boundary is decoration.
#
# Exit status is non-zero if any of those does not hold.
set -uo pipefail

BOOTSTRAP_DIR=${BOOTSTRAP_DIR:-/bootstrap}
BUCKETS_CONF=${BUCKETS_CONF:-$BOOTSTRAP_DIR/buckets.conf}
ENDPOINT=${RUSTFS_INTERNAL_ENDPOINT:?set RUSTFS_INTERNAL_ENDPOINT}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export MC_CONFIG_DIR="$WORK/.mc"

PASSED=0
FAILED=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILED=$((FAILED + 1)); }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

mc() { command mc --no-color "$@"; }

# assert_allow / assert_deny wrap a command and check it succeeded / was
# refused. Output is captured and only shown when the expectation is violated,
# so a green run stays readable. Every line says which outcome was expected, so
# a green run cannot be misread as "deleting worked".
assert_allow() {
    local what=$1; shift
    if out=$("$@" 2>&1); then
        pass "allowed:  $what"
    else
        fail "allowed:  $what -- expected success, got: ${out##*$'\n'}"
    fi
}
assert_deny() {
    local what=$1; shift
    if out=$("$@" 2>&1); then
        fail "refused:  $what -- expected to be REFUSED, but it SUCCEEDED"
    elif [[ $out == *Denied* || $out == *denied* || $out == *"Insufficient permissions"* ]]; then
        pass "refused:  $what"
    else
        # It failed, but not because the policy refused it. A connection error
        # counts as a failed assertion: this test exists to prove the policy
        # works, and an unreachable store proves nothing.
        fail "refused:  $what -- failed, but not with an authorization error: ${out##*$'\n'}"
    fi
}

env_prefix() { local b=${1//-/_}; printf '%s' "${b^^}"; }

declare -a BUCKETS=() CLASSES=() EXTRA_CONSUMERS=()
while read -r bucket _days class extras _rest; do
    [[ -n ${bucket-} && ${bucket:0:1} != "#" ]] || continue
    BUCKETS+=("$bucket")
    CLASSES+=("${class:-published}")
    EXTRA_CONSUMERS+=("${extras-}")
done < "$BUCKETS_CONF"

# Every reader of a published bucket: the default consumer plus each name in
# the fourth buckets.conf column. Each must be tested, or an extra key could
# silently carry more privilege than the one that is checked.
consumer_roles() {
    local extras=${1-} role
    printf 'CONSUMER'
    [[ -n $extras ]] || return
    local IFS=,
    for role in $extras; do
        [[ -n $role ]] || continue
        printf ' CONSUMER_%s' "${role^^}"
    done
}
(( ${#BUCKETS[@]} > 0 )) || { echo "no buckets declared in $BUCKETS_CONF"; exit 1; }

printf 'hello from the bedrock smoke test\n' > "$WORK/probe.txt"

mc alias set anon "$ENDPOINT" "" "" >/dev/null 2>&1
mc alias set root "$ENDPOINT" "${RUSTFS_ROOT_USER:?}" "${RUSTFS_ROOT_PASSWORD:?}" >/dev/null 2>&1

for i in "${!BUCKETS[@]}"; do
    bucket=${BUCKETS[$i]}
    class=${CLASSES[$i]}
    prefix=$(env_prefix "$bucket")

    # A bucket that is NOT this one, to prove cross-bucket isolation. With a
    # single bucket declared there is nothing to cross into, so it is skipped.
    other=""
    for candidate in "${BUCKETS[@]}"; do
        [[ $candidate == "$bucket" ]] || { other=$candidate; break; }
    done

    if [[ $class == restricted ]]; then
        ing_key="${prefix}_INGEST_KEY"; ing_secret="${prefix}_INGEST_SECRET"
        mc alias set ing "$ENDPOINT" "${!ing_key}" "${!ing_secret}" >/dev/null 2>&1

        step "$bucket [restricted] — ingest (land + read back, no delete)"
        assert_allow "put object"            mc cp "$WORK/probe.txt" "ing/$bucket/_smoke/probe.txt"
        assert_allow "list bucket"           mc ls "ing/$bucket"
        assert_allow "read back own object"  mc cat "ing/$bucket/_smoke/probe.txt"
        assert_deny  "delete object"         mc rm "ing/$bucket/_smoke/probe.txt"
        assert_deny  "create another bucket" mc mb "ing/bedrock-smoke-should-not-exist"
        [[ -z $other ]] || assert_deny "reach $other (cross-bucket isolation)" mc ls "ing/$other"

        # THE assertion. Every consumer key that exists anywhere in this store
        # must be unable to see a restricted bucket.
        step "$bucket [restricted] — no consumer key can read it"
        for j in "${!BUCKETS[@]}"; do
            [[ ${CLASSES[$j]} == published ]] || continue
            other_prefix=$(env_prefix "${BUCKETS[$j]}")
            for role in $(consumer_roles "${EXTRA_CONSUMERS[$j]}"); do
                ok="${other_prefix}_${role}_KEY"; os="${other_prefix}_${role}_SECRET"
                mc alias set foreign "$ENDPOINT" "${!ok}" "${!os}" >/dev/null 2>&1
                assert_deny "${BUCKETS[$j]} ${role,,} key cannot list it" mc ls "foreign/$bucket"
                assert_deny "${BUCKETS[$j]} ${role,,} key cannot read it" mc cat "foreign/$bucket/_smoke/probe.txt"
            done
        done
    else
        pub_key="${prefix}_PUBLISHER_KEY"; pub_secret="${prefix}_PUBLISHER_SECRET"
        mc alias set pub "$ENDPOINT" "${!pub_key}" "${!pub_secret}" >/dev/null 2>&1

        step "$bucket [published] — publisher (write + read, no delete)"
        assert_allow "put object"            mc cp "$WORK/probe.txt" "pub/$bucket/_smoke/probe.txt"
        assert_allow "list bucket"           mc ls "pub/$bucket"
        assert_allow "read back own object"  mc cat "pub/$bucket/_smoke/probe.txt"
        assert_deny  "delete object"         mc rm "pub/$bucket/_smoke/probe.txt"
        assert_deny  "create another bucket" mc mb "pub/bedrock-smoke-should-not-exist"
        [[ -z $other ]] || assert_deny "reach $other (cross-bucket isolation)" mc ls "pub/$other"

        for role in $(consumer_roles "${EXTRA_CONSUMERS[$i]}"); do
            con_key="${prefix}_${role}_KEY"; con_secret="${prefix}_${role}_SECRET"
            mc alias set con "$ENDPOINT" "${!con_key}" "${!con_secret}" >/dev/null 2>&1
            step "$bucket [published] — ${role,,} (read only)"
            assert_allow "list bucket"   mc ls "con/$bucket"
            assert_allow "read object"   mc cat "con/$bucket/_smoke/probe.txt"
            assert_deny  "write object"  mc cp "$WORK/probe.txt" "con/$bucket/_smoke/nope.txt"
            assert_deny  "delete object" mc rm "con/$bucket/_smoke/probe.txt"
            [[ -z $other ]] || assert_deny "reach $other (cross-bucket isolation)" mc ls "con/$other"
        done
    fi

    step "$bucket [$class] — anonymous (nothing)"
    assert_deny "list bucket without credentials" mc ls "anon/$bucket"
    assert_deny "read object without credentials" mc cat "anon/$bucket/_smoke/probe.txt"

    # Clean up with the root credentials — deliberately the only identity that
    # can, which is the point of the cannot-delete assertions above.
    mc rm --recursive --force --versions "root/$bucket/_smoke/" >/dev/null 2>&1
done

step "Summary"
printf '  %d passed, %d failed\n' "$PASSED" "$FAILED"
if (( FAILED > 0 )); then
    printf '\n\033[31mSMOKE TEST FAILED — the store is not enforcing least privilege.\033[0m\n'
    exit 1
fi
printf '\n\033[32mAll access-control assertions hold.\033[0m\n'
