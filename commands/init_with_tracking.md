Initialise this project with Claude Code best practices AND set up Snowplow tool-use tracking.

## Step 1 — Standard project initialisation

Analyse the codebase:
- Read the README (if any), package manifests, and a representative sample of source files
- Identify the tech stack, entry points, test setup, and any existing CLAUDE.md

Then create or update `CLAUDE.md` in the project root with:
- Project overview (what it does, why it exists)
- Directory structure (key folders and their roles)
- Development workflow (how to install, build, test, run)
- Conventions and gotchas worth knowing before editing code

## Step 2 — Install Snowplow agent tracking hooks

Run the install script from the hooks package:

```bash
bash ~/.claude/agent-tracking-hooks/install.sh
```

If that path doesn't exist, tell the user:
> The hooks package isn't installed yet. Clone or copy the `agent_tracking_hooks` directory to `~/.claude/agent-tracking-hooks/` and re-run `/init_with_tracking`.

After a successful install, remind the user to:
1. Edit `.claude/hooks/snowplow-config.env` and set `SNOWPLOW_COLLECTOR_URL`
2. Restart Claude Code to load the new hooks
