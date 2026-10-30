#!/usr/bin/env bash
# Push the current build to the public cache (cache.kleinbem.dev, an R2
# bucket shared by several projects) and drop this project's older builds.
# Only paths cache.nixos.org doesn't have stay.
#
# Each project lists what its current build uses in roots/<project>; an
# object no roots list mentions is deleted, once it is a day old (so a
# project's upload is safe while its push is still running).
#
# Env: CACHE_STORE (s3://… store URL), CACHE_SIGNING_KEY, the S3 credentials
# as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, and CACHE_PROJECT (default:
# the GitHub repository's name). CACHE_GRACE (default "1 day") is the age
# below which nothing is deleted.
# Args: the flake's packages to push, e.g. `.#mesh-llm .#skippy`.
set -euo pipefail

project=${CACHE_PROJECT:-${GITHUB_REPOSITORY#*/}}
limit_bytes=$((8 * 1024 * 1024 * 1024))
# Ask the bucket, not Nix's local memory of it: objects get deleted below.
export NIX_CONFIG="narinfo-cache-positive-ttl = 0
narinfo-cache-negative-ttl = 0"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

printf '%s\n' "$CACHE_SIGNING_KEY" >"$work/signing-key"
store="$CACHE_STORE&secret-key=$work/signing-key&compression=zstd"
bucket=${CACHE_STORE#s3://}
bucket=${bucket%%\?*}
endpoint=$(sed -n 's/.*[?&]endpoint=\([^&]*\).*/\1/p' <<<"$CACHE_STORE")
s3() { aws --endpoint-url "$endpoint" --region auto s3api "$@"; }

# `nix path-info --json` gives an array or, in newer Nix, an object keyed by
# path; this yields each path's info with its path either way.
infos='if type == "array" then .[] else to_entries[] | .value + {path: .key} end'

mapfile -t outs < <(nix build --no-link --print-out-paths "$@")
nix path-info --recursive "${outs[@]}" | sort -u >"$work/closure"
mapfile -t closure <"$work/closure"
# The paths cache.nixos.org has (its .narinfo exists); the rest is ours to
# serve.
on_upstream() {
  local hash
  hash=$(basename "$1" | cut -d- -f1)
  if curl -fsI -o /dev/null "https://cache.nixos.org/$hash.narinfo"; then echo "$1"; fi
}
export -f on_upstream
# shellcheck disable=SC2016 # expanded by the inner bash
printf '%s\n' "${closure[@]}" | xargs -P 16 -n 1 bash -c 'on_upstream "$1"' _ |
  sort -u >"$work/upstream"
mapfile -t push < <(comm -23 "$work/closure" "$work/upstream")
echo "${#closure[@]} paths in the closure, ${#push[@]} not on cache.nixos.org"

size=$(nix path-info --json "${push[@]}" | jq "[$infos | .narSize] | add // 0")
echo "pushing $((size / 1024 / 1024)) MiB (uncompressed)"
if [ "$size" -gt "$limit_bytes" ]; then
  echo "refusing: over the $((limit_bytes / 1024 / 1024 / 1024)) GiB limit per project (R2's free tier is 10 GB for all)" >&2
  exit 1
fi

# A binary cache only takes a path whose dependencies it already has, so the
# whole closure goes up; the cleanup below drops what cache.nixos.org serves.
nix copy --to "$store" "${push[@]}"

# Nix won't use an HTTP cache without nix-cache-info ("does not appear to be
# a binary cache"), and `nix copy` to S3 doesn't write one.
if ! s3 head-object --bucket "$bucket" --key nix-cache-info >/dev/null 2>&1; then
  printf 'StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 41\n' >"$work/nix-cache-info"
  s3 put-object --bucket "$bucket" --key nix-cache-info --body "$work/nix-cache-info" \
    --content-type text/x-nix-cache-info >/dev/null
fi

# What the current build needs: its narinfos and their NARs.
nix path-info --store "$CACHE_STORE" --json "${push[@]}" |
  jq -r "$infos"' | (.path | ltrimstr("/nix/store/") | split("-")[0] + ".narinfo"), .url' |
  sort -u >"$work/root"
s3 put-object --bucket "$bucket" --key "roots/$project" --body "$work/root" >/dev/null

s3 list-objects-v2 --bucket "$bucket" --output json |
  jq -r '.Contents // [] | .[] | "\(.Key)\t\(.LastModified)"' >"$work/present"
# Everything any project's current build needs, and the cache's own files.
{
  echo nix-cache-info
  while read -r key; do
    echo "$key"
    s3 get-object --bucket "$bucket" --key "$key" "$work/other-root" >/dev/null
    cat "$work/other-root"
  done < <(cut -f1 "$work/present" | grep '^roots/')
} | sort -u >"$work/keep"

cutoff=$(date -u -d "${CACHE_GRACE:-1 day} ago" +%s)
while IFS=$'\t' read -r key modified; do
  if [ "$(date -u -d "$modified" +%s)" -lt "$cutoff" ]; then echo "$key"; fi
done <"$work/present" | sort -u | comm -23 - "$work/keep" >"$work/stale"
echo "deleting $(wc -l <"$work/stale") objects no project uses any more"
while read -r key; do
  s3 delete-object --bucket "$bucket" --key "$key" >/dev/null
done <"$work/stale"
