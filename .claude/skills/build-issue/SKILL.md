---
name: build-issue
description: Builder playbook — implement one GitHub issue in an isolated worktree and open one PR. Use when dispatched as a builder for issue #<n>.
---

# build-issue

Input: an issue number `<n>`. You are already in an isolated worktree.

1. **Read the spec.** `gh issue view <n>`. Note acceptance criteria, the load-bearing invariant, the
   wave, the model tier, and any seams you must stub or consume.
2. **Branch.** `git checkout -b issue/<n>-<short-slug>`.
3. **Resolve.** `swift package resolve --package-path Packages/HaloKit` (retry up to 3 times).
4. **Read before writing.** `HaloCore/Contract.swift`, `HaloCore/Seams.swift`, and every module the
   issue depends on. Reuse them. If the contract, `Package.swift` or `project.yml` needs a change,
   stop and report the exact proposed diff to master instead of editing it.
5. **Implement.** Logic in `Packages/HaloKit/Sources/<YourTarget>/`; `App/` code stays thin.
   Cross-issue couplings go through the `Seams.swift` protocols so this PR merges without the other
   issue. Replace (delete) your target's `Placeholder.swift`.
6. **Test.** Swift Testing files in `Packages/HaloKit/Tests/<YourTarget>Tests/` (the ONLY discovered
   location); delete `PlaceholderTests.swift`. Cover the invariant the issue names, edge cases and
   failure paths. Synthetic fixtures only — no real faces/data.
7. **Verify — must pass:** `./scripts/check.sh` then `swift format -i` anything it flags.
   If Xcode isn't installed locally the script only builds; open the PR as **draft**, run
   `gh pr checks <pr> --watch`, fix until green, then `gh pr ready <pr>`. Confirm your new tests
   appear in the CI test log (test discovery is a review item).
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
If master asks you to pick up a main change: `git merge origin/main`; on a `Package.resolved`
conflict run `swift package resolve` to regenerate it (never hand-merge it), re-run checks, push.
