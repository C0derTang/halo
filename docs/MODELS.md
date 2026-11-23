# Face embedding models

Weights are never committed (public repo). `scripts/fetch-models.sh` downloads and converts them into
the gitignored `Models/` directory, which the app bundles at build time.

| Model ID | Dimension | Source URL | License | Use allowed | Calibrated `MatchPolicy` |
|----------|-----------|------------|---------|-------------|--------------------------|
| `insightface-w600k_mbf-buffalo_sc-v0.7` | 512 | [buffalo_sc.zip @ insightface v0.7](https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_sc.zip) → `w600k_mbf.onnx` | InsightFace pretrained models: non-commercial research only ([license](https://github.com/deepinsight/insightface/tree/master/python-package#license)) | Personal prototype only; never redistributed | **Proposed production:** 0.32 / 0.20 / 3 votes, LFW-calibrated ([Calibration](#calibration)); code still ships `MatchPolicy.conservative` (0.55 / 0.08 / 3) until master applies it |

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
by the tool: master applies a policy after review.

**Proposed production policy:** `MatchPolicy(minSimilarity: 0.32, minMargin: 0.20, minVotes: 3)`.
This is a proposal; `Contract.swift` still ships `conservative` (0.55 / 0.08 / 3) until master
applies it. Results at this policy are in [Proposed policy per gallery cell](#proposed-policy-per-gallery-cell).

Method (all decisions use the matcher's rule, accept iff cosine ≥ threshold):

1. Detect every image the pair list references with `VisionFaceDetector` (the face with five
   landmarks closest to the image centre: LFW's subject), embed with `CoreMLFaceEmbedder`.
   `--gallery-images all` also embeds the rest of LFW (13,233 images) for steps 3–4.
2. Verification: FAR/FRR and ROC points on the standard `pairs.txt` (3000 + 3000 pairs, standard
   10-fold accuracy) and on **all** pairs of the `pairs.txt` images (~29.6M impostor pairs), which
   resolves FAR far below 0.01%; the 3000 standard impostors cannot resolve 0.01%.
   Derived `minSimilarity` = lowest threshold with pair FAR ≤ `--far` (0.1%) on the all-pairs set,
   rounded **up** to 0.01.
3. Margin: one cell per enrollment count k (`--enroll-per-person`, e.g. 1,3,5) × gallery size N
   (10 / 50 / 200 identities, seeded choice among identities with more than k images). Each enrolled
   person gets their first k images; every other image is a probe (enrolled identity = known probe,
   anyone else = unknown, open-set probe). Derived `minMargin` = smallest of 0.00…0.30 keeping wrong
   names ≤ `--max-wrong-label-rate` (0.1%) of probes in **every** cell, rounded up; a cell with no such
   value contributes the 0.30 fallback, and the report shows its numbers at that fallback.
4. Voting: 5 tracks × 10 frames per probe identity, frames drawn with replacement from that
   identity's probe images, replayed through the app's `TrackVoter`. Derived `minVotes` = lowest
   worst-cell track false-label rate among 2…4, ties to **more** votes, never below the current 3.
5. `--min-similarity` / `--min-margin` / `--min-votes` override the derived values; the per-cell table
   is evaluated at the resulting policy.

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

Command: `./scripts/calibrate.sh --min-similarity 0.32 --min-margin 0.20 --min-votes 3
--enroll-per-person 1,3,5 --gallery-sizes 10,50,200 --gallery-images all`.

| Model ID | Dataset | Pair FAR target | Threshold (all pairs) | FRR at threshold | `MatchPolicy` |
|----------|---------|----------------:|----------------------:|-----------------:|---------------|
| `insightface-w600k_mbf-buffalo_sc-v0.7` | LFW | ≤ 0.1% | 0.2277 | 0.46% | Derived: `MatchPolicy(minSimilarity: 0.23, minMargin: 0.20, minVotes: 4)` |
| `insightface-w600k_mbf-buffalo_sc-v0.7` | LFW | ≤ 0.01% | 0.2824 | 0.84% | (minSimilarity 0.29 for the stricter target) |
| `insightface-w600k_mbf-buffalo_sc-v0.7` | LFW | 0.0018% (measured) | 0.32 | 1.28% | **Proposed production:** `MatchPolicy(minSimilarity: 0.32, minMargin: 0.20, minVotes: 3)` |

#### Proposed policy per gallery cell

At `MatchPolicy(minSimilarity: 0.32, minMargin: 0.20, minVotes: 3)`, probes from all 13,233 LFW
images. Wrong-label rate = wrong names / all probes (known + unknown); recall = right names / known
probes. Tracks: 10 frames through `TrackVoter`; a track counts as wrong if it **ever** shows a wrong
name, and as recalled if it ever shows the right one (28,745 tracks per cell, 5 per identity).

| Enroll/person | Gallery N | Known / unknown probes | Frame wrong-label | Frame recall | Track wrong-label | Track recall |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 10 | 27 / 13,196 | 0.000% (0) | 100.0% | 0.000% (0) | 100.0% |
| 1 | 50 | 168 / 13,015 | 0.038% (5) | 97.0% | 0.021% (6) | 95.2% |
| 1 | 200 | 802 / 12,231 | 0.031% (4) | 96.0% | 0.052% (15) | 94.1% |
| 3 | 10 | 80 / 13,123 | 0.015% (2) | 100.0% | 0.000% (0) | 100.0% |
| 3 | 50 | 985 / 12,098 | 0.038% (5) | 99.6% | 0.024% (7) | 100.0% |
| 3 | 200 | 1,686 / 10,947 | 0.032% (4) | 98.7% | 0.035% (10) | 99.0% |
| 5 | 10 | 49 / 13,134 | 0.038% (5) | 100.0% | 0.052% (15) | 100.0% |
| 5 | 50 | 360 / 12,623 | 0.085% (11) | 98.9% | 0.035% (10) | 98.0% |
| 5 | 200 | 2,063 / 10,170 | 0.033% (4) | 98.5% | 0.035% (10) | 98.3% |

Every cell stays under 0.1% wrong names per frame and per track. The trade against `conservative`
(0.55 / 0.08, "Conservative" column of the full report's margin table): per-frame recall rises from
73–95% to 96–100%, and per-frame wrong names rise from 0.000–0.032% to 0.000–0.085%. Pair FAR at
0.32 is 0.0018%, with pair FRR 1.28% (vs ~30% at 0.55).

Reading the numbers (for whoever applies them):

- LFW is easy (sharp, mostly frontal press photos) and the model's WebFace600K training set may
  overlap LFW identities, so LFW thresholds are a **lower bound** for live camera frames (blur, pose,
  low light). 0.32 sits above the 0.01%-FAR threshold (0.28) for that headroom; check it on device.
- Voting barely changes the *track* false-label rate (tracks ever wrong for minVotes 2/3/4 at
  N = 200: 15/15/15, 10/10/10 and 11/10/10 for k = 1/3/5). The residual wrong names come from perfectly correlated frames (identities with a single
  probe image repeat it) or likely LFW label noise (wrong top-1 candidates with margins up to ~0.5).
  More votes lower the *frame* rate and cost recall; 3 keeps the current behaviour.
- More enrollment images per person raise recall (k = 1 → 3: 96% → 99% at N = 200) but also give
  impostors more chances to match (similarity-only wrong-label rate grows with k), which is why the
  margin gate matters more for larger galleries.
- Small run-to-run differences (±0.0001 in thresholds, ±0.03 pp in FRR) appear across runs: Vision
  and CoreML on the GPU/Neural Engine are not bit-exact.

### Full report

#### Calibration: `insightface-w600k_mbf-buffalo_sc-v0.7` on LFW (`pairs.txt`, 6000 pairs)

Run 2026-11-23 with `scripts/calibrate.sh`. Images: 7701 referenced, 7701 embedded; 0 pairs skipped (no usable face). Galleries and probes: all 13233 embedded LFW images.
Standard 10-fold accuracy: 99.57% ± 0.26%; EER 0.40%.

**Derived:** `MatchPolicy(minSimilarity: 0.23, minMargin: 0.20, minVotes: 4)` (pair FAR ≤ 0.100%, wrong names ≤ 0.100% of probes; `MatchPolicy.conservative` is unchanged in code).

**Evaluated (command-line overrides):** `MatchPolicy(minSimilarity: 0.32, minMargin: 0.20, minVotes: 3)`.

##### Verification (accept iff cosine ≥ threshold)

| Pair set | Genuine | Impostor | FAR target | Threshold | FAR | FRR |
|----------|--------:|---------:|-----------:|----------:|----:|----:|
| pairs.txt | 3000 | 3000 | 1.000% | 0.1656 | 1.0000% | 0.30% |
| pairs.txt | 3000 | 3000 | 0.100% | 0.2532 | 0.1000% | 0.80% |
| pairs.txt | 3000 | 3000 | 0.010% (below resolution) | 0.3221 | 0.0000% | 1.70% |
| all pairs | 8101 | 29640749 | 1.000% | 0.1665 | 1.0000% | 0.21% |
| all pairs | 8101 | 29640749 | 0.100% | 0.2277 | 0.1000% | 0.46% |
| all pairs | 8101 | 29640749 | 0.010% | 0.2824 | 0.0100% | 0.84% |

##### ROC points at fixed thresholds

| Pair set | Threshold | FAR | FRR |
|----------|----------:|----:|----:|
| pairs.txt | 0.20 | 0.3667% | 0.40% |
| pairs.txt | 0.25 | 0.1333% | 0.80% |
| pairs.txt | 0.30 | 0.0333% | 1.37% |
| pairs.txt | 0.32 | 0.0333% | 1.60% |
| pairs.txt | 0.35 | 0.0000% | 2.27% |
| pairs.txt | 0.40 | 0.0000% | 5.00% |
| pairs.txt | 0.45 | 0.0000% | 9.60% |
| pairs.txt | 0.50 | 0.0000% | 16.23% |
| pairs.txt | 0.55 | 0.0000% | 29.67% |
| all pairs | 0.20 | 0.2943% | 0.28% |
| all pairs | 0.25 | 0.0400% | 0.59% |
| all pairs | 0.30 | 0.0046% | 1.09% |
| all pairs | 0.32 | 0.0018% | 1.28% |
| all pairs | 0.35 | 0.0005% | 1.95% |
| all pairs | 0.40 | 0.0001% | 4.27% |
| all pairs | 0.45 | 0.0001% | 8.53% |
| all pairs | 0.50 | 0.0001% | 16.08% |
| all pairs | 0.55 | 0.0001% | 29.79% |

##### Evaluated policy per gallery cell

At `MatchPolicy(minSimilarity: 0.32, minMargin: 0.20, minVotes: 3)`. Wrong-label rate = wrong names / all probes (known + unknown); recall = right names / known probes. Tracks: 10 frames, `TrackVoter`; a track is wrong if it ever shows a wrong name and recalled if it ever shows the right one.

| Enroll/person | Gallery N | Known probes | Unknown probes | Frame wrong-label | Frame recall | Tracks | Track wrong-label | Track recall |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 10 | 27 | 13196 | 0.0000% (0) | 100.00% | 28745 | 0.000% (0) | 100.00% |
| 1 | 50 | 168 | 13015 | 0.0379% (5) | 97.02% | 28745 | 0.021% (6) | 95.20% |
| 1 | 200 | 802 | 12231 | 0.0307% (4) | 96.01% | 28745 | 0.052% (15) | 94.10% |
| 3 | 10 | 80 | 13123 | 0.0151% (2) | 100.00% | 28745 | 0.000% (0) | 100.00% |
| 3 | 50 | 985 | 12098 | 0.0382% (5) | 99.59% | 28745 | 0.024% (7) | 100.00% |
| 3 | 200 | 1686 | 10947 | 0.0317% (4) | 98.70% | 28745 | 0.035% (10) | 99.00% |
| 5 | 10 | 49 | 13134 | 0.0379% (5) | 100.00% | 28745 | 0.052% (15) | 100.00% |
| 5 | 50 | 360 | 12623 | 0.0847% (11) | 98.89% | 28745 | 0.035% (10) | 98.00% |
| 5 | 200 | 2063 | 10170 | 0.0327% (4) | 98.45% | 28745 | 0.035% (10) | 98.30% |

##### Open-set gallery emulation (top-1 vs top-2 margin, per frame)

Margins of probes whose top-1 clears `minSimilarity` = 0.32. Cells read false-label / recall; "Suggested" is at the suggested margin, or at the fallback (largest grid) margin when none meets the target.

| Enroll/person | Gallery N | Correct margin p1 / p5 / p50 | Wrong margin p50 / p99 / max | Suggested minMargin | Suggested | Similarity only | Conservative |
|---:|---:|---|---|---:|---|---|---|
| 1 | 10 | 0.257 / 0.395 / 0.530 | n/a / n/a / n/a (n=0) | 0.00 | 0.0000% / 100.00% | 0.0000% / 100.00% | 0.0000% / 74.07% |
| 1 | 50 | 0.176 / 0.294 / 0.476 | 0.191 / 0.262 / 0.262 (n=10) | 0.00 | 0.0759% / 98.21% | 0.0759% / 98.21% | 0.0000% / 73.21% |
| 1 | 200 | 0.158 / 0.249 / 0.427 | 0.142 / 0.528 / 0.528 (n=48) | 0.16 | 0.0997% / 97.01% | 0.3683% / 98.00% | 0.0153% / 75.44% |
| 3 | 10 | 0.270 / 0.388 / 0.537 | 0.209 / 0.213 / 0.213 (n=2) | 0.00 | 0.0151% / 100.00% | 0.0151% / 100.00% | 0.0000% / 92.50% |
| 3 | 50 | 0.286 / 0.343 / 0.481 | 0.155 / 0.521 / 0.521 (n=35) | 0.17 | 0.0764% / 99.59% | 0.2675% / 99.59% | 0.0153% / 95.13% |
| 3 | 200 | 0.200 / 0.290 / 0.446 | 0.103 / 0.506 / 0.506 (n=98) | 0.16 | 0.0792% / 99.05% | 0.7757% / 99.70% | 0.0317% / 92.05% |
| 5 | 10 | 0.289 / 0.323 / 0.545 | 0.174 / 0.259 / 0.259 (n=17) | 0.14 | 0.0910% / 100.00% | 0.1290% / 100.00% | 0.0000% / 87.76% |
| 5 | 50 | 0.235 / 0.327 / 0.490 | 0.152 / 0.293 / 0.293 (n=71) | 0.20 | 0.0847% / 98.89% | 0.5469% / 99.72% | 0.0000% / 93.61% |
| 5 | 200 | 0.175 / 0.294 / 0.452 | 0.093 / 0.255 / 0.435 (n=211) | 0.17 | 0.0981% / 98.69% | 1.7248% / 99.61% | 0.0163% / 94.04% |

##### Per-track voting (`TrackVoter`, 10 frames per track, evaluated thresholds)

| Enroll/person | Gallery N | minVotes | Tracks | Tracks ever wrong | Frames wrong | Known-track recall |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 200 | 2 | 28745 | 15 (0.052%) | 0.0470% | 94.60% |
| 1 | 200 | 3 | 28745 | 15 (0.052%) | 0.0417% | 94.10% |
| 1 | 200 | 4 | 28745 | 15 (0.052%) | 0.0365% | 93.80% |
| 3 | 200 | 2 | 28745 | 10 (0.035%) | 0.0313% | 99.30% |
| 3 | 200 | 3 | 28745 | 10 (0.035%) | 0.0278% | 99.00% |
| 3 | 200 | 4 | 28745 | 10 (0.035%) | 0.0244% | 98.10% |
| 5 | 200 | 2 | 28745 | 11 (0.038%) | 0.0324% | 98.50% |
| 5 | 200 | 3 | 28745 | 10 (0.035%) | 0.0278% | 98.30% |
| 5 | 200 | 4 | 28745 | 10 (0.035%) | 0.0244% | 97.40% |

- minSimilarity: lowest threshold with pair FAR ≤ 0.1% on the all-pairs set, rounded up to 0.01.
- minMargin: smallest grid value (0.00…0.30) keeping wrong names ≤ 0.1% of probes at the evaluated minSimilarity in every cell, rounded up to 0.01 (a cell with none uses 0.30).
- minVotes: lowest worst-cell track false-label rate among 2…4, ties to more votes, never below the current 3. Tracks sample one identity's images with replacement, seed 42, 5 tracks per identity.

## Voting policy

`TrackVoter` (HaloMatching) turns per-frame matches into a stable name. With `n = minVotes`: a name
needs `n` consecutive agreeing `.known` results; it drops after `n` consecutive non-matching results
or when the held person is not a strict majority (more than half) of the last `2n` results. A
exactly-50% window therefore drops the name. This trades recall for precision on purpose (invariant
4): a flickering track briefly loses its label rather than risk showing a wrong one, and has to
re-earn it with a fresh `n`-streak. `IoUTracker` likewise clears a track's identity when it is
re-matched after more than `TrackerConfig.identityResetAfterMissed` (default 5) missed frames.
