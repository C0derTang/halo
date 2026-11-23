---
name: dispatch-wave
description: Master playbook — fan out one builder per issue in wave N (parallel, isolated worktrees, model by tier label), review each PR, and run the merge loop until the wave is merged. Use with argument "wave-N".
---

# dispatch-wave

Input: `wave-N`.

1. **Preflight.** On `main`, clean tree, previous wave closed (`/close-wave`). Integrated main passes
   all three checks. Every issue this wave hard-depends on is merged.
2. **List.** `gh issue list --label wave-N --state open --json number,title,labels`.
3. **Fan out builders** — one Agent call per issue, all in ONE message so they run concurrently:
   - `subagent_type: "builder"`, `isolation: "worktree"`, `model` from the `model:*` label.
   - Prompt: `Build issue #<n>. Follow .claude/skills/build-issue/SKILL.md.` plus any wave-specific
     note (e.g. which seam to stub).
4. **Review as PRs land.** For each builder report, spawn a `reviewer` agent
   (`model: opus` for `model:opus` issues, else `sonnet`): `Review PR #<pr> for issue #<n>. Follow
   .claude/skills/review-pr/SKILL.md.` Reviews run in parallel with remaining builders.
5. **Merge loop** per PR:
   - REQUEST_CHANGES: SendMessage the blocking findings to the SAME builder; when it reports back,
     re-review (same reviewer via SendMessage).
   - APPROVE + green `gh pr checks`: `gh pr merge <pr> --squash` (no `--delete-branch`).
   - Conflict after a merge: tell the builder to `git merge origin/main` (regenerate
     `Package.resolved` with `swift package resolve`, never hand-merge); re-verify checks.
   - FOLLOW-UP items: `gh issue create --label follow-up` (+ a later wave label).
6. **Contract requests** from builders: master edits `Contract.swift` / `Seams.swift` /
   `Package.swift` on main via a small scaffold commit, then tells affected builders to merge
   `origin/main`.
7. When every wave-N issue is closed, run `/close-wave wave-N`.

Never implement a feature yourself during this loop; never fabricate an agent's result.
