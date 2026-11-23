#!/usr/bin/env bash
# Usage: merge-when-green.sh <pr> [<pr>...]
# For each APPROVED PR (reviewer verdict, not GitHub review): wait for CI, rerun once on runner
# capacity failure, squash-merge when green (no --delete-branch). Prints one line per PR.
set -uo pipefail
for p in "$@"; do
  # Wait (up to 10 min) for a check run to be registered after a fresh push.
  for _ in $(seq 1 40); do
    gh pr checks "$p" 2>&1 | grep -q "no checks reported" || break
    sleep 15
  done
  for attempt in 1 2; do
    gh pr checks "$p" --watch --interval 30 >/dev/null 2>&1
    if gh pr checks "$p" >/dev/null 2>&1; then
      gh pr merge "$p" --squash >/dev/null 2>&1 && echo "#$p merged" || echo "#$p merge failed (conflict?)"
      break
    fi
    run=$(gh pr checks "$p" --json link --jq '.[0].link' | sed 's|.*/runs/||; s|/job.*||')
    if gh run view "$run" 2>&1 | grep -q "not acquired by Runner" && [ "$attempt" = 1 ]; then
      gh run rerun "$run" >/dev/null 2>&1; sleep 20; continue
    fi
    echo "#$p CI FAILED: $(gh run view "$run" --log-failed 2>&1 | grep -E 'error:|✘' | head -3)"
    break
  done
done
