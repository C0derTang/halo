#!/usr/bin/env bash
# Fetch, verify and convert the face-embedding model into the gitignored Models/ directory.
#
# Weights are NEVER committed (public repo) or redistributed. Provenance, license and checksums are
# recorded in docs/MODELS.md; keep the constants below and that file in sync.
#
# Usage: ./scripts/fetch-models.sh [--download-only]
#   --download-only   fetch + verify the ONNX weights, skip CoreML conversion/compilation.
#
# Output:
#   Models/w600k_mbf.onnx              verified source weights
#   Models/HaloFaceEmbedder.mlpackage  CoreML ML program (input "input" 1x3x112x112, output "embedding")
#   Models/HaloFaceEmbedder.mlmodelc   compiled model loaded by CoreMLFaceEmbedder
#
# Conversion needs `uv` (https://docs.astral.sh/uv/) to run a pinned, throwaway Python env with
# torch + onnx2torch + coremltools; coremltools no longer converts ONNX directly. Without uv, the
# script prints the manual commands and stops after verifying the download.
set -euo pipefail
cd "$(dirname "$0")/.."

MODELS_DIR="Models"
CACHE_DIR="$MODELS_DIR/.cache"

# InsightFace buffalo_sc pack, release v0.7: MobileFaceNet trained on WebFace600K (512-d ArcFace).
ZIP_URL="https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_sc.zip"
ZIP_SHA256="57d31b56b6ffa911c8a73cfc1707c73cab76efe7f13b675a05223bf42de47c72"
ONNX_NAME="w600k_mbf.onnx"
ONNX_SHA256="9cc6e4a75f0e2bf0b1aed94578f144d15175f357bdc05e815e5c4a02b319eb4f"
OUT_NAME="HaloFaceEmbedder"

DOWNLOAD_ONLY=0
[[ "${1:-}" == "--download-only" ]] && DOWNLOAD_ONLY=1

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

verify() {
  local file="$1" expected="$2" actual
  actual="$(sha256_of "$file")"
  if [[ "$actual" != "$expected" ]]; then
    echo "!! SHA-256 mismatch for $file" >&2
    echo "   expected $expected" >&2
    echo "   actual   $actual" >&2
    rm -f "$file"
    exit 1
  fi
  echo "ok  $file ($actual)"
}

mkdir -p "$CACHE_DIR"

echo "== 1/3 download + verify"
ZIP_PATH="$CACHE_DIR/buffalo_sc.zip"
if [[ ! -f "$ZIP_PATH" ]]; then
  curl --fail --location --retry 3 --output "$ZIP_PATH.partial" "$ZIP_URL"
  mv "$ZIP_PATH.partial" "$ZIP_PATH"
fi
verify "$ZIP_PATH" "$ZIP_SHA256"

ONNX_PATH="$MODELS_DIR/$ONNX_NAME"
unzip -o -q -j "$ZIP_PATH" "$ONNX_NAME" -d "$MODELS_DIR"
verify "$ONNX_PATH" "$ONNX_SHA256"

if [[ "$DOWNLOAD_ONLY" == 1 ]]; then
  echo "== done (download only)"
  exit 0
fi

echo "== 2/3 convert ONNX -> CoreML"
PACKAGE_PATH="$MODELS_DIR/$OUT_NAME.mlpackage"
if ! command -v uv >/dev/null; then
  cat >&2 <<EOF
!! uv not found; convert manually (Python 3.12):
   python3.12 -m venv .venv-models && . .venv-models/bin/activate
   pip install torch==2.5.1 onnx==1.17.0 onnx2torch==1.5.15 coremltools==8.3.0 numpy==1.26.4
   python - <<'PY'   # body: the CONVERT_PY heredoc in this script
   PY
   xcrun coremlcompiler compile $PACKAGE_PATH $MODELS_DIR
EOF
  exit 1
fi

rm -rf "$PACKAGE_PATH"
# Input is a float tensor, RGB, NCHW, normalized as (pixel - 127.5) / 127.5 by CoreMLFaceEmbedder
# (InsightFace w600k preprocessing). Output is the raw 512-d embedding; the app L2-normalizes it.
uv run --quiet --no-project --python 3.12 \
  --with torch==2.5.1 --with onnx==1.17.0 --with onnx2torch==1.5.15 \
  --with coremltools==8.3.0 --with numpy==1.26.4 \
  python - "$ONNX_PATH" "$PACKAGE_PATH" <<'CONVERT_PY'
import sys

import coremltools as ct
import numpy as np
import onnx
import torch
from onnx2torch import convert

onnx_path, out_path = sys.argv[1], sys.argv[2]
torch_model = convert(onnx.load(onnx_path)).eval()
example = torch.rand(1, 3, 112, 112) * 2 - 1
traced = torch.jit.trace(torch_model, example)
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=(1, 3, 112, 112), dtype=np.float32)],
    outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT32,
    minimum_deployment_target=ct.target.iOS18,
)
mlmodel.short_description = "InsightFace w600k_mbf (buffalo_sc v0.7) face embedder, 512-d"
mlmodel.save(out_path)

# Parity check: CoreML output must match the PyTorch reference on a random input.
with torch.no_grad():
    reference = torch_model(example).numpy().reshape(-1)
converted = mlmodel.predict({"input": example.numpy()})["embedding"].reshape(-1)
cosine = float(np.dot(reference, converted) / (np.linalg.norm(reference) * np.linalg.norm(converted)))
print(f"ok  {out_path} (dim={converted.size}, parity cosine={cosine:.6f})")
if converted.size != 512 or cosine < 0.999:
    sys.exit("!! conversion parity check failed")
CONVERT_PY

echo "== 3/3 compile"
rm -rf "$MODELS_DIR/$OUT_NAME.mlmodelc"
xcrun coremlcompiler compile "$PACKAGE_PATH" "$MODELS_DIR" >/dev/null
echo "ok  $MODELS_DIR/$OUT_NAME.mlmodelc"
echo "== done"
