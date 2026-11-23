# CLAUDE.md

@AGENTS.md

## Claude Code mechanics for the build model

- **Builders**: spawn with the Agent tool, `subagent_type: "builder"` (`.claude/agents/builder.md`),
  `isolation: "worktree"`, and `model` set from the issue's tier label (`haiku` | `sonnet` | `opus`).
  One agent per issue. Launch every issue of a wave in a single message so they run concurrently.
- **Reviewers**: `subagent_type: "reviewer"` (`.claude/agents/reviewer.md`), no isolation, `model: "opus"`
  for issues labeled `model:opus`, otherwise `sonnet`.
- **Fixes**: on REQUEST_CHANGES, resume the same builder with SendMessage (keeps its worktree and
  context) rather than spawning a new one.
- **Skills**: invoke the playbooks in `.claude/skills/` (`/plan-wave`, `/dispatch-wave`, `/close-wave`,
  `/new-skill`). Builders and reviewers load `build-issue` / `review-pr` themselves.
- When a procedure is repeated a second time, capture it with `/new-skill` instead of re-deriving it.
- Never fabricate a subagent's result; wait for its notification.
