#!/usr/bin/env bash
# Snowplow pre-tool-use hook for Claude Code
#
# Fires before every tool invocation and sends an Iglu self-describing event
# to a Snowplow collector:
#   iglu:com.anthropic.claude_code/pre_tool_use/jsonschema/1-0-0
#
# Configuration: copy snowplow-config.env.example → snowplow-config.env
# and set SNOWPLOW_COLLECTOR_URL. The hook silently no-ops if the file is
# missing or the URL is unset.
#
# Dependencies: jq, curl (required); python3 (optional, for ms-precision timestamps)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/snowplow-config.env"
TOOLS_FILE="$SCRIPT_DIR/available-tools.json"

# Load collector config
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# No-op if not configured
if [ -z "${SNOWPLOW_COLLECTOR_URL:-}" ]; then
  exit 0
fi

# No-op if required tools are missing
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  exit 0
fi

# Read Claude Code hook payload from stdin
INPUT=$(cat)

# --- Extract fields from hook payload ---
SESSION_ID=$(echo "$INPUT"    | jq -r '.session_id    // ""')
TOOL_USE_ID=$(echo "$INPUT"   | jq -r '.tool_use_id   // ""')
TOOL_NAME=$(echo "$INPUT"     | jq -r '.tool_name     // ""')
TOOL_INPUT_RAW=$(echo "$INPUT"| jq -c '.tool_input    // {}')
CWD=$(echo "$INPUT"           | jq -r '.cwd           // ""')
TRANSCRIPT_PATH=$(echo "$INPUT"| jq -r '.transcript_path // ""')

# --- Timestamps ---
# Use python3 for millisecond precision; fall back to second-precision date.
if command -v python3 >/dev/null 2>&1; then
  TIMESTAMP=$(python3 -c "
from datetime import datetime, timezone
now = datetime.now(timezone.utc)
ms = now.microsecond // 1000
print(now.strftime('%Y-%m-%dT%H:%M:%S.') + str(ms).zfill(3) + 'Z')
")
  START_MS=$(python3 -c "import time; print(int(time.time() * 1000))")
else
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  START_MS=$(( $(date +%s) * 1000 ))
fi

# --- Write start time to temp file for duration tracking in post-hook ---
# Key uses session_id + sanitized tool_name (alphanumeric + underscore only).
SAFE_TOOL=$(echo "$TOOL_NAME" | tr -cd 'a-zA-Z0-9_')
TMPFILE="/tmp/claude_pre_${SESSION_ID}_${SAFE_TOOL}"
echo "$START_MS" > "$TMPFILE"

# --- Strip large content fields, then truncate to 500 chars ---
# Removes known high-volume fields (file content, edit strings) while keeping
# short identifying metadata like file_path, command, pattern, description.
TOOL_INPUT_JSON=$(echo "$TOOL_INPUT_RAW" | jq 'del(.content, .new_string, .old_string)' | head -c 500)

# --- Load available tools list (populated during install) ---
if [ -f "$TOOLS_FILE" ]; then
  AVAILABLE_TOOLS=$(cat "$TOOLS_FILE")
else
  AVAILABLE_TOOLS="[]"
fi

# --- Build Iglu self-describing JSON payload ---
PAYLOAD=$(jq -n \
  --arg schema        "iglu:com.anthropic.claude_code/pre_tool_use/jsonschema/1-0-0" \
  --arg timestamp     "$TIMESTAMP" \
  --arg session_id    "$SESSION_ID" \
  --arg tool_use_id   "$TOOL_USE_ID" \
  --arg tool_name     "$TOOL_NAME" \
  --arg tool_input    "$TOOL_INPUT_JSON" \
  --arg cwd           "$CWD" \
  --arg transcript    "$TRANSCRIPT_PATH" \
  --argjson tools     "$AVAILABLE_TOOLS" \
  '{
    schema: $schema,
    data: (
      {
        timestamp:        $timestamp,
        session_id:       $session_id,
        tool_name:        $tool_name,
        tool_input_json:  $tool_input,
        cwd:              $cwd,
        transcript_path:  $transcript
      }
      + (if $tool_use_id != "" then {tool_use_id: $tool_use_id}   else {} end)
      + (if ($tools | length) > 0 then {available_tools: $tools}  else {} end)
    )
  }')

# --- POST to collector (fire-and-forget, does not block Claude) ---
curl -s --max-time 5 \
  -X POST \
  "${SNOWPLOW_COLLECTOR_URL}/com.snowplowanalytics.iglu/v1" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  > /dev/null 2>&1 &

exit 0
