# Face embedding models

Weights are never committed (public repo). `scripts/fetch-models.sh` downloads and converts them into
the gitignored `Models/` directory, which the app bundles at build time.

| Model ID | Dimension | Source URL | License | Use allowed | Calibrated `MatchPolicy` |
|----------|-----------|------------|---------|-------------|--------------------------|
| `insightface-w600k_mbf-buffalo_sc-v0.7` | 512 | [buffalo_sc.zip @ insightface v0.7](https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_sc.zip) → `w600k_mbf.onnx` | InsightFace pretrained models: non-commercial research only ([license](https://github.com/deepinsight/insightface/tree/master/python-package#license)) | Personal prototype only; never redistributed | Not yet calibrated: `MatchPolicy.conservative` (0.55 / 0.08 / 3 votes) until the calibration follow-up |

## `insightface-w600k_mbf-buffalo_sc-v0.7`

- **Architecture:** MobileFaceNet, ArcFace loss, trained on WebFace600K (InsightFace `w600k_mbf`).
  ~13.6 MB ONNX, 512-d output.
- **Release:** `deepinsight/insightface` GitHub release tag `v0.7`, asset `buffalo_sc.zip`
  (the pack also contains the `det_500m` SCRFD detector, which Halo does not use: Apple Vision
  does detection).
- **SHA-256:**
  - `buffalo_sc.zip`: `57d31b56b6ffa911c8a73cfc1707c73cab76efe7f13b675a05223bf42de47c72`
  - `w600k_mbf.onnx`: `9cc6e4a75f0e2bf0b1aed94578f144d15175f357bdc05e815e5c4a02b319eb4f`
- **License:** InsightFace code is MIT, but the pretrained model packs are released for
  non-commercial research purposes only. Acceptable for this personal prototype; do not ship
  commercially or redistribute the weights (including converted CoreML files).
- **Input:** aligned 112×112 RGB face crop (ArcFace 5-point template, see `FaceAligner`), NCHW
  float32 tensor `input` `[1, 3, 112, 112]`, normalized `(pixel − 127.5) / 127.5`. The
  normalization happens in `CoreMLFaceEmbedder` (`Preprocessing.arcFace`), not in the model.
- **Output:** `embedding` `[1, 512]` float32, raw; `CoreMLFaceEmbedder` L2-normalizes it.

### Conversion (done by `scripts/fetch-models.sh`)

coremltools 6+ no longer converts ONNX directly, so the script goes ONNX → PyTorch (onnx2torch) →
TorchScript → CoreML ML program, in a throwaway `uv` environment with pinned versions
(Python 3.12, torch 2.5.1, onnx 1.17.0, onnx2torch 1.5.15, coremltools 8.3.0, numpy 1.26.4):

```python
torch_model = onnx2torch.convert(onnx.load("Models/w600k_mbf.onnx")).eval()
traced = torch.jit.trace(torch_model, torch.rand(1, 3, 112, 112) * 2 - 1)
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=(1, 3, 112, 112), dtype=np.float32)],
    outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    convert_to="mlprogram", compute_precision=ct.precision.FLOAT32,
    minimum_deployment_target=ct.target.iOS18,
)
mlmodel.save("Models/HaloFaceEmbedder.mlpackage")
```

then `xcrun coremlcompiler compile Models/HaloFaceEmbedder.mlpackage Models/`. The script fails if
the CoreML output is not 512-d or its cosine similarity to the PyTorch reference on a random input
is below 0.999 (measured: 1.000000). Without `uv` it verifies the download and prints these steps
for a manual run.

The app loads `HaloFaceEmbedder.mlmodelc` via `CoreMLFaceEmbedder(directory:)`. If it is missing,
the embedder throws `HaloVisionError.modelNotFound` and the app shows "recognition unavailable".

Rules:
- Record exact source URL, commit/tag, SHA-256 of the downloaded file, and the license text link.
- Personal prototype: research/non-commercial weights are acceptable. Do not redistribute them.
- `EmbeddingSpace.modelID` must change whenever the weights change; embeddings from different spaces
  are never compared.
- Calibrate `minSimilarity` / `minMargin` on a public face-verification benchmark pair list and
  record the target false-accept rate (≤ 0.1%) and the resulting thresholds here.
