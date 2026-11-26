#!/usr/bin/env bash
# Fetches the sherpa-onnx and ONNX Runtime iOS xcframeworks into ios/Packages/SuflyorKit/Vendor/, pinned to the
# version the Android app uses (sherpa-onnx v1.13.8) and verified by SHA-256 before anything is unpacked.
#
#   ios/scripts/fetch-sherpa-onnx.sh              install (does nothing when the pinned version is already there)
#   ios/scripts/fetch-sherpa-onnx.sh --print-sha  download both zips and print their SHA-256 (first run, on a Mac)
#   ios/scripts/fetch-sherpa-onnx.sh --force      install again even when the marker says it is up to date
#
# Dev tool only: the app itself has no network code. Works on macOS (shasum) and Linux (sha256sum).
set -euo pipefail

SHERPA_VERSION="1.13.8"
SHERPA_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v${SHERPA_VERSION}-ios-static.xcframework.zip"
# SwiftPM's "checksum" of a binaryTarget zip is the SHA-256 of the zip. This value is copied from sherpa-onnx's own
# Package.swift at tag v1.13.8 (target SherpaOnnxIOS), not computed here: confirm it once with --print-sha.
SHERPA_SHA256="6b8e769cb153343270fdccbe92e3b3db0d1c421d67fa0989ab01fdf5b2fcf2de"

# The ONNX Runtime that sherpa-onnx v1.13.8 builds against (SHERPA_ONNX_ONNXRUNTIME_VERSION in its build-ios.sh).
ORT_VERSION="1.28.2"
ORT_URL="https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ORT_VERSION}/onnxruntime-ios-static-xcframework-${ORT_VERSION}.xcframework.zip"
# Empty on purpose: GitHub release downloads were blocked where this script was written, so the hash could not be
# learned. Run --print-sha on a Mac and paste the value here. Until then the script refuses to install.
ORT_SHA256="2c2299acbb461d26d4bac4bc85985d40e7c7177ed6072703ae0846d88b0b4599"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
vendor="$here/../Packages/SuflyorKit/Vendor"
marker="$vendor/.sherpa-onnx-installed"
expected_marker="sherpa-onnx=${SHERPA_VERSION}:${SHERPA_SHA256} onnxruntime=${ORT_VERSION}:${ORT_SHA256}"

mode="install"
force=0
for arg in "$@"; do
  case "$arg" in
    --print-sha) mode="print" ;;
    --force) force=1 ;;
    -h|--help) sed -n "2,9p" "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

download() { # url, destination
  curl --fail --location --silent --show-error --retry 3 --output "$2" "$1"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ "$mode" = "print" ]; then
  echo "Downloading sherpa-onnx ${SHERPA_VERSION} and ONNX Runtime ${ORT_VERSION} to compute their SHA-256..."
  download "$SHERPA_URL" "$tmp/sherpa.zip"
  download "$ORT_URL" "$tmp/ort.zip"
  sherpa_hash="$(sha256_of "$tmp/sherpa.zip")"
  ort_hash="$(sha256_of "$tmp/ort.zip")"
  echo
  echo "Paste these into $(basename "${BASH_SOURCE[0]}"):"
  echo "SHERPA_SHA256=\"$sherpa_hash\""
  echo "ORT_SHA256=\"$ort_hash\""
  if [ -n "$SHERPA_SHA256" ] && [ "$sherpa_hash" != "$SHERPA_SHA256" ]; then
    echo "WARNING: the sherpa-onnx zip differs from the pinned SHA-256 ($SHERPA_SHA256)." >&2
  fi
  exit 0
fi

if [ -z "$SHERPA_SHA256" ] || [ -z "$ORT_SHA256" ]; then
  echo "Refusing to install: a SHA-256 is not pinned in $(basename "${BASH_SOURCE[0]}")." >&2
  [ -z "$SHERPA_SHA256" ] && echo "  SHERPA_SHA256 is empty." >&2
  [ -z "$ORT_SHA256" ] && echo "  ORT_SHA256 is empty." >&2
  echo "Run '$0 --print-sha' on a Mac, check the values against the release pages, and paste them into the script." >&2
  exit 2
fi

if [ "$force" -eq 0 ] && [ -f "$marker" ] && [ "$(cat "$marker")" = "$expected_marker" ] \
   && [ -d "$vendor/sherpa-onnx.xcframework" ] && [ -d "$vendor/onnxruntime.xcframework" ]; then
  echo "sherpa-onnx ${SHERPA_VERSION} and ONNX Runtime ${ORT_VERSION} are already installed in Vendor/."
  exit 0
fi

fetch_one() { # name, url, sha256, final xcframework name
  local name="$1" url="$2" want="$3" final="$4"
  echo "Downloading $name..."
  download "$url" "$tmp/$name.zip"
  local got
  got="$(sha256_of "$tmp/$name.zip")"
  if [ "$got" != "$want" ]; then
    echo "SHA-256 mismatch for $name: expected $want, got $got. Nothing was installed." >&2
    exit 3
  fi
  mkdir -p "$tmp/$name"
  unzip -q "$tmp/$name.zip" -d "$tmp/$name"
  local found
  found="$(find "$tmp/$name" -maxdepth 2 -name '*.xcframework' -type d | head -n 1)"
  if [ -z "$found" ]; then
    echo "No .xcframework inside the $name zip." >&2
    exit 4
  fi
  mkdir -p "$tmp/staged"
  mv "$found" "$tmp/staged/$final"
}

fetch_one sherpa-onnx "$SHERPA_URL" "$SHERPA_SHA256" sherpa-onnx.xcframework
fetch_one onnxruntime "$ORT_URL" "$ORT_SHA256" onnxruntime.xcframework

# Both verified: replace the old ones.
mkdir -p "$vendor"
rm -rf "$vendor/sherpa-onnx.xcframework" "$vendor/onnxruntime.xcframework"
mv "$tmp/staged/sherpa-onnx.xcframework" "$vendor/sherpa-onnx.xcframework"
mv "$tmp/staged/onnxruntime.xcframework" "$vendor/onnxruntime.xcframework"
printf '%s\n' "$expected_marker" > "$marker"
echo "Installed sherpa-onnx ${SHERPA_VERSION} and ONNX Runtime ${ORT_VERSION} into $vendor"
