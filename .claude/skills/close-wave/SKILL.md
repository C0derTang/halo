---
name: close-wave
description: Master playbook — after a wave is merged, clean worktrees/branches and verify integrated main before the next wave. Use with argument "wave-N".
---

# close-wave

1. Confirm `gh issue list --label wave-N --state open` is empty (except deliberate follow-ups).
2. Sync and clean:
   ```sh
   git checkout main && git pull --ff-only
   rm -rf .claude/worktrees
   git worktree prune
   git branch --merged main | grep 'issue/' | xargs -r git branch -d
   git ls-remote --heads origin 'issue/*'   # delete remote branches whose PRs merged:
   # git push origin --delete issue/<n>-<slug>
   ```
3. Verify integrated main from a clean install:
   ```sh
   ./scripts/check.sh
   gh run list --branch main --limit 1   # CI on main must be green (authoritative without Xcode)
   ```
   If anything fails, file a `wave-N` fix issue and dispatch one builder; do not start wave N+1.
4. Update `docs/PLAN.md` (mark wave done, note follow-ups) — scaffold commit by master.
5. Report: merged PRs, follow-ups filed, check results, readiness for wave N+1.
