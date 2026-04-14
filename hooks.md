# Claude Code Snowplow Tracking Hooks

Sends a Snowplow event to a collector before and after every Claude Code tool invocation, giving you a full audit trail of what the agent did, how long each tool took, and how many tokens were consumed.

## Events

| Schema | Hook | Description |
|---|---|---|
| `iglu:com.anthropic.claude_code/pre_tool_use/jsonschema/1-0-0` | `PreToolUse` | Fires before every tool call. Records tool name, sanitised input metadata, and session context. |
| `iglu:com.anthropic.claude_code/post_tool_use/jsonschema/1-0-0` | `PostToolUse` + `PostToolUseFailure` | Fires after every tool call. Adds success flag, truncated output, duration (paired with pre event via temp file), and token counts from the transcript. |

Both events are **fire-and-forget** (`async: true` + backgrounded `curl`). They do not block Claude.

---

## Prerequisites

| Dependency | Required | Notes |
|---|---|---|
| `jq` | **Yes** | Used to parse the hook payload from stdin and build the Iglu JSON. Hooks silently no-op if missing. Install: `brew install jq` (macOS) or `apt install jq` (Debian/Ubuntu). |
| `curl` | **Yes** | Sends the HTTP POST to the collector. Present on most systems by default. |
| `python3` | No | Used for millisecond-precision timestamps and transcript token parsing. Falls back to second-precision `date` if absent. |

---

## Installation

### Automatic (recommended)

```bash
git clone <this-repo> ~/.claude/agent-tracking-hooks
bash ~/.claude/agent-tracking-hooks/install.sh
```

`install.sh` does everything in one shot:
- Copies hook scripts into `.claude/hooks/` of the current directory (or a path you pass as `$1`)
- Creates `snowplow-config.env` from the example template
- Merges the hook registration block into `.claude/settings.json` (non-destructive — appends to any existing hooks)
- Installs the `/init_with_tracking` Claude Code slash command to `~/.claude/commands/`
- Adds `snowplow-config.env` to `.gitignore`

After install, edit `.claude/hooks/snowplow-config.env` and set `SNOWPLOW_COLLECTOR_URL`, then restart Claude Code.

### `/init_with_tracking` slash command

Once installed, run `/init_with_tracking` inside any Claude Code project to initialise the project (creates `CLAUDE.md`) and set up tracking hooks in one step.

### Manual installation

<details>
<summary>Expand for manual steps</summary>

**1. Copy hook scripts**

```bash
cp -r hooks/ /path/to/your/project/.claude/hooks/
chmod +x .claude/hooks/pre-tool-use.sh
chmod +x .claude/hooks/post-tool-use.sh
```

**2. Configure the collector URL**

```bash
cp .claude/hooks/snowplow-config.env.example .claude/hooks/snowplow-config.env
# Edit and set SNOWPLOW_COLLECTOR_URL
```

`snowplow-config.env` should **not** be committed to version control.

**3. Register hooks in Claude Code settings**

Merge `hooks/settings.json.example` into your project's `.claude/settings.json`. The empty `matcher: ""` means the hooks fire for every tool call:

```json
{
  "hooks": {
    "PreToolUse":        [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/pre-tool-use.sh", "async": true }] }],
    "PostToolUse":       [{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/post-tool-use.sh", "async": true }] }],
    "PostToolUseFailure":[{ "matcher": "", "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/post-tool-use.sh", "async": true }] }]
  }
}
```

</details>

### Deploy the Iglu schemas

The `schemas/` directory contains the self-describing JSON schemas for both events. You need to make these available to your Iglu resolver so the collector can validate incoming events.

**Option A — Snowplow Micro (local development)**

Add the `schemas/` directory to Micro's schema registry. In your `micro.conf`:

```hocon
iglu {
  repositories = [
    {
      name = "local-schemas"
      priority = 0
      vendorPrefixes = ["com.anthropic"]
      connection = {
        embedded { path = "/path/to/agent_tracking_hooks/schemas" }
      }
    }
  ]
}
```

**Option B — Static Iglu registry**

Copy the `schemas/` tree into your static registry repo under the standard path:

```
schemas/
  com.anthropic.claude_code/
    pre_tool_use/jsonschema/1-0-0
    post_tool_use/jsonschema/1-0-0
```

**Option C — Skip validation (development only)**

Configure Micro to use `iglucentral` only and ignore unknown schemas. Events will be accepted but not schema-validated.

---

## Verify it's working

With Snowplow Micro running, start a Claude Code session and use any tool. Then check:

```bash
curl http://0.0.0.0:9090/micro/all
# {"total":N,"good":N,"bad":0}
```

If `bad > 0`, check the schema deployment — the events are reaching the collector but failing validation:

```bash
curl http://0.0.0.0:9090/micro/bad
```

If `total` stays at 0 after tool use:
1. Confirm `jq` is installed: `which jq`
2. Confirm `SNOWPLOW_COLLECTOR_URL` is set in `snowplow-config.env`
3. Run the hook manually to debug:
   ```bash
   echo '{"session_id":"test","tool_name":"Write","tool_input":{"file_path":"/tmp/x"},"cwd":"/tmp","transcript_path":""}' \
     | bash -x .claude/hooks/pre-tool-use.sh
   ```

---

## File reference

```
agent_tracking_hooks/
├── hooks.md                                          # This file
├── install.sh                                        # One-shot installer (run this first)
├── commands/
│   └── init_with_tracking.md                         # /init_with_tracking Claude Code slash command
├── hooks/
│   ├── pre-tool-use.sh                               # PreToolUse hook script
│   ├── post-tool-use.sh                              # PostToolUse + PostToolUseFailure hook script
│   ├── snowplow-config.env.example                   # Collector URL config template
│   ├── settings.json.example                         # Claude Code hook registration config (reference)
│   └── available-tools.json                          # Tool list populated at session start (starts empty)
├── schemas/
│   └── com.anthropic.claude_code/
│       ├── pre_tool_use/jsonschema/1-0-0             # Iglu schema for pre-tool-use events
│       └── post_tool_use/jsonschema/1-0-0            # Iglu schema for post-tool-use events
└── start-snowplow-micro.txt                          # Docker command to run Snowplow Micro locally
```

## Data collected

### pre_tool_use

| Field | Type | Notes |
|---|---|---|
| `timestamp` | string (datetime) | UTC, ms precision if python3 available |
| `session_id` | string | Claude Code session ID |
| `tool_use_id` | string | Per-invocation ID (optional) |
| `tool_name` | string | e.g. `Write`, `Bash`, `Grep` |
| `tool_input_json` | string | Input JSON, large fields stripped, truncated to 500 chars |
| `cwd` | string | Working directory |
| `transcript_path` | string | Path to session transcript JSONL |
| `available_tools` | string[] | Tools available in this session (optional) |

### post_tool_use

All fields above, plus:

| Field | Type | Notes |
|---|---|---|
| `success` | boolean | `false` when fired by `PostToolUseFailure` |
| `tool_output_json` | string | Output JSON truncated to 1000 chars |
| `tool_output_length` | integer | Original output byte length before truncation |
| `duration_ms` | integer | ms between pre and post hooks (optional) |
| `input_tokens` | integer | From transcript (optional) |
| `output_tokens` | integer | From transcript (optional) |
