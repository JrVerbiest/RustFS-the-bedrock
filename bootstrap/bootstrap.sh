#!/usr/bin/env bash
# Bedrock bootstrap — bring the object store to its declared state.
#
# Runs inside the minio/mc container (the `bootstrap` service in compose.yaml),
# so it needs no tooling on the host. It is idempotent: re-running reconciles
# rather than fails, which makes it safe on every deploy and in CI.
#
# For every bucket in buckets.conf it ensures:
#   1. the bucket exists
#   2. object versioning is on          (a bad write is recoverable)
#   3. anonymous access is off          (nothing is public-read, ever)
#   4. a lifecycle rule expires non-current versions after N days
#   5. the keys and policies its class calls for:
#        published   publisher (put/get/list, NO delete) + consumer (get/list)
#        restricted  ingest    (put/get/list, NO delete) and NOTHING ELSE
#
# The root credentials are used here and nowhere else.
#
# Reconciling only ever ADDS, so the run finishes with a drift report: whatever
# the store carries that buckets.conf no longer declares. It reports rather
# than deletes — revoking a credential is an operator decision.
#
# The mc image has bash but no sed/awk/grep, so everything below is bash
# builtins on purpose.
set -euo pipefail

BOOTSTRAP_DIR=${BOOTSTRAP_DIR:-/bootstrap}
BUCKETS_CONF="$BOOTSTRAP_DIR/buckets.conf"
POLICY_DIR="$BOOTSTRAP_DIR/policies"
ALIAS=bedrock
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# mc writes its config (which contains the root secret) into $HOME/.mc. Keep it
# in scratch and remove it on exit rather than in a mounted volume.
export MC_CONFIG_DIR="$WORK/.mc"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
step()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()   { red "ERROR: $*"; exit 1; }

mc() { command mc --no-color "$@"; }

# Is $1 present in the remaining arguments? Used by the drift report.
contains() {
    local needle=$1 item
    shift
    for item in "$@"; do
        [[ $item != "$needle" ]] || return 0
    done
    return 1
}

# Pull a string field out of one line of mc's --json output. No jq in this
# image, so this is parameter expansion — good enough for the flat objects mc
# emits, not a general JSON parser.
json_field() {
    local line=$1 field=$2 rest
    rest=${line#*\"$field\":\"}
    [[ $rest != "$line" ]] || return 1
    printf '%s' "${rest%%\"*}"
}

# ── Credential hygiene ───────────────────────────────────────────────────────
# This is the one place that sees every credential at once, so it is the only
# place that can check them against each other.
declare -a SEEN_SECRETS=()

# What the store SHOULD contain, compared against reality in the drift report.
declare -a WANT_BUCKETS=() WANT_POLICIES=() WANT_USERS=()

# Policies every store ships with. Not ours, not drift.
BUILTIN_POLICIES="consoleAdmin readwrite readonly writeonly diagnostics"

check_credential() {
    local name=$1 value=${2-}
    [[ -n $value ]] || die "$name is not set. Copy .env.example to .env and run 'make secrets'."
    [[ $value != *CHANGE_ME* ]] || die "$name still holds the placeholder from .env.example. Run 'make secrets'."
    (( ${#value} >= 16 )) || die "$name is ${#value} characters; 16 is the minimum. Run 'make secrets'."
    local seen
    for seen in ${SEEN_SECRETS[@]+"${SEEN_SECRETS[@]}"}; do
        [[ $seen != "$value" ]] || die "$name repeats another credential. Every key and secret must be distinct."
    done
    SEEN_SECRETS+=("$value")
}

# ── Read the desired state ───────────────────────────────────────────────────
# buckets.conf is "<bucket> <noncurrent-expiry-days> <class> [extra consumers]";
# '#' comments and blank lines ignored.
declare -a BUCKETS=() EXPIRY_DAYS=() CLASSES=() EXTRA_CONSUMERS=()
[[ -f $BUCKETS_CONF ]] || die "missing $BUCKETS_CONF"
while read -r bucket days class extras _rest; do
    [[ -n ${bucket-} ]] || continue
    [[ ${bucket:0:1} != "#" ]] || continue
    [[ -n ${days-} ]] || die "buckets.conf: '$bucket' has no expiry-days column"
    [[ $days =~ ^[0-9]+$ ]] || die "buckets.conf: '$bucket' expiry-days '$days' is not a number"
    [[ -n ${class-} ]] || die "buckets.conf: '$bucket' has no class column (published|restricted)"
    [[ $class == published || $class == restricted ]] \
        || die "buckets.conf: '$bucket' class '$class' is not 'published' or 'restricted'"
    # S3 bucket naming: lowercase letters, digits and hyphens. Enforced here so
    # a typo fails the bootstrap instead of producing a bucket nobody expects.
    [[ $bucket =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || die "buckets.conf: '$bucket' is not a valid bucket name"
    if [[ -n ${extras-} && $class != published ]]; then
        die "buckets.conf: '$bucket' is $class and cannot have extra consumers"
    fi
    BUCKETS+=("$bucket")
    EXPIRY_DAYS+=("$days")
    CLASSES+=("$class")
    EXTRA_CONSUMERS+=("${extras-}")
done < "$BUCKETS_CONF"
(( ${#BUCKETS[@]} > 0 )) || die "buckets.conf declares no buckets"

# env-var prefix for a bucket: my-data-publish -> MY_DATA_PUBLISH
env_prefix() { local b=${1//-/_}; printf '%s' "${b^^}"; }

# The roles a bucket's class calls for. A restricted bucket gets no consumer
# role at all — that absence IS the control. Extra named consumers (the fourth
# column) become roles of the form consumer_<name>: the same read-only policy,
# but a key of their own.
roles_for_class() {
    local class=$1 extras=${2-} role
    case $class in
        published)  printf 'publisher consumer' ;;
        restricted) printf 'ingest'; return ;;
        *)          die "unknown class '$class'" ;;
    esac
    [[ -n $extras ]] || return
    local IFS=,
    for role in $extras; do
        [[ -n $role ]] || continue
        [[ $role =~ ^[a-z0-9_]+$ ]] || die "buckets.conf: extra consumer '$role' must be lowercase [a-z0-9_]"
        printf ' consumer_%s' "$role"
    done
}

# Which policy template a role uses.
template_for_role() {
    case $1 in
        consumer_*) printf 'consumer' ;;
        *)          printf '%s' "$1" ;;
    esac
}

step "Checking credentials"
check_credential RUSTFS_ROOT_USER "${RUSTFS_ROOT_USER-}"
check_credential RUSTFS_ROOT_PASSWORD "${RUSTFS_ROOT_PASSWORD-}"
for i in "${!BUCKETS[@]}"; do
    p=$(env_prefix "${BUCKETS[$i]}")
    for role in $(roles_for_class "${CLASSES[$i]}" "${EXTRA_CONSUMERS[$i]}"); do
        upper=${role^^}
        for part in KEY SECRET; do
            var="${p}_${upper}_${part}"
            check_credential "$var" "${!var-}"
        done
    done
done
info "${#SEEN_SECRETS[@]} credentials present, distinct, and not placeholders"

# ── Connect ──────────────────────────────────────────────────────────────────
step "Connecting to ${RUSTFS_INTERNAL_ENDPOINT:?set RUSTFS_INTERNAL_ENDPOINT}"
mc alias set "$ALIAS" "$RUSTFS_INTERNAL_ENDPOINT" "$RUSTFS_ROOT_USER" "$RUSTFS_ROOT_PASSWORD" >/dev/null \
    || die "could not authenticate against $RUSTFS_INTERNAL_ENDPOINT with the root credentials"
info "connected"

# ── Reconcile each bucket ────────────────────────────────────────────────────
for i in "${!BUCKETS[@]}"; do
    bucket=${BUCKETS[$i]}
    days=${EXPIRY_DAYS[$i]}
    class=${CLASSES[$i]}
    prefix=$(env_prefix "$bucket")

    step "Bucket: $bucket ($class)"
    WANT_BUCKETS+=("$bucket")

    mc mb --ignore-existing "$ALIAS/$bucket" >/dev/null
    info "exists"

    mc version enable "$ALIAS/$bucket" >/dev/null
    info "versioning enabled — an overwriting write leaves the previous object recoverable"

    # Belt and braces: the default is private, but say so explicitly so a
    # bucket someone once opened up gets closed again on the next bootstrap.
    mc anonymous set none "$ALIAS/$bucket" >/dev/null
    info "anonymous access: none"

    # `ilm rule import` REPLACES the lifecycle configuration, so this is
    # idempotent. `ilm rule add` would append a duplicate rule on every run.
    cat > "$WORK/ilm.json" <<JSON
{"Rules":[{"ID":"bedrock-noncurrent-expiry","Status":"Enabled","Filter":{"Prefix":""},"NoncurrentVersionExpiration":{"NoncurrentDays":$days}}]}
JSON
    mc ilm rule import "$ALIAS/$bucket" < "$WORK/ilm.json" >/dev/null
    info "lifecycle: non-current versions expire after $days days"

    for role in $(roles_for_class "$class" "${EXTRA_CONSUMERS[$i]}"); do
        upper=${role^^}
        key_var="${prefix}_${upper}_KEY"
        secret_var="${prefix}_${upper}_SECRET"
        key=${!key_var}
        secret=${!secret_var}
        policy="${bucket}-${role//_/-}"

        # Template the bucket name into the policy. No sed in this image; bash
        # substitution does the same job and cannot be fooled by shell quoting.
        template=$(cat "$POLICY_DIR/$(template_for_role "$role").json")
        printf '%s' "${template//__BUCKET__/$bucket}" > "$WORK/$policy.json"

        mc admin policy create "$ALIAS" "$policy" "$WORK/$policy.json" >/dev/null
        mc admin user add "$ALIAS" "$key" "$secret" >/dev/null
        mc admin policy attach "$ALIAS" "$policy" --user "$key" >/dev/null 2>&1 || true
        WANT_POLICIES+=("$policy")
        WANT_USERS+=("$key")
        info "$role key '$key' -> policy '$policy'"
    done
    [[ $class != restricted ]] || info "no consumer key exists for this bucket — that is the point"
done

# ── Drift ────────────────────────────────────────────────────────────────────
# Everything above only ADDS. Rename or retire a bucket and its keys stay
# behind, still enabled — and `make test` cannot see them, because it iterates
# buckets.conf and a retired key is precisely what is no longer in there.
step "Checking for drift"
DRIFT=0

while IFS= read -r line; do
    [[ -n $line ]] || continue
    bucket=$(json_field "$line" key) || continue
    bucket=${bucket%/}
    [[ -n $bucket ]] || continue
    contains "$bucket" ${WANT_BUCKETS[@]+"${WANT_BUCKETS[@]}"} && continue
    red "  undeclared bucket:  $bucket"
    DRIFT=$((DRIFT + 1))
done < <(mc ls "$ALIAS" --json)

while IFS= read -r line; do
    [[ -n $line ]] || continue
    policy=$(json_field "$line" policy) || continue
    [[ -n $policy ]] || continue
    contains "$policy" $BUILTIN_POLICIES && continue
    contains "$policy" ${WANT_POLICIES[@]+"${WANT_POLICIES[@]}"} && continue
    red "  undeclared policy:  $policy"
    DRIFT=$((DRIFT + 1))
done < <(mc admin policy list "$ALIAS" --json)

while IFS= read -r line; do
    [[ -n $line ]] || continue
    user=$(json_field "$line" accessKey) || continue
    [[ -n $user ]] || continue
    contains "$user" ${WANT_USERS[@]+"${WANT_USERS[@]}"} && continue
    red "  undeclared key:     $user  (still enabled)"
    DRIFT=$((DRIFT + 1))
done < <(mc admin user list "$ALIAS" --json)

if (( DRIFT == 0 )); then
    info "none — the store matches buckets.conf exactly"
else
    red "
$DRIFT item(s) above exist in the store but are not declared in buckets.conf.
Nothing was deleted. An undeclared key still works and is not covered by
'make test', so retire what you no longer want, with the root credentials:

  mc admin user remove <alias> <accessKey>
  mc admin policy remove <alias> <policy>
  mc rb --force <alias>/<bucket>     # deletes the bucket AND everything in it
"
fi

step "Result"
mc ls "$ALIAS"

green "
Bootstrap complete. Every bucket is versioned, private, and has only the keys
its class calls for: published buckets get a no-delete publisher and a
read-only consumer, restricted buckets get an ingest key and no reader.

Verify least privilege actually holds:   make test
"
