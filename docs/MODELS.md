# Face embedding models

Weights are never committed (public repo). `scripts/fetch-models.sh` downloads and converts them into
the gitignored `Models/` directory, which the app bundles at build time.

| Model ID | Dimension | Source URL | License | Use allowed | Calibrated `MatchPolicy` |
|----------|-----------|------------|---------|-------------|--------------------------|
| `insightface-w600k_mbf-buffalo_sc-v0.7` | 512 | [buffalo_sc.zip @ insightface v0.7](https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_sc.zip) → `w600k_mbf.onnx` | InsightFace pretrained models: non-commercial research only ([license](https://github.com/deepinsight/insightface/tree/master/python-package#license)) | Personal prototype only; never redistributed | LFW-calibrated recommendation 0.23 / 0.19 / 2 votes ([Calibration](#calibration)); code still ships `MatchPolicy.conservative` (0.55 / 0.08 / 3) until master applies it |

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

## Calibration

`halo-calibrate` (macOS CLI, math in `HaloCalibrateKit`) measures a model's verification error rates
on a **public** benchmark and recommends `MatchPolicy` thresholds. Run it with
`./scripts/calibrate.sh` after `./scripts/fetch-models.sh`; it skips when the model or dataset is
absent, and CI never downloads datasets. It never touches personal photos and reports aggregates
only (no identities, file names or per-image scores). `MatchPolicy.conservative` is **not** changed
by the tool: master applies a recommendation after review.

Method (all decisions use the matcher's rule, accept iff cosine ≥ threshold):

1. Detect every image the pair list references with `VisionFaceDetector` (the face with five
   landmarks closest to the image centre: LFW's subject), embed with `CoreMLFaceEmbedder`.
2. Verification: FAR/FRR and ROC points on the standard `pairs.txt` (3000 + 3000 pairs, standard
   10-fold accuracy) and on **all** pairs of the embedded images (~29.6M impostor pairs), which
   resolves FAR far below 0.01%; the 3000 standard impostors cannot resolve 0.01%.
   `minSimilarity` = lowest threshold with FAR ≤ 0.1% on the all-pairs set, rounded **up** to 0.01.
3. Margin: simulated galleries of N = 10 / 50 / 200 identities (seeded choice, one enrollment image
   each); every other image is a probe (enrolled identity = known probe, anyone else = unknown,
   open-set probe). `minMargin` = smallest of 0.00…0.30 keeping wrong names ≤ 0.1% of probes at
   that `minSimilarity` in every N, rounded up.
4. Voting: 5 tracks × 10 frames per probe identity (largest gallery), frames drawn with replacement
   from that identity's probe images, replayed through the app's `TrackVoter` for `minVotes` 2…4.

### Dataset: LFW (Labeled Faces in the Wild)

- **What:** 13,233 web news photos of 5,749 public figures; standard verification list
  `pairs.txt` (10 folds × 300 matched + 300 mismatched pairs, 7,701 distinct images).
- **Source:** University of Massachusetts Amherst (Huang et al., 2007), originally
  `http://vis-www.cs.umass.edu/lfw/` (unreachable when calibrated), downloaded from the figshare
  mirror scikit-learn's `fetch_lfw_pairs` uses:
  - `lfw.tgz`: `https://ndownloader.figshare.com/files/5976018`,
    SHA-256 `055f7d9c632d7370e6fb4afc7468d40f970c34a80d4c6f50ffec63f5a8d536c0`
  - `pairs.txt`: `https://ndownloader.figshare.com/files/5976006`,
    SHA-256 `ea42330c62c92989f9d7c03237ed5d591365e89b3e649747777b70e692dc1592`

  Both match scikit-learn's published checksums.
- **License:** LFW carries no formal license; its authors distribute it free of charge for research
  on face recognition, and it is the standard public benchmark for it. We use it only locally to
  compute aggregate statistics. It is downloaded into the gitignored `Models/calibration/` and is
  never committed or redistributed.

### Results summary

| Model ID | Dataset | FAR target | Threshold (all pairs) | FRR at threshold | Recommended `MatchPolicy` |
|----------|---------|-----------:|----------------------:|-----------------:|---------------------------|
| `insightface-w600k_mbf-buffalo_sc-v0.7` | LFW `pairs.txt` images | ≤ 0.1% | 0.2276 | 0.47% | `MatchPolicy(minSimilarity: 0.23, minMargin: 0.19, minVotes: 2)` |
| `insightface-w600k_mbf-buffalo_sc-v0.7` | LFW `pairs.txt` images | ≤ 0.01% | 0.2823 | 0.81% | minSimilarity 0.29 for the stricter target |

Reading the numbers (for whoever applies them):

- On LFW the current `conservative` 0.55 rejects ~30% of genuine pairs, while FAR 0.1% is already
  reached at 0.23. LFW is easy (sharp, mostly frontal press photos) and the model's WebFace600K
  training set may overlap LFW identities, so these thresholds are a **lower bound** for live
  camera frames (blur, pose, low light). A value between the 0.01%-FAR threshold (0.29) and 0.55,
  checked on device, is the cautious choice.
- Voting barely changes the *track* false-label rate (15 of 21,405 tracks at every `minVotes`).
  The residual wrong names come from perfectly correlated frames (identities with a single probe
  image repeat it) or likely LFW label noise (a wrong top-1 with margin 0.37). More votes lower the
  *frame* rate and cost recall. Real video frames are correlated too, so `minVotes` mostly buys
  stability rather than accuracy; keeping 3 is reasonable.
- Known probes are limited to the images in `pairs.txt` (25 / 104 / 454 for N = 10 / 50 / 200), so
  the margin and voting figures are dominated by unknown (open-set) probes.

### Full report

#### Calibration: `insightface-w600k_mbf-buffalo_sc-v0.7` on LFW (`pairs.txt`, 6000 pairs)

Run 2026-11-23 with `scripts/calibrate.sh`. Images: 7701 referenced, 7701 embedded; 0 pairs skipped (no usable face).
Standard 10-fold accuracy: 99.58% ± 0.25%; EER 0.37%.

**Recommended:** `MatchPolicy(minSimilarity: 0.23, minMargin: 0.19, minVotes: 2)` (target FAR ≤ 0.100%; `MatchPolicy.conservative` is unchanged in code).

##### Verification (accept iff cosine ≥ threshold)

| Pair set | Genuine | Impostor | FAR target | Threshold | FAR | FRR |
|----------|--------:|---------:|-----------:|----------:|----:|----:|
| pairs.txt | 3000 | 3000 | 1.000% | 0.1642 | 1.0000% | 0.30% |
| pairs.txt | 3000 | 3000 | 0.100% | 0.2574 | 0.1000% | 0.77% |
| pairs.txt | 3000 | 3000 | 0.010% (below resolution) | 0.3090 | 0.0000% | 1.43% |
| all pairs | 8101 | 29640749 | 1.000% | 0.1665 | 1.0000% | 0.22% |
| all pairs | 8101 | 29640749 | 0.100% | 0.2276 | 0.1000% | 0.47% |
| all pairs | 8101 | 29640749 | 0.010% | 0.2823 | 0.0100% | 0.81% |

##### ROC points at fixed thresholds

| Pair set | Threshold | FAR | FRR |
|----------|----------:|----:|----:|
| pairs.txt | 0.20 | 0.3333% | 0.37% |
| pairs.txt | 0.25 | 0.1333% | 0.73% |
| pairs.txt | 0.30 | 0.0333% | 1.27% |
| pairs.txt | 0.35 | 0.0000% | 2.37% |
| pairs.txt | 0.40 | 0.0000% | 4.80% |
| pairs.txt | 0.45 | 0.0000% | 9.50% |
| pairs.txt | 0.50 | 0.0000% | 16.33% |
| pairs.txt | 0.55 | 0.0000% | 30.03% |
| all pairs | 0.20 | 0.2947% | 0.28% |
| all pairs | 0.25 | 0.0400% | 0.58% |
| all pairs | 0.30 | 0.0046% | 1.07% |
| all pairs | 0.35 | 0.0005% | 1.99% |
| all pairs | 0.40 | 0.0001% | 4.23% |
| all pairs | 0.45 | 0.0001% | 8.49% |
| all pairs | 0.50 | 0.0001% | 16.15% |
| all pairs | 0.55 | 0.0001% | 29.76% |

##### Open-set gallery emulation (top-1 vs top-2 margin, per frame)

Margins of probes whose top-1 clears `minSimilarity` = 0.23. False-label rate = wrong names / all probes (known + unknown).

| Gallery N | Known probes | Unknown probes | Correct margin p1 / p5 / p50 | Wrong margin p50 / p99 / max | Suggested minMargin | False-label rate | Known recall | Conservative: false-label / recall |
|---:|---:|---:|---|---|---:|---:|---:|---|
| 10 | 25 | 7666 | 0.102 / 0.171 / 0.479 | 0.146 / 0.244 / 0.244 (n=55) | 0.19 | 0.0910% | 92.00% | 0.0000% / 68.00% |
| 50 | 104 | 7547 | 0.119 / 0.167 / 0.455 | 0.097 / 0.218 / 0.237 (n=280) | 0.19 | 0.0784% | 94.23% | 0.0000% / 69.23% |
| 200 | 454 | 7047 | 0.102 / 0.168 / 0.398 | 0.056 / 0.151 / 0.370 (n=1107) | 0.16 | 0.0933% | 95.15% | 0.0000% / 66.74% |

##### Per-track voting (`TrackVoter`, 10 frames per track, recommended thresholds)

| minVotes | Tracks | Tracks ever wrong | Frames wrong | Known-track recall |
|---:|---:|---:|---:|---:|
| 2 | 21405 | 15 (0.070%) | 0.0631% | 95.80% |
| 3 | 21405 | 15 (0.070%) | 0.0561% | 94.50% |
| 4 | 21405 | 15 (0.070%) | 0.0491% | 93.10% |

- minSimilarity: lowest threshold with FAR ≤ 0.1% on the all-pairs set, rounded up to 0.01.
- minMargin: smallest grid value (0.00…0.30) keeping the per-frame false-label rate ≤ 0.1% in every gallery size, rounded up to 0.01.
- minVotes: smallest of 2…4 with track false-label rate ≤ 0.1% (else the lowest-rate one); tracks sample one identity's images with replacement, seed 42.

## Voting policy

`TrackVoter` (HaloMatching) turns per-frame matches into a stable name. With `n = minVotes`: a name
needs `n` consecutive agreeing `.known` results; it drops after `n` consecutive non-matching results
or when the held person is not a strict majority (more than half) of the last `2n` results. A
exactly-50% window therefore drops the name. This trades recall for precision on purpose (invariant
4): a flickering track briefly loses its label rather than risk showing a wrong one, and has to
re-earn it with a fresh `n`-streak. `IoUTracker` likewise clears a track's identity when it is
re-matched after more than `TrackerConfig.identityResetAfterMissed` (default 5) missed frames.
