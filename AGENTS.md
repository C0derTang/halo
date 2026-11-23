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
5. **Credential safety.** Tokens and pairing keys (e.g. Mac bridge ↔ phone) live only in the
   Keychain. No secrets in the repo or the app bundle.
6. **Message content is private.** Message data stays on the user's own devices (Mac → iPhone).
   No off-device AI: summaries use on-device Foundation Models only.
7. **Frame budget.** Camera/vision work never runs on the main actor; embedding is throttled per
   track. The lens must hold 30 fps on the target iPhone.

## The build model: master → builders → reviewers

Work is orchestrated, not free-for-all. There are three roles.

- **Master** (the main session). Owns planning, scaffolding, GitHub issues, dispatching subagents,
  reviewing their PRs via reviewer agents, merging, and release. Master does NOT implement features
  by hand — it delegates. The only things master edits directly are repo-wide scaffold/config
  (`AGENTS.md`, `CLAUDE.md`, `Packages/HaloKit/Package.swift`, `App/project.yml`, `App/Halo/RootView.swift`,
  `.swift-format`, `scripts/check.sh`, the `HaloCore` contract `Contract.swift` + `Seams.swift`, CI,
  `.claude/**`) and merge/release glue.
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
  `Packages/HaloKit/Sources/HaloCore/Seams.swift` — protocols with safe defaults).

### Model tiers (pick by complexity)

- **haiku** — trivial/mechanical: config, copy, pure single-purpose modules, docs, fixtures.
- **sonnet** — standard features: SwiftUI screens, UI components, importers with a clear spec.
- **opus** — load-bearing logic: the recognition/matching pipeline, frame processors, concurrency,
  the people-graph store and identity resolution, crypto/credentials, cross-module integration.

### Builder rules

- Work in your assigned isolated worktree. Create branch `issue/<n>-<slug>`. First build resolves
  SwiftPM dependencies (GitHub is occasionally flaky — retry).
- Read the shared contract (`HaloCore/Contract.swift`, `HaloCore/Seams.swift`) and the modules you
  depend on before writing. Reuse existing modules; do not reimplement the store, matcher, vision
  pipeline, digest format, etc.
- Do NOT modify `Contract.swift`, `Seams.swift`, `Package.swift`, `App/project.yml`, or
  `HaloStore`'s schema/migrations unless the issue is explicitly about them — flag needed contract,
  target or dependency changes to master instead. Each issue owns one target (or one app folder);
  stay inside it. Delete the target's `Placeholder.swift` / `PlaceholderTests.swift` when you replace it.
- Keep cross-issue couplings behind the seam protocols so your PR merges without the other issue.
- All three checks must pass before you open the PR: `./scripts/check.sh`
  (1 `swift format lint --strict`, 2 `swift test` on HaloKit, 3 `xcodebuild` of the iOS app).
  Without Xcode locally, the script builds only — then CI is the gate: push, open the PR as draft,
  `gh pr checks <n> --watch`, and mark ready only when green.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) and live in
  `Packages/HaloKit/Tests/<Target>Tests/` — the only declared test targets. A test file anywhere else
  (e.g. under `Sources/` or `App/`) silently never runs. Keep logic in HaloKit so it is testable on the
  macOS host; `App/` stays thin (views + wiring). Device e2e flows live in `e2e/`.
- Never commit real personal data, real face images, tokens, or model weights (the repo is public).
  Test fixtures are synthetic; weights are fetched by `scripts/fetch-models.sh`.
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
- Verify claims against installed dependency versions when an API is in question (GRDB in
  `Packages/HaloKit/.build/checkouts/`, Apple SDK headers/`.swiftinterface` files). Don't trust
  training data — iOS 26 APIs changed.
- Return APPROVE or REQUEST_CHANGES with `file:line`, the problem, and a concrete fix. Skip style nits.
  Report to master; do not comment on the PR.

### Master merge flow

- On REQUEST_CHANGES: send the finding back to the same builder (resume it) to fix on its branch;
  re-verify CI.
- Merge with `gh pr merge <n> --squash`. Do NOT `--delete-branch` (worktree lock) — clean up after the
  wave.
- Dependencies and targets are added by master on main (`Package.swift`), so builders don't conflict on
  `Package.resolved`. If one does conflict: `git merge origin/main`, then `swift package resolve`
  to regenerate it (never hand-merge it).
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
| `merge-when-green` | master | Wait for CI on approved PRs, retry runner failures, squash-merge |
| `close-wave` | master | Post-wave cleanup and integrated-main verification |
| `new-skill` | master | Capture a newly repeated procedure as a skill |

## Stack

- Native iOS 26: Swift 6 (strict concurrency), SwiftUI, AVFoundation, Vision, CoreML, PhotoKit,
  Contacts, LocalAuthentication, Foundation Models (on-device LLM). Personal prototype, iPhone only.
- `Packages/HaloKit` — SwiftPM package holding all logic, one target per module, tested on the macOS
  host with Swift Testing. Only third-party dependency: GRDB (SQLite).
- `App/` — thin SwiftUI app; the Xcode project is generated by XcodeGen from `App/project.yml`
  (never commit or hand-edit `Halo.xcodeproj`).
- `halo-bridge` — macOS CLI (same package) that reads `~/Library/Messages/chat.db` (needs Full Disk
  Access) and emits a metadata-only `InteractionDigest`.
- Face embeddings: CoreML model fetched by `scripts/fetch-models.sh` (gitignored). Personal-use
  prototype, so research-licensed weights are acceptable but are never committed or redistributed;
  provenance recorded in `docs/MODELS.md`. Apple Vision provides detection/landmarks/quality only — it
  has no public recognition embedding.
- Storage: GRDB database file with iOS Data Protection `.complete`; embeddings matched in-memory.
- AI: on-device only (Foundation Models). No off-device LLM calls.
- CI: GitHub Actions `macos-latest` runs `./scripts/check.sh` on every PR and push to main. **CI has an
  older toolchain (Xcode 26.6 / Swift 6.2) than local dev (Xcode 27.2 / Swift 6.4): code must compile on
  both.** Avoid Swift 6.3+ only features (e.g. typed throws through `rethrows` closures such as
  `withUnsafeBytes`); when in doubt, use untyped `throws`. A PR is not mergeable until CI is green.
- Data sources (verified 2026-11): Contacts + Apple Photos (on-device), iMessage via Mac bridge.
  Later: Google Photos (Picker API only — no whole-library access), Instagram (export import only —
  no personal-account API), X (OAuth, pay-per-use, or archive import).

## Layout

```
Packages/HaloKit/Package.swift          targets + deps (master-owned)
Packages/HaloKit/Sources/HaloCore/      Contract.swift + Seams.swift (master-owned)
Packages/HaloKit/Sources/<Target>/      one module per issue (Store, Matching, Clustering, Tracking,
                                        Vision, Import, Labels, Lens, UI, BridgeKit)
Packages/HaloKit/Sources/halo-bridge/   macOS iMessage bridge CLI
Packages/HaloKit/Tests/<Target>Tests/   Swift Testing — the ONLY place tests run from
App/project.yml                         XcodeGen spec (master-owned)
App/Halo/<Feature>/                     SwiftUI screens (Lens, People, Settings, Onboarding)
scripts/check.sh                        the three checks (CI runs the same)
e2e/                                    device test notes / UI test plans
docs/                                   PLAN.md, MODELS.md
```
