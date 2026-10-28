#!/usr/bin/env bash
# Push the current build to the public cache (mesh-agents-cache.kleinbem.dev,
# an R2 bucket) and delete everything else in it, so it holds exactly one
# build. Only paths cache.nixos.org doesn't have stay.
#
# Env: CACHE_STORE (s3://… store URL), CACHE_SIGNING_KEY, and the S3
# credentials as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.
# Args: the flake's packages to push, e.g. `.#mesh-llm .#skippy`.
set -euo pipefail

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
  echo "refusing: over the $((limit_bytes / 1024 / 1024 / 1024)) GiB limit that keeps the bucket in R2's free tier" >&2
  exit 1
fi

# A binary cache only takes a path whose dependencies it already has, so the
# whole closure goes up; the cleanup below drops what cache.nixos.org serves.
nix copy --to "$store" "${push[@]}"

# What the current build needs: nix-cache-info, its narinfos and their NARs.
{
  echo nix-cache-info
  nix path-info --store "$CACHE_STORE" --json "${push[@]}" |
    jq -r "$infos"' | (.path | ltrimstr("/nix/store/") | split("-")[0] + ".narinfo"), .url'
} | sort -u >"$work/keep"

s3 list-objects-v2 --bucket "$bucket" --query 'Contents[].Key' --output text |
  tr '\t' '\n' | grep -v '^None$' | sort -u >"$work/present"
comm -23 "$work/present" "$work/keep" >"$work/stale"
echo "deleting $(wc -l <"$work/stale") objects of older builds"
while read -r key; do
  s3 delete-object --bucket "$bucket" --key "$key" >/dev/null
done <"$work/stale"
