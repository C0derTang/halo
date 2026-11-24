# Halo — product plan (v1)

A live camera lens that recognizes people you already know and floats a holographic label over their
head: who they are, how you know them, and the one or two things worth remembering right now.

**Decisions (2026-11-23):** personal prototype (TestFlight / own device), native Swift (iOS 26),
public GitHub repo, sources = Contacts + Apple Photos + iMessage (Mac bridge), on-device AI only.

Design stance: a **personal memory aid**, not a surveillance tool. Everything biometric is
on-device, only people you enrolled and confirmed are ever recognized, unknown faces stay anonymous.
See the invariants in `AGENTS.md`.

## Feature set

### MVP
1. **Live Lens** — camera; real-time face detection + tracking; recognized people get a holographic
   label above the head (smoothed, scaled by face size, fades on track loss). Unknown faces get a
   faint neutral ring only. Tap a label → full context card.
2. **People Graph (local)** — one `Person` per human; identities from contact card, phone/email,
   iMessage handles, photo clusters.
3. **Enrollment ("Who is this?")** — on-device scan of Apple Photos: detect, embed, cluster; user
   names clusters (linked to a contact) in a triage UI. Contact photos seed enrollment. Nothing is
   recognizable until confirmed.
4. **Context labels** — name + relationship + 1–2 ranked chips: last interaction ("texted 3d ago"),
   upcoming (birthday in 5 days), open loop ("they're waiting on your reply"), memory hook.
5. **iMessage bridge** — macOS CLI reads `chat.db` metadata → `InteractionDigest` → encrypted file
   moved to the phone (AirDrop/Files) and imported with a QR-paired key.
6. **Privacy core** — Face ID lock, Data-Protection-encrypted store, per-person forget, kill switch,
   local recognition log.

### Next (wave 4)
7. On-device memory hooks — Foundation Models summarizes message text (bridge v2 decodes
   `attributedBody`) into 2–3 hooks per person.
8. Moments — capture a labeled frame + quick note that feeds memory hooks.
9. Whisper mode — AirPods speak name + one hook; haptic tap.
10. ARKit 3D anchoring for the hologram (depth-stable placement, parallax).

### Later / never
- Later: Google Photos (Picker), Instagram/X archive import, LinkedIn export, glasses.
- **Never:** identifying strangers, web/social lookup of unknown faces, cloud face matching.

## Architecture

```
AVCaptureSession (HaloLens, off main actor)
  └─ FaceDetecting (HaloVision: Vision rects + landmarks + capture quality)
       └─ FaceTracking (HaloTracking: IoU assignment + One Euro smoothing)
            └─ FaceEmbedder (HaloVision: align + CoreML), throttled per track
                 └─ FaceMatching (HaloMatching: open-set, top-2 margin, per-track votes)
                      └─ LabelRanking (HaloLabels) ─► HologramLabel (HaloUI)
PeopleStoring (HaloStore: GRDB + Data Protection) ◄── HaloImport (Contacts, PhotoScan, digest import)
                                                  ◄── HaloClustering (enrollment suggestions)
halo-bridge (macOS CLI, HaloBridgeKit) ──encrypted digest──► app
```

## Waves

**Wave 0 — master scaffold (done):** HaloKit package with all targets, `Contract.swift`,
`Seams.swift`, XcodeGen app shell, `scripts/check.sh`, CI, agent playbooks.

**Wave 1 — independent modules: DONE (2026-11-23).** Merged #9 HaloUI, #10 HaloTracking,
#11 HaloImport contacts, #12 halo-bridge, #14 HaloClustering, #15 HaloMatching, #16 HaloStore,
#18 HaloVision. Follow-ups: #13, #17.

**Wave 2 — pipelines and flows** (seams added by master: `VideoFrame`, `FrameFaceDetecting`,
`FrameFaceEmbedding`, `ClusterRecord`, `EnrollmentStoring`, `PrivacyStoring`)
| Issue | Where | Tier |
|-------|-------|------|
| Store: EnrollmentStoring + PrivacyStoring, cluster table, forget-cluster cascade, erasure fixes | HaloStore | opus |
| Frame-based detect/embed (VideoFrame + orientation), async model factory, vision follow-ups | HaloVision | opus |
| Live lens pipeline: capture → detect → track → throttled embed → vote → re-verify | HaloLens | opus |
| Photo library scan job (resumable) → embeddings → clusters | HaloImport/PhotoScan | opus |
| Encrypted digest transport: QR pairing + HPKE envelope + bridge follow-ups | HaloBridgeKit + halo-bridge | opus |
| Label ranker | HaloLabels | sonnet |
| Enrollment triage ("Who is this?") view model + views | HaloUI + App/Halo/People | sonnet |
| Privacy shell: Face ID lock, kill switch, forget UI, recognition log + HaloUI follow-ups | HaloUI + App/Halo/Settings | sonnet |
| Contacts import hardening: identityConflict, cross-kind ambiguity, shared normalizer | HaloImport/Contacts | sonnet |
| Algorithm follow-ups (matching, tracking, clustering) | HaloMatching/Tracking/Clustering | sonnet |

**Wave 2: DONE.** #29–#38 merged.

**Wave 3 (integration): DONE.** #46 onboarding, #47 People, #48 PhotoScan hardening, #49 pairing + digest
import, #50 follow-ups, #52 Lens screen, #53 CI toolchain compat, #54 composition root.

**Wave 4: DONE.**
- #68 final app hookup (all tabs real, one camera, kill switch stops every writer)
- #62 face boxes
- #67 bridge v2 (opt-in message excerpts, clean-room typedstream decoder)
- #65 memory-hook store
- #66 on-device Foundation Models hooks
- #64 hook chips
- #63 Whisper mode (headphone/confirmed-device only)

**Wave 5: DONE.**
- #76 memory hooks + Whisper + Moments wired into the app (kill switch stops every writer; Whisper is headphone/confirmed-device only and never runs while locked)
- #73 Moments (on-device dictation)
- #74 library follow-ups
- #75/#77 `halo-calibrate` on LFW; production `MatchPolicy` is now 0.32 / 0.20 / 3

**State:** 798 tests, lint, and the iOS build are green. Remaining polish items are tracked on #17. Next
step is a device test (see `e2e/`).

**Later (needs a decision):** ARKit 3D anchoring; TestFlight distribution; Android.

## Known constraints (verified 2026-11)
- No Xcode on the dev machine yet → local checks build only; CI (macos-26) runs tests + iOS build.
  Install Xcode to run on device.
- Command Line Tools can't compile `.metal` shaders or Swift Testing macros → hologram v1 is pure
  SwiftUI (Canvas/TimelineView/blend modes).
- `chat.db`: text often only in `attributedBody` (typedstream) → v1 uses metadata only.
  `imessage-exporter` is GPL-3.0 → don't link it.
- Embedding weights: research-licensed acceptable for personal use, never committed (public repo).
