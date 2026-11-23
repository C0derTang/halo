---
name: build-issue
description: Builder playbook — implement one GitHub issue in an isolated worktree and open one PR. Use when dispatched as a builder for issue #<n>.
---

# build-issue

Input: an issue number `<n>`. You are already in an isolated worktree.

1. **Read the spec.** `gh issue view <n>`. Note acceptance criteria, the load-bearing invariant, the
   wave, the model tier, and any seams you must stub or consume.
2. **Branch.** `git checkout -b issue/<n>-<short-slug>`.
3. **Install.** `pnpm install` (retry up to 3 times on registry errors).
4. **Read before writing.** `src/lib/types.ts`, `src/lib/seams.ts`, and every module the issue
   depends on. Reuse them. If the contract is missing something, stop and report the proposed diff
   to master instead of editing it.
5. **Implement.** Logic in pure TS under `src/lib/<module>/`; keep RN/native adapters thin.
   Cross-issue couplings go through seams in `src/lib/seams.ts` with a safe default so this PR
   merges without the other issue.
6. **Test.** Add `tests/<module>/*.test.ts` (the ONLY discovered location). Cover the invariant the
   issue names, edge cases, and failure paths. Synthetic fixtures only — no real faces/data.
7. **Verify — all must pass:**
   ```sh
   pnpm exec eslint .
   pnpm exec tsc --noEmit
   pnpm exec vitest run
   ```
   Confirm your new tests appear in the vitest output (test discovery is a review item).
8. **Commit.** Conventional message; last line
   `Co-Authored-By: Claude <your model> <noreply@anthropic.com>`.
9. **PR.** `git push -u origin HEAD` then `gh pr create` with body:
   ```
   Closes #<n>

   ## What changed
   ## How verified   (paste the three check summaries; list new test files)
   ## Notes for reviewers   (where the invariant is enforced, file:line)
   ## Deviations   (or "None")
   ```
10. **Report** to master: PR URL, branch, check results, deviations, contract requests.

On a fix request from master: fix on the same branch, re-run all three checks, push, report again.
If master asks you to rebase onto a lockfile change: `git merge origin/main`, then `pnpm install` to
regenerate `pnpm-lock.yaml` (never hand-merge it), re-run checks, push.
