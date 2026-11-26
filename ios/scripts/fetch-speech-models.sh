#!/usr/bin/env bash
# Downloads the bundled ru/en/tr speech models for the iOS "full" build (about 155 MB, not stored in git).
# The list (URL + SHA-256) is tools/speech-assets.json, kept in step with app/build.gradle.kts by
# tools/ios/check_speech_assets.py. Idempotent: files that already match their checksum are skipped.
#
# Usage: ios/scripts/fetch-speech-models.sh [--check]
#   --check   only verify the files that are present, download nothing (exit 1 if any is missing or wrong)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="$ROOT/tools/speech-assets.json"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; } # same on macOS and Linux (perl shasum)

# python3 is on every macOS with the Xcode command line tools; it avoids needing jq.
LIST="$(python3 - "$MANIFEST" <<'PY'
import json, sys
for a in json.load(open(sys.argv[1], encoding="utf-8"))["assets"]:
    print("\t".join((a["path"], a["sha256"], a["url"])))
PY
)"

fail=0
while IFS=$'\t' read -r rel sha url; do
  [ -n "$rel" ] || continue
  target="$ROOT/$rel"
  if [ -f "$target" ] && [ "$(sha256_of "$target")" = "$sha" ]; then
    echo "ok       $rel"
    continue
  fi
  if [ "$CHECK_ONLY" = 1 ]; then
    echo "MISSING  $rel" >&2
    fail=1
    continue
  fi
  mkdir -p "$(dirname "$target")"
  part="$target.part"
  echo "download $rel"
  # Retries cover flaky CI networks; --fail turns HTTP errors into a non-zero exit.
  curl --fail --location --silent --show-error --retry 4 --retry-delay 3 --retry-all-errors \
    --connect-timeout 30 --output "$part" "$url"
  got="$(sha256_of "$part")"
  if [ "$got" != "$sha" ]; then
    rm -f "$part"
    echo "checksum mismatch for $rel: expected $sha, got $got" >&2
    exit 1
  fi
  mv -f "$part" "$target"
done <<< "$LIST"

exit "$fail"
