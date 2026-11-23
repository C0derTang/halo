#!/usr/bin/env bash
# Calibrate MatchPolicy thresholds for the face model on the PUBLIC LFW benchmark (macOS only).
#
# Downloads LFW (Labeled Faces in the Wild) and its standard `pairs.txt` into the gitignored
# Models/calibration/, verifies SHA-256, then runs `halo-calibrate run`. The dataset is NEVER
# committed or redistributed; provenance and license notes are in docs/MODELS.md. Never point
# halo-calibrate at personal photos.
#
# Usage: ./scripts/calibrate.sh [--download-only] [extra halo-calibrate options]
#   e.g. ./scripts/calibrate.sh --gallery-sizes 10,50,200 --frames 10
#
# Output: the Markdown results table on stdout and in Models/calibration/report.md (paste it into
# docs/MODELS.md). Skips (exit 0) when the model is absent: run scripts/fetch-models.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "$(uname)" == "Darwin" ]] || { echo "calibrate.sh: macOS only"; exit 0; }

DATA_DIR="Models/calibration"
MODEL="Models/HaloFaceEmbedder.mlmodelc"

# LFW via the figshare mirror scikit-learn uses (sklearn.datasets.fetch_lfw_pairs); the original
# vis-www.cs.umass.edu host is often unreachable. Checksums match scikit-learn's.
PAIRS_URL="https://ndownloader.figshare.com/files/5976006"
PAIRS_SHA256="ea42330c62c92989f9d7c03237ed5d591365e89b3e649747777b70e692dc1592"
LFW_URL="https://ndownloader.figshare.com/files/5976018"
LFW_SHA256="055f7d9c632d7370e6fb4afc7468d40f970c34a80d4c6f50ffec63f5a8d536c0"

DOWNLOAD_ONLY=0
if [[ "${1:-}" == "--download-only" ]]; then DOWNLOAD_ONLY=1; shift; fi

fetch() {
  local url="$1" out="$2" expected="$3" actual
  if [[ ! -f "$out" ]]; then
    curl --fail --location --retry 3 --output "$out.partial" "$url"
    mv "$out.partial" "$out"
  fi
  actual="$(shasum -a 256 "$out" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "!! SHA-256 mismatch for $out (expected $expected, got $actual)" >&2
    rm -f "$out"
    exit 1
  fi
  echo "ok  $out ($actual)"
}

mkdir -p "$DATA_DIR"
echo "== 1/2 download + verify LFW"
fetch "$PAIRS_URL" "$DATA_DIR/pairs.txt" "$PAIRS_SHA256"
fetch "$LFW_URL" "$DATA_DIR/lfw.tgz" "$LFW_SHA256"
if [[ ! -d "$DATA_DIR/lfw" ]]; then
  tar -xzf "$DATA_DIR/lfw.tgz" -C "$DATA_DIR"
fi
echo "ok  $DATA_DIR/lfw ($(find "$DATA_DIR/lfw" -name '*.jpg' | wc -l | tr -d ' ') images)"
[[ "$DOWNLOAD_ONLY" == 1 ]] && { echo "== done (download only)"; exit 0; }

if [[ ! -d "$MODEL" ]]; then
  echo "calibrate.sh: skipped: no model at $MODEL (run scripts/fetch-models.sh)"
  exit 0
fi

echo "== 2/2 halo-calibrate"
swift run -c release --package-path Packages/HaloKit halo-calibrate run \
  --model "$MODEL" --pairs "$DATA_DIR/pairs.txt" --images "$DATA_DIR/lfw" \
  --report "$DATA_DIR/report.md" "$@"
