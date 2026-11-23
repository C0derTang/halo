---
name: review-pr
description: Reviewer playbook — read-only review of one PR against its issue and the product invariants, returning APPROVE or REQUEST_CHANGES to master. Use when dispatched as a reviewer for PR #<n>.
---

# review-pr

Input: PR number `<n>`. Read-only. Do not check out, edit, comment, or approve on GitHub.

1. `gh pr view <n>` — find the linked issue, then `gh issue view <issue>`. Identify the load-bearing
   invariant (see AGENTS.md "Non-negotiable product invariants").
2. `gh pr diff <n>` and `gh pr checks <n>`. Read changed files in full context with
   `git show origin/<branch>:<path>` (fetch first) — not just the hunks.
3. Verify against the code, not the PR description:
   - **Invariants**: known-people-only (no lookup of unknown faces); biometrics never leave device
     (grep the diff for `fetch`, network clients, logging/analytics of crops/embeddings);
     confirm-before-recognize; open-set match rejects below threshold and ambiguous top-2;
     tokens only in secure store, no client secrets in the bundle; frame processor work stays in
     worklets/native.
   - **Contract**: no unauthorized edits to `src/lib/types.ts`, `src/lib/seams.ts`,
     `src/lib/store/schema.ts`.
   - **Test discovery**: new tests are under `tests/**/*.test.ts` and actually exercise the invariant.
   - **APIs**: when a library API is in question, read the installed version under `node_modules/`.
   - Seams have safe defaults; the PR merges cleanly without sibling issues.
4. Skip style nits. File non-blocking items separately as "follow-up".

Output (to master only):
```
VERDICT: APPROVE | REQUEST_CHANGES
BLOCKING:
- path:line — problem — concrete fix
FOLLOW-UP (non-blocking, file as issues):
- path:line — problem — suggested fix
```
