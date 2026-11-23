# Face embedding models

Weights are never committed (public repo). `scripts/fetch-models.sh` downloads and converts them into
the gitignored `Models/` directory, which the app bundles at build time.

| Model ID | Dimension | Source URL | License | Use allowed | Calibrated `MatchPolicy` |
|----------|-----------|------------|---------|-------------|--------------------------|
| _TBD by the HaloVision issue_ | | | | | |

Rules:
- Record exact source URL, commit/tag, SHA-256 of the downloaded file, and the license text link.
- Personal prototype: research/non-commercial weights are acceptable. Do not redistribute them.
- `EmbeddingSpace.modelID` must change whenever the weights change; embeddings from different spaces
  are never compared.
- Calibrate `minSimilarity` / `minMargin` on a public face-verification benchmark pair list and
  record the target false-accept rate (≤ 0.1%) and the resulting thresholds here.
