#!/usr/bin/env bash
# Bedrock delete — empty a bucket (and optionally remove it).
#
# Only the root key can delete: the publisher, consumer and ingest keys are
# write/read only on purpose. So this runs inside the mc container (the
# `bootstrap` service in compose.yaml), which already carries the root
# credentials, and needs no tooling on the host beyond Docker.
#
#   scripts/delete_objects.sh <bucket> [options]
#
#   --versions       also delete every old version (permanent; without it the
#                    bucket keeps recoverable versions behind delete markers)
#   --remove-bucket  remove the bucket itself afterwards (implies --versions)
#   --dry-run        list what would be deleted, delete nothing
#   --yes            skip the confirmation prompt
#
# Removing a bucket here does not touch bootstrap/buckets.conf: delete its line
# there too, or the next `make bootstrap` recreates the bucket.
#
# The same file is both halves: on the host it validates, confirms and starts
# the container; inside the container (BEDROCK_IN_CONTAINER=1) it does the
# deleting. The mc image has no sed/awk/grep, so that half is bash builtins.
set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()   { red "ERROR: $*"; exit 1; }

mc() { command mc --no-color "$@"; }

# ── Inside the container ────────────────────────────────────────────────────
if [[ ${BEDROCK_IN_CONTAINER:-} == 1 ]]; then
    : "${BUCKET:?}" "${RUSTFS_INTERNAL_ENDPOINT:?}" "${RUSTFS_ROOT_USER:?}" "${RUSTFS_ROOT_PASSWORD:?}"
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
    # mc writes its config (which contains the root secret) into scratch.
    export MC_CONFIG_DIR="$WORK/.mc"

    mc alias set bedrock "$RUSTFS_INTERNAL_ENDPOINT" "$RUSTFS_ROOT_USER" "$RUSTFS_ROOT_PASSWORD" >/dev/null
    mc stat "bedrock/$BUCKET" >/dev/null 2>&1 || die "bucket '$BUCKET' does not exist"

    rm_args=(--recursive --force)
    [[ ${WITH_VERSIONS:-0} != 1 ]] || rm_args+=(--versions)

    if [[ ${DRY_RUN:-0} == 1 ]]; then
        step "Dry run: would delete from $BUCKET"
        mc rm "${rm_args[@]}" --dry-run "bedrock/$BUCKET"
        exit 0
    fi

    step "Deleting objects in $BUCKET"
    mc rm "${rm_args[@]}" "bedrock/$BUCKET"

    if [[ ${REMOVE_BUCKET:-0} == 1 ]]; then
        step "Removing bucket $BUCKET"
        mc rb --force "bedrock/$BUCKET"
        green "Bucket $BUCKET removed. Remove its line from bootstrap/buckets.conf too."
    else
        green "Bucket $BUCKET emptied."
    fi
    exit 0
fi

# ── On the host ─────────────────────────────────────────────────────────────
usage() { sed -n '2,19p' "${BASH_SOURCE[0]}" | cut -c3-; exit "${1:-0}"; }

bucket=""
versions=0 remove_bucket=0 dry_run=0 assume_yes=0
while (($#)); do
    case $1 in
        --versions)      versions=1 ;;
        --remove-bucket) remove_bucket=1 ;;
        --dry-run)       dry_run=1 ;;
        --yes|-y)        assume_yes=1 ;;
        -h|--help)       usage 0 ;;
        -*)              red "unknown option: $1"; usage 1 ;;
        *)               [[ -z $bucket ]] || die "only one bucket per run"; bucket=$1 ;;
    esac
    shift
done

[[ -n $bucket ]] || { red "missing <bucket>"; usage 1; }
# S3 bucket naming: lowercase letters, digits, dots and hyphens, 3-63 chars.
[[ $bucket =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "'$bucket' is not a valid bucket name"
((! remove_bucket)) || versions=1

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
[[ -f .env ]] || die "no .env in $repo_root (run: make secrets)"

if ((! dry_run && ! assume_yes)); then
    what="ALL objects"
    ((! versions)) || what="ALL objects AND ALL old versions (permanent)"
    ((! remove_bucket)) || what="$what, then the bucket itself"
    printf '\033[31mThis deletes %s in %s.\033[0m\n' "$what" "$bucket"
    read -r -p "Type the bucket name to confirm: " reply
    [[ $reply == "$bucket" ]] || { echo "Aborted; nothing was deleted."; exit 1; }
fi

docker compose --profile bootstrap run --rm -T \
    -e BEDROCK_IN_CONTAINER=1 \
    -e BUCKET="$bucket" \
    -e WITH_VERSIONS="$versions" \
    -e REMOVE_BUCKET="$remove_bucket" \
    -e DRY_RUN="$dry_run" \
    -v "$repo_root/scripts/delete_objects.sh:/scripts/delete_objects.sh:ro" \
    --entrypoint /bin/bash \
    bootstrap /scripts/delete_objects.sh
