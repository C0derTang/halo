---
name: merge-when-green
description: Master playbook — after a reviewer returns APPROVE, wait for the PR's CI, retry once on macOS runner-capacity failures, and squash-merge when green. Use for every approved PR.
---

# merge-when-green

Input: one or more PR numbers whose reviewer verdict is APPROVE (no open blocking items).

1. Run in the background (it blocks until CI finishes):
   `.claude/skills/merge-when-green/scripts/merge-when-green.sh <pr> [<pr>...]`
2. Read its output when notified:
   - `#N merged` — done.
   - `#N merge failed (conflict?)` — tell the builder to `git merge origin/main`, re-run checks, push;
     then re-run this skill.
   - `#N CI FAILED: ...` — send the quoted lines to the same builder as REQUEST_CHANGES.
3. Never merge a PR whose reviewer verdict is REQUEST_CHANGES, and never use `--delete-branch`.
