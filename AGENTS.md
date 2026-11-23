# AGENTS.md

Canonical instructions for every coding agent working in this repo (Claude Code, Codex, others).
Claude-specific mechanics live in `CLAUDE.md`, which imports this file.

## Project: Halo (working name)

An iOS-first mobile app: a live camera "lens" that recognizes people **the user already knows**
and floats a holographic label above their head with context drawn from the user's own data
(Photos, Google Photos, Contacts, Instagram, X, iMessage, other socials).

Product plan and wave breakdown: `docs/PLAN.md`.

### Non-negotiable product invariants

These are load-bearing. Reviewers scrutinize them hardest. Violating one is always REQUEST_CHANGES.

1. **Known people only.** Recognition matches only against faces the user explicitly enrolled and
   confirmed. Unknown faces are never looked up anywhere (no reverse image search, no web/social
   lookup, no server-side matching). Unknown face = no identity label.
2. **Biometrics stay on device.** Face images, crops and embeddings never leave the device and are
   never sent to any server, analytics, crash report, or LLM. Stored encrypted at rest.
3. **Confirm before recognize.** Automatic clustering may *suggest* identities; a person becomes
   recognizable only after the user confirms. "Forget this person" deletes every embedding,
   crop and derived record for them, immediately and irreversibly.
4. **Open-set correctness over recall.** A wrong name on a face is worse than no name. Matching must
   reject below threshold and when the top-2 candidates are ambiguous. Thresholds live in one place
   and are covered by tests.
5. **Credential safety.** OAuth tokens live only in the iOS Keychain (`expo-secure-store`). Client
   secrets never ship in the app bundle; flows that need one go through the minimal server proxy.
6. **Message/social content is private.** Raw message text stays on device. Off-device LLM use (if
   ever enabled) is opt-in, per-feature, and receives only already-summarized, non-biometric text.
7. **Frame budget.** Camera frame processing never blocks the JS thread; per-frame work runs in
   worklets/native. The lens must hold 30 fps on the target device.

## The build model: master → builders → reviewers

Work is orchestrated, not free-for-all. There are three roles.

- **Master** (the main session). Owns planning, scaffolding, GitHub issues, dispatching subagents,
  reviewing their PRs via reviewer agents, merging, and release. Master does NOT implement features
  by hand — it delegates. The only things master edits directly are repo-wide scaffold/config
  (`AGENTS.md`, `CLAUDE.md`, `eslint.config.mjs`, `app.config.ts`, `eas.json`, `vitest.config.ts`,
  the `src/lib/types.ts` contract, `src/lib/seams.ts`, CI, `.claude/**`) and merge/release glue.
- **Builder** subagent. Implements exactly one GitHub issue in an isolated git worktree, on its own
  branch, and opens one PR. Nothing more.
- **Reviewer** subagent. Reviews one PR read-only and returns APPROVE / REQUEST_CHANGES with concrete
  findings. Never edits code, never posts to GitHub — it reports to master.

Every change reaches `main` through: **issue → builder PR → reviewer → master merges**.
No direct-to-main feature commits.

### Issues

- One issue = one PR = one agent. Right-size accordingly; if an issue needs 3+ agents, it is too big —
  split it.
- Label every issue with a wave (`wave-1` … `wave-4`) and a model tier
  (`model:haiku` | `model:sonnet` | `model:opus`).
- Waves gate dependencies: a wave only starts when the issues it depends on are merged. Issues within
  a wave must be independent enough to run in parallel; where a soft dependency exists, the
  depended-on interface is stubbed behind an injected seam so both can proceed (pattern:
  `src/lib/seams.ts`).

### Model tiers (pick by complexity)

- **haiku** — trivial/mechanical: config, copy, pure single-purpose modules, docs, fixtures.
- **sonnet** — standard features: screens, UI components, connectors/importers with a clear spec.
- **opus** — load-bearing logic: the recognition/matching pipeline, frame processors, concurrency,
  the people-graph store and identity resolution, crypto/credentials, cross-module integration.

### Builder rules

- Work in your assigned isolated worktree. Create branch `issue/<n>-<slug>`. Run `pnpm install` first
  (worktrees have no `node_modules`; the registry is occasionally flaky — retry).
- Read the shared contract `src/lib/types.ts` and the modules you depend on before writing. Reuse
  existing modules; do not reimplement crypto, the store, the matcher, connectors' OAuth, etc.
- Do NOT modify `src/lib/types.ts`, `src/lib/seams.ts` or `src/lib/store/schema.ts` unless the issue
  is explicitly about them — flag needed contract changes to master instead.
- Keep cross-issue couplings behind injected/optional seams so your PR merges without the other issue.
- All three checks must pass before you open the PR:
  `pnpm exec eslint .`, `pnpm exec tsc --noEmit`, `pnpm exec vitest run`.
- Tests live in `tests/**/*.test.ts` — that is the only glob vitest runs. A test file anywhere else
  (e.g. colocated in `src/`) silently never runs. Keep logic in pure TS modules under `src/lib/**` so
  it is testable without a device; React Native/native code stays thin. Device e2e flows (Maestro)
  live in `e2e/` and are deliberately outside that glob.
- Never commit real personal data, real face images, or tokens. Test fixtures are synthetic.
- PR body: `Closes #<n>`, what changed, how verified, notes for reviewers, any deviations.
- Commit messages end with a `Co-Authored-By:` line naming the model that actually wrote the change,
  e.g. `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

### Reviewer rules

- Read-only from the main repo dir; do not check out the branch or edit.
- Use `gh pr view/diff/checks <n>`, read the issue spec, verify against the actual code (not the PR's
  self-report).
- Scrutinize the issue's load-bearing invariant hardest — for this project usually one of the
  product invariants above (known-people-only, biometrics-on-device, confirm-before-recognize,
  open-set match correctness, credential safety, frame budget) or test discovery.
- Verify claims against installed dependency versions when an API is in question (Expo SDK,
  VisionCamera, Skia, expo-sqlite). Read `node_modules/<pkg>` types/docs. Don't trust training data.
- Return APPROVE or REQUEST_CHANGES with `file:line`, the problem, and a concrete fix. Skip style nits.
  Report to master; do not comment on the PR.

### Master merge flow

- On REQUEST_CHANGES: send the finding back to the same builder (resume it) to fix on its branch;
  re-verify CI.
- Merge with `gh pr merge <n> --squash`. Do NOT `--delete-branch` (worktree lock) — clean up after the
  wave.
- Dep-adding PRs conflict on `pnpm-lock.yaml`. Merge one, then have the next builder
  `git merge origin/main` and regenerate the lock with `pnpm install` (never hand-merge the lockfile).
- After each wave: `git checkout main && git pull`, remove `.claude/worktrees`, `git worktree prune`,
  delete merged branches, then verify integrated main (all three checks) before starting the next wave.
- File non-blocking review findings as follow-up issues rather than blocking a merge.

## Repeatable workflows (playbooks)

Repeatable procedures are bundled as skills under `.claude/skills/<name>/SKILL.md`. They are plain
markdown, so any agent can follow them by reading the file:

| Skill | Who runs it | What it does |
|-------|-------------|--------------|
| `plan-wave` | master | Turn `docs/PLAN.md` items into right-sized, labeled GitHub issues |
| `dispatch-wave` | master | Fan out builders for a wave, run reviewers, merge loop |
| `build-issue` | builder | Implement one issue end-to-end and open the PR |
| `review-pr` | reviewer | Read-only review returning APPROVE / REQUEST_CHANGES |
| `close-wave` | master | Post-wave cleanup and integrated-main verification |
| `new-skill` | master | Capture a newly repeated procedure as a skill |

## Stack

- Expo SDK 58 (RN 0.88, dev client — not Expo Go), New Architecture, TypeScript strict,
  `expo-router` (routes in `src/app/`).
- Camera: `react-native-vision-camera` v5 (Nitro; frame processors via `react-native-worklets`
  `useFrameOutput`) + an ML Kit/Nitro face detection plugin. Face embeddings via an on-device model
  run in a local Expo native module (CoreML) or `react-native-fast-tflite`. **Model weights must have a
  license compatible with our use — InsightFace pretrained weights are non-commercial. Record the
  provenance of any weights in `docs/MODELS.md`.**
- Overlay: `@shopify/react-native-skia` (holographic label shaders).
- Local store: `expo-sqlite` with `useSQLCipher: true` (verify with `PRAGMA cipher_version` — without
  SQLCipher `PRAGMA key` silently does nothing); embeddings matched in-memory.
- Data sources reality (verified 2026-11): Google Photos = Picker API only (user-picked items);
  Instagram personal accounts = "Download your information" export import only; X = OAuth API,
  pay-per-use (~$0.01/resource) or archive import; iMessage = no iOS API, macOS `chat.db` via a Mac
  companion. Do not build against APIs that no longer exist.
- Server: minimal Vercel functions only for OAuth flows that need a client secret. No user data stored.
- Package manager: pnpm. Tests: vitest (`tests/**`), Maestro (`e2e/**`). Builds: EAS.

## Layout

```
src/app/            expo-router screens
src/lib/types.ts    shared contract (master-owned)
src/lib/seams.ts    injected-hook registry for cross-issue couplings (master-owned)
src/lib/<module>/   pure TS logic (matcher, graph, importers, label builder, ...)
src/native/         thin RN/native adapters (camera, photos, secure store)
modules/            local Expo native modules (Swift)
server/             Vercel OAuth proxy
tests/              vitest — the ONLY place unit tests run from
e2e/                Maestro flows
docs/               plan and design notes
```
