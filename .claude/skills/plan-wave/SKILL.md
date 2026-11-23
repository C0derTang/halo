---
name: plan-wave
description: Master playbook — turn docs/PLAN.md items into right-sized, labeled GitHub issues (wave-N, model tier). Use when starting a project phase or when the plan changes.
---

# plan-wave

1. Ensure labels exist (idempotent):
   ```sh
   for l in wave-1 wave-2 wave-3 wave-4 model:haiku model:sonnet model:opus follow-up; do
     gh label create "$l" --force >/dev/null; done
   ```
2. For each plan item, check sizing: one issue = one PR = one agent. If it would need 3+ agents or
   touches more than one load-bearing invariant, split it.
3. Assign the wave by dependency: an issue goes in the earliest wave where everything it hard-depends
   on is merged. Soft dependencies → add a seam to `src/lib/seams.ts` (master edits it first) and keep
   both issues in the same wave.
4. Assign the model tier (AGENTS.md "Model tiers").
5. Create the issue with this body:
   ```
   ## Goal
   ## Scope (files/modules)        ## Out of scope
   ## Contract                     (types from src/lib/types.ts it uses/produces; seams it fills/consumes)
   ## Load-bearing invariant       (the one thing the reviewer must verify hardest)
   ## Acceptance criteria          (testable bullets; name the test files under tests/)
   ## Depends on                   (#issues, or "none")
   ```
   `gh issue create --title "<title>" --body-file <tmp> --label wave-N --label model:<tier>`
6. Update `docs/PLAN.md` with the issue numbers.
