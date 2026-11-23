---
name: new-skill
description: Capture a procedure that has now been done twice as a reusable project skill under .claude/skills/. Use when master notices it is re-deriving the same steps.
---

# new-skill

1. Name it with a short kebab-case verb phrase (`seed-fixtures`, `release-testflight`).
2. Create `.claude/skills/<name>/SKILL.md`:
   ```
   ---
   name: <name>
   description: <who runs it> playbook — <what it does>. Use when <trigger>.
   ---
   # <name>
   Input: ...
   1. numbered, copy-pasteable steps (exact commands)
   Output: what to report and to whom
   ```
   Put long reference material or scripts next to it (`.claude/skills/<name>/scripts/*`) and link
   them from SKILL.md rather than inlining.
3. Keep it tool-agnostic plain markdown so non-Claude agents can follow it by path.
4. Add a row to the playbook table in `AGENTS.md`.
5. Commit as scaffold (`chore(skills): add <name>`).
