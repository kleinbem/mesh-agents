#!/usr/bin/env bash
# .github/scripts/push-cache.sh against a throwaway SeaweedFS S3: two projects
# share the bucket, and a project's new push drops its own old build but
# nothing another project's roots list. Needs nix, weed, aws, curl, jq.
# Run: nix shell nixpkgs#seaweedfs nixpkgs#awscli2 -c tests/push-cache.sh
set -euo pipefail

push_cache=$(realpath "$(dirname "$0")/../.github/scripts/push-cache.sh")
work=$(mktemp -d)
weed_pid=
cleanup() {
  if [ -n "$weed_pid" ]; then
    kill "$weed_pid" 2>/dev/null || true
    wait "$weed_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

port=18333
mkdir "$work/weed"
weed server -ip=127.0.0.1 -ip.bind=127.0.0.1 -dir="$work/weed" -s3 -s3.port=$port -master.port=19333 \
  -volume.port=18080 -filer.port=18888 >"$work/weed.log" 2>&1 &
weed_pid=$!
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
endpoint=http://127.0.0.1:$port
# The S3 port answers before the filer behind it is ready.
for i in $(seq 60); do
  aws --endpoint-url "$endpoint" --region us-east-1 s3api create-bucket \
    --bucket cache >/dev/null 2>&1 && break
  [ "$i" -lt 60 ] || { cat "$work/weed.log" >&2; exit 1; }
  sleep 1
done
export CACHE_STORE="s3://cache?endpoint=$endpoint&region=us-east-1"
nix key generate-secret --key-name test >"$work/key"
CACHE_SIGNING_KEY=$(cat "$work/key")
export CACHE_SIGNING_KEY
# Everything is deletable at once: the test can't wait a day.
export CACHE_GRACE="0 seconds"

# Store paths cache.nixos.org can't have: a fresh nonce each run.
nonce=$(date +%s%N)
drv() {
  echo "derivation { name = \"push-cache-$1\"; system = builtins.currentSystem;
    builder = \"/bin/sh\"; args = [ \"-c\" \"echo $1 $nonce > \$out\" ]; }"
}
build() { nix build --no-link --print-out-paths --impure --expr "$(drv "$1")"; }
push() { CACHE_PROJECT=$1 "$push_cache" --impure --expr "$(drv "$2")"; }
a1=$(build a1)
b1=$(build b1)
a2=$(build a2)

# Ask the bucket, not Nix's narinfo cache (as the script does).
cached() {
  NIX_CONFIG="narinfo-cache-positive-ttl = 0
narinfo-cache-negative-ttl = 0" nix path-info --store "$CACHE_STORE" "$1" >/dev/null 2>&1
}
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

push a a1
aws --endpoint-url "$endpoint" --region us-east-1 s3api get-object --bucket cache \
  --key nix-cache-info "$work/info" >/dev/null || fail "no nix-cache-info after the first push"
grep -qx 'StoreDir: /nix/store' "$work/info" || fail "nix-cache-info: $(cat "$work/info")"
push b b1
cached "$a1" || fail "a1 missing after project a's first push"
cached "$b1" || fail "b1 missing after project b's push"

sleep 1
push a a2
cached "$a2" || fail "a2 missing after project a's second push"
cached "$b1" || fail "b1 (project b's build) was deleted by project a's push"
cached "$a1" && fail "a1 (project a's old build) is still in the cache"
aws --endpoint-url "$endpoint" --region us-east-1 s3api head-object \
  --bucket cache --key nix-cache-info >/dev/null || fail "nix-cache-info deleted by the cleanup"

# What users see: the bucket over plain HTTP (SeaweedFS serves it
# anonymously, as the public domain serves R2) is a binary cache Nix accepts.
nix store info --store "$endpoint/cache" >/dev/null || fail "Nix doesn't accept the bucket as a binary cache"

echo "push-cache: ok"
