# agent-tool-tracker

Snowplow event tracking hooks for [Claude Code](https://claude.ai/code). Fires an async event before and after every tool invocation, giving you a full audit trail of what the agent did, how long each tool took, and how many tokens were consumed.

---

## Quick install

```bash
git clone https://github.com/jonathanmalloy120/agent-tool-tracker.git ~/.claude/agent-tracking-hooks
bash ~/.claude/agent-tracking-hooks/install.sh
```

Then edit `.claude/hooks/snowplow-config.env` in your project and set `SNOWPLOW_COLLECTOR_URL`. Restart Claude Code to load the hooks.

### `/init_with_tracking` slash command

The installer also registers an `/init_with_tracking` global slash command. Run it inside any Claude Code project to initialise the project (creates `CLAUDE.md`) and set up tracking hooks in one step.

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

Both scripts are **fire-and-forget** — they background the `curl` POST so they never block Claude.

The pre-hook writes a start timestamp to a temp file; the post-hook reads it to calculate `duration_ms`, then deletes it.

---

## What `install.sh` does

- Copies `pre-tool-use.sh`, `post-tool-use.sh`, and `available-tools.json` into `.claude/hooks/`
- Creates `.claude/hooks/snowplow-config.env` from the example template (skips if already present)
- Deep-merges the hook registration block into `.claude/settings.json` — appends to existing hooks, deduplicates on re-run, preserves all other settings
- Copies `commands/init_with_tracking.md` to `~/.claude/commands/` (skips if already present)
- Adds `.claude/hooks/snowplow-config.env` to `.gitignore`

```bash
# Install into current directory
bash install.sh

# Install into a specific project
bash install.sh /path/to/project
```

---

## Iglu schemas

The `schemas/` directory contains self-describing JSON schemas for both events under the vendor path `com.anthropic.claude_code`. Deploy them so your collector can validate incoming events.

**Snowplow Micro (local dev) — mount the schemas directory:**

```bash
docker run -p 9090:9090 \
  -v "$(pwd)/schemas:/config/iglu-client-embedded/schemas" \
  snowplow/snowplow-micro:latest
```

See `start-snowplow-micro.txt` for the full Docker command used in development.

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
| `available_tools` | string[] | Tools available in this session (optional) |

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
2. Confirm `SNOWPLOW_COLLECTOR_URL` is set in `.claude/hooks/snowplow-config.env`
3. Run the hook manually to debug:
   ```bash
   echo '{"session_id":"test","tool_name":"Write","tool_input":{"file_path":"/tmp/x"},"cwd":"/tmp","transcript_path":""}' \
     | bash -x .claude/hooks/pre-tool-use.sh
   ```

---

## Manual installation

<details>
<summary>Expand for manual steps (without install.sh)</summary>

**1. Copy hook scripts**

```bash
mkdir -p .claude/hooks
cp hooks/pre-tool-use.sh hooks/post-tool-use.sh hooks/available-tools.json .claude/hooks/
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
    "PreToolUse":        [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/pre-tool-use.sh", "async": true }] }],
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
├── install.sh                                        # One-shot installer
├── commands/
│   └── init_with_tracking.md                         # /init_with_tracking slash command
├── hooks/
│   ├── pre-tool-use.sh                               # PreToolUse hook
│   ├── post-tool-use.sh                              # PostToolUse + PostToolUseFailure hook
│   ├── snowplow-config.env.example                   # Collector URL template
│   ├── settings.json.example                         # Hook registration reference
│   └── available-tools.json                          # Tool list (starts empty)
├── schemas/
│   └── com.anthropic.claude_code/
│       ├── pre_tool_use/jsonschema/1-0-0
│       └── post_tool_use/jsonschema/1-0-0
└── start-snowplow-micro.txt                          # Docker command for local Snowplow Micro
```
