# agent-tool-tracker

Snowplow event tracking hooks for [Claude Code](https://claude.ai/code). Fires an async event before and after every tool invocation, giving you a full audit trail of what the agent did, how long each tool took, and how many tokens were consumed.

---

## Quick install

```bash
git clone https://github.com/jonathanmalloy120/agent-tool-tracker.git ~/.claude/agent-tracking-hooks
bash ~/.claude/agent-tracking-hooks/install.sh --global
```

`--global` registers the hooks in `~/.claude/settings.json` so they run automatically in **every Claude Code project** on your machine — no per-project setup needed.

Then set your collector URL:

```bash
# Edit and set SNOWPLOW_COLLECTOR_URL
nano ~/.claude/agent-tracking-hooks/hooks/snowplow-config.env
```

Restart Claude Code to load the hooks.

### Per-project install

To install into a single project instead of globally:

```bash
bash ~/.claude/agent-tracking-hooks/install.sh              # current directory
bash ~/.claude/agent-tracking-hooks/install.sh /path/to/project
```

Per-project install copies the hook scripts into `.claude/hooks/` and registers them in the project's `.claude/settings.json`. Useful if you want different collector URLs per project or don't want tracking on every project.

### `/init_with_tracking` slash command

Both install modes register an `/init_with_tracking` global slash command. Run it inside any Claude Code project to initialise the project (creates `CLAUDE.md`) and set up tracking hooks in one step.

---

## Prerequisites

| Dependency | Required | Notes |
|---|---|---|
| `jq` | **Yes** | Parses hook payload and builds Iglu JSON. Hooks silently no-op if missing. `brew install jq` / `apt install jq` |
| `curl` | **Yes** | POSTs events to the collector. Present on most systems. |
| `python3` | No | Millisecond-precision timestamps and transcript token parsing. Falls back gracefully if absent. |

---

## How it works

Claude Code's hook system lets you attach shell commands to tool lifecycle events. This package registers three:

| Hook event | Script | Fires |
|---|---|---|
| `PreToolUse` | `pre-tool-use.sh` | Immediately before every tool call |
| `PostToolUse` | `post-tool-use.sh` | After every successful tool call |
| `PostToolUseFailure` | `post-tool-use.sh` | After every failed tool call |

Both scripts run synchronously inside the hook process. Claude Code's `async: true` setting handles non-blocking execution for the post hook — Claude Code fires it and moves on immediately without waiting for it to finish.

The pre-hook writes a start timestamp to a temp file; the post-hook reads it to calculate `duration_ms`, then deletes it.

---

## What `install.sh` does

### Global install (`--global`)

- Registers hook scripts (from the cloned package directory) in `~/.claude/settings.json` using their absolute paths
- Creates `~/.claude/agent-tracking-hooks/hooks/snowplow-config.env` from the example template (skips if already present)
- Copies `commands/init_with_tracking.md` to `~/.claude/commands/` (skips if already present)

### Project install (no flag)

- Copies `pre-tool-use.sh` and `post-tool-use.sh` into `.claude/hooks/`
- Creates `.claude/hooks/snowplow-config.env` from the example template (skips if already present)
- Deep-merges the hook registration block into `.claude/settings.json` — appends to existing hooks, deduplicates on re-run, preserves all other settings
- Copies `commands/init_with_tracking.md` to `~/.claude/commands/` (skips if already present)
- Adds `.claude/hooks/snowplow-config.env` to `.gitignore`

```bash
# Global (recommended)
bash install.sh --global

# Project — current directory
bash install.sh

# Project — specific path
bash install.sh /path/to/project
```

---

## Iglu schemas

The `schemas/` directory contains self-describing JSON schemas for both events under the vendor path `com.anthropic.claude_code`. Deploy them so your collector can validate incoming events.

**Snowplow Micro (local dev):**

The schemas live in the package and are mounted directly from there — no need to copy them per-project. After the quick install, run:

```bash
bash ~/.claude/agent-tracking-hooks/start-snowplow-micro.txt
```

This mounts `~/.claude/agent-tracking-hooks/schemas/` into Micro and starts the collector on `http://0.0.0.0:9090`.

**Static Iglu registry** — copy the `schemas/` tree into your registry repo at the same path structure.

---

## Data collected

### `pre_tool_use`

| Field | Type | Notes |
|---|---|---|
| `timestamp` | string (datetime) | UTC, ms precision if python3 available |
| `session_id` | string | Claude Code session ID |
| `tool_use_id` | string | Per-invocation ID (optional) |
| `tool_name` | string | e.g. `Write`, `Bash`, `Grep` |
| `tool_input_json` | string | Input JSON — large content fields stripped, truncated to 500 chars |
| `cwd` | string | Working directory |
| `transcript_path` | string | Path to session transcript JSONL |

### `post_tool_use`

All fields above, plus:

| Field | Type | Notes |
|---|---|---|
| `success` | boolean | `false` when fired by `PostToolUseFailure` |
| `tool_output_json` | string | Output JSON truncated to 1000 chars |
| `tool_output_length` | integer | Original output byte length before truncation |
| `duration_ms` | integer | ms between pre and post hooks (optional) |
| `input_tokens` | integer | From transcript (optional) |
| `output_tokens` | integer | From transcript (optional) |

---

## Verify it's working

Start Snowplow Micro and run any Claude Code tool, then check:

```bash
curl http://0.0.0.0:9090/micro/all
# {"total":N,"good":N,"bad":0}
```

If `bad > 0`, the events are reaching the collector but failing schema validation — check your schema deployment.

If `total` stays at 0:
1. Confirm `jq` is installed: `which jq`
2. Confirm `SNOWPLOW_COLLECTOR_URL` is set in the config file
3. Run the hook manually to debug:
   ```bash
   echo '{"session_id":"test","tool_name":"Write","tool_input":{"file_path":"/tmp/x"},"cwd":"/tmp","transcript_path":""}' \
     | bash -x ~/.claude/agent-tracking-hooks/hooks/pre-tool-use.sh
   ```

---

## Manual installation

<details>
<summary>Expand for manual steps (without install.sh)</summary>

**1. Copy hook scripts**

```bash
mkdir -p .claude/hooks
cp hooks/pre-tool-use.sh hooks/post-tool-use.sh .claude/hooks/
chmod +x .claude/hooks/pre-tool-use.sh .claude/hooks/post-tool-use.sh
```

**2. Configure the collector URL**

```bash
cp hooks/snowplow-config.env.example .claude/hooks/snowplow-config.env
# Edit and set SNOWPLOW_COLLECTOR_URL
echo '.claude/hooks/snowplow-config.env' >> .gitignore
```

**3. Register hooks in `.claude/settings.json`**

```json
{
  "hooks": {
    "PreToolUse":        [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/pre-tool-use.sh" }] }],
    "PostToolUse":       [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/post-tool-use.sh", "async": true }] }],
    "PostToolUseFailure":[{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/post-tool-use.sh", "async": true }] }]
  }
}
```

See `hooks/settings.json.example` for the full reference.

</details>

---

## File reference

```
agent-tool-tracker/
├── README.md
├── install.sh                                        # Installer (--global or per-project)
├── commands/
│   └── init_with_tracking.md                         # /init_with_tracking slash command
├── hooks/
│   ├── pre-tool-use.sh                               # PreToolUse hook
│   ├── post-tool-use.sh                              # PostToolUse + PostToolUseFailure hook
│   ├── snowplow-config.env.example                   # Collector URL template
│   └── settings.json.example                         # Hook registration reference
├── schemas/
│   └── com.anthropic.claude_code/
│       ├── pre_tool_use/jsonschema/1-0-0
│       └── post_tool_use/jsonschema/1-0-0
└── start-snowplow-micro.txt                          # Docker command for local Snowplow Micro
```
