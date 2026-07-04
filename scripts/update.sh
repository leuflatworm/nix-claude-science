#!/usr/bin/env bash
# Mirrors the resolution logic in Anthropic's own
# install-claude-science.sh (stable pointer -> sha8 -> manifest.json),
# and rewrites release.json with the current version/sha8/sha256 values.
#
# Run from the repo root: ./scripts/update.sh
set -euo pipefail

BASE_URL="https://storage.googleapis.com/operon-dist-cf94a20e-f71c-413c-bd00-9e12b1fedf59/operon-releases"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/release.json"

command -v jq >/dev/null 2>&1 || { echo "update.sh: jq is required" >&2; exit 1; }

sha8=$(curl -fsS --proto '=https' --tlsv1.2 "$BASE_URL/stable")
if [[ ! "$sha8" =~ ^[0-9a-f]{8}$ ]]; then
  echo "update.sh: unexpected content for stable pointer: '$sha8'" >&2
  exit 1
fi

manifest=$(curl -fsS --proto '=https' --tlsv1.2 "$BASE_URL/$sha8/manifest.json")

version=$(jq -r '.version' <<<"$manifest")
linux_x64=$(jq -r '.sha256["linux-x64"]' <<<"$manifest")
darwin_arm64=$(jq -r '.sha256["darwin-arm64"]' <<<"$manifest")
darwin_x64=$(jq -r '.sha256["darwin-x64"]' <<<"$manifest")

for name in "$linux_x64" "$darwin_arm64" "$darwin_x64"; do
  if [[ ! "$name" =~ ^[a-f0-9]{64}$ ]]; then
    echo "update.sh: manifest for $sha8 is missing an expected sha256 entry" >&2
    exit 1
  fi
done

jq -n \
  --arg version "$version" \
  --arg sha8 "$sha8" \
  --arg linux_x64 "$linux_x64" \
  --arg darwin_arm64 "$darwin_arm64" \
  --arg darwin_x64 "$darwin_x64" \
  '{
     version: $version,
     sha8: $sha8,
     sha256: {
       "x86_64-linux": $linux_x64,
       "aarch64-darwin": $darwin_arm64,
       "x86_64-darwin": $darwin_x64
     }
   }' > "$OUT"

echo "release.json updated -> version $version ($sha8)"
