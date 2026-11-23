# Halo — product plan (draft v0, awaiting feedback)

A live camera lens that recognizes people you already know and floats a holographic label over their
head: who they are, how you know them, and the one or two things worth remembering right now.

Design stance: a **personal memory aid**, not a surveillance tool. Everything biometric is on-device,
only people you enrolled and confirmed are ever recognized, and unknown faces stay anonymous.
See the invariants in `AGENTS.md`.

## Feature set

### Core (MVP)

1. **Live Lens** — full-screen camera; real-time face detection and tracking; recognized people get a
   holographic label anchored above the head (smoothed, depth-scaled, fades on track loss). Unknown
   faces get a faint neutral ring only. Tap a label to expand a full context card.
2. **People Graph (local)** — one `Person` per human, merging identities across sources: contact
   card, face clusters, IG/X handles, iMessage handles, Google Photos picks. Identity resolution by
   phone/email/handle/name with user-confirmed merges.
3. **Enrollment ("Who is this?")** — on-device scan of the Apple Photos library: detect faces,
   embed, cluster; user names clusters (linked to a contact) in a swipeable triage UI. Contact photos
   seed enrollment too. Nothing is recognizable until confirmed.
4. **Context labels** — label shows name + relationship line + 1–2 chips chosen by a ranker:
   last interaction ("texted 3d ago"), upcoming (birthday in 5 days), memory hook ("met at Sam's
   wedding '24"), open loop ("you owe them a reply"), shared recent photo. Card shows the rest.
5. **Connectors / importers**
   - Apple Contacts (names, photos, birthdays, notes, relations)
   - Apple Photos (PhotoKit, full library, on-device)
   - Google Photos (Picker API — user picks albums/photos per session)
   - Instagram (import "Download your information" export: followers/following, DMs metadata, media)
   - X (OAuth: following list + DMs, pay-per-use; or archive import)
   - iMessage (Mac companion reads `chat.db` → per-person interaction stats + recent-thread digest →
     encrypted sync to phone)
   - LinkedIn (export import — later)
6. **Privacy core** — Face ID app lock, encrypted store, per-person "forget", global kill switch,
   per-source disconnect + purge, local audit log of recognitions, export-my-data.

### Next

7. **Moments** — capture a frame with labels; quick voice/text note ("talked about her new job")
   that feeds back into that person's memory hooks.
8. **On-device summaries** — Apple Foundation Models (iOS 26) turns message/social history into
   2–3 short memory hooks per person. Never off-device by default.
9. **Whisper mode** — no screen needed: AirPods speak the name + one hook when a known face is held
   in frame; haptic tap for "you know this person".
10. **Holographic polish** — Skia shader label (scanlines, chromatic fringe, glow, parallax from
    device motion), per-relationship color coding, entry/exit animations.

### Later / explicitly out of scope

- Smart-glasses mode (Ray-Ban Meta / visionOS) — later.
- Identifying strangers, web/social lookup of unknown faces, cloud face matching — **never**.

## Architecture

```
Camera (VisionCamera v5 frame output, worklet)
  └─ face detector (ML Kit/Nitro) ─ boxes + landmarks
       └─ aligner + embedder (CoreML/TFLite, native) ─ 128/512-d vector   [throttled per track]
            └─ tracker (IoU + One Euro smoothing, track IDs)
                 └─ matcher (open-set cosine, top-2 margin, per-track voting)
                      └─ label builder (graph + ranker → LabelData)
                           └─ Skia hologram overlay
People Graph store (expo-sqlite + SQLCipher)  ◄── connectors/importers (contacts, photos, picker,
                                                   IG/X archives, X OAuth, Mac iMessage bridge)
server/ (Vercel) — OAuth token exchange only (no user data)
mac/    — iMessage bridge CLI (reads chat.db, emits encrypted digest)
```

## Waves (draft — becomes GitHub issues via `/plan-wave`)

**Wave 0 — master scaffold (no agents):** Expo SDK 58 app, TS strict, eslint/tsc/vitest, CI,
`src/lib/types.ts` contract, `src/lib/seams.ts`, `docs/MODELS.md`, EAS config.

**Wave 1 — independent foundations (parallel)**
| # | Issue | Tier |
|---|-------|------|
| 1 | People Graph store: schema, encrypted open, CRUD, forget-person cascade | opus |
| 2 | Matcher: open-set cosine match, thresholds, top-2 margin, per-track voting (pure TS) | opus |
| 3 | Tracker + smoothing: IoU track assignment, One Euro filter, track lifecycle (pure TS) | opus |
| 4 | Hologram label component (Skia), driven by props; storybook-style demo screen | sonnet |
| 5 | Contacts connector → Person/Identity records | sonnet |
| 6 | Instagram export parser (synthetic fixtures) | sonnet |
| 7 | X archive parser (synthetic fixtures) | sonnet |
| 8 | Mac iMessage bridge CLI: chat.db reader → per-handle interaction digest JSON | sonnet |
| 9 | Embedding model selection + license provenance + native embedder module (spike → module) | opus |

**Wave 2 — pipelines and flows**
| # | Issue | Tier |
|---|-------|------|
| 10 | Camera frame pipeline: VisionCamera v5 + detector + embedder throttling → FaceObservation stream | opus |
| 11 | Photos library scan + clustering job (background, resumable) | opus |
| 12 | Enrollment triage UI ("Who is this?") | sonnet |
| 13 | Identity resolution + merge suggestions across sources | opus |
| 14 | Google Photos Picker connector (OAuth PKCE + session polling) | sonnet |
| 15 | X OAuth connector (following + DM metadata) + server token proxy | sonnet |
| 16 | Label ranker: Person + interactions → LabelData chips | sonnet |
| 17 | Privacy shell: Face ID lock, kill switch, per-source purge, audit log | sonnet |

**Wave 3 — integration**
| # | Issue | Tier |
|---|-------|------|
| 18 | Live Lens screen: pipeline + tracker + matcher + ranker + hologram | opus |
| 19 | iMessage bridge → phone encrypted sync (pairing, key exchange) | opus |
| 20 | Onboarding + consent flow + source connection hub | sonnet |

**Wave 4 — polish and ship**
| # | Issue | Tier |
|---|-------|------|
| 21 | Moments capture + notes | sonnet |
| 22 | On-device summaries (Foundation Models) → memory hooks | sonnet |
| 23 | Whisper mode (AirPods speech + haptics) | sonnet |
| 24 | Maestro e2e flows + perf pass (30 fps budget) + EAS TestFlight | sonnet |

## Known constraints (verified 2026-11)

- No Xcode on the dev machine → iOS builds via EAS cloud, or install Xcode for local dev builds.
- Google Photos: no whole-library access; Picker only.
- Instagram personal accounts: no API; export import only.
- X: API is pay-per-use (~$0.01/resource read).
- iMessage: Mac-only via `chat.db`; `imessage-exporter` is GPL-3.0 (run as separate tool or write our
  own typedstream parser).
- Face embedding weights: InsightFace pretrained = non-commercial; need verified-license weights.
- Legal: BIPA has no household exemption; on-device-only + consent UX is the posture. Counsel before
  any public launch.
