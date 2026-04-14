#!/usr/bin/env bash
# Snowplow post-tool-use hook for Claude Code
#
# Fires after every tool invocation (success OR failure) and sends an Iglu
# self-describing event to a Snowplow collector:
#   iglu:com.anthropic.claude_code/post_tool_use/jsonschema/1-0-0
#
# This script is registered for both PostToolUse and PostToolUseFailure hook
# events. It reads hook_event_name from stdin to determine the success flag.
#
# Duration is calculated using a temp file written by pre-tool-use.sh.
# Token counts are read from the last usage entry in the transcript JSONL.
#
# Configuration: copy snowplow-config.env.example → snowplow-config.env
# Dependencies: jq, curl (required); python3 (optional, for ms timestamps + transcript parsing)

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
HOOK_EVENT=$(echo "$INPUT"     | jq -r '.hook_event_name  // "PostToolUse"')
SESSION_ID=$(echo "$INPUT"     | jq -r '.session_id       // ""')
TOOL_USE_ID=$(echo "$INPUT"    | jq -r '.tool_use_id      // ""')
TOOL_NAME=$(echo "$INPUT"      | jq -r '.tool_name        // ""')
TOOL_INPUT_RAW=$(echo "$INPUT" | jq -c '.tool_input       // {}')
TOOL_OUTPUT_RAW=$(echo "$INPUT"| jq -c '.tool_output      // ""')
CWD=$(echo "$INPUT"            | jq -r '.cwd              // ""')
TRANSCRIPT_PATH=$(echo "$INPUT"| jq -r '.transcript_path  // ""')

# --- Success flag (PostToolUseFailure → false, PostToolUse → true) ---
if [ "$HOOK_EVENT" = "PostToolUseFailure" ]; then
  SUCCESS="false"
else
  SUCCESS="true"
fi

# --- Timestamps ---
if command -v python3 >/dev/null 2>&1; then
  TIMESTAMP=$(python3 -c "
from datetime import datetime, timezone
now = datetime.now(timezone.utc)
ms = now.microsecond // 1000
print(now.strftime('%Y-%m-%dT%H:%M:%S.') + str(ms).zfill(3) + 'Z')
")
  END_MS=$(python3 -c "import time; print(int(time.time() * 1000))")
else
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  END_MS=$(( $(date +%s) * 1000 ))
fi

# --- Calculate duration from pre-hook temp file ---
SAFE_TOOL=$(echo "$TOOL_NAME" | tr -cd 'a-zA-Z0-9_')
TMPFILE="/tmp/claude_pre_${SESSION_ID}_${SAFE_TOOL}"
DURATION_MS=""

if [ -f "$TMPFILE" ]; then
  START_MS=$(cat "$TMPFILE" 2>/dev/null || echo "")
  if [ -n "$START_MS" ] && [ "$START_MS" -gt 0 ] 2>/dev/null; then
    DURATION_MS=$(( END_MS - START_MS ))
    # Clamp negative values (clock skew / async timing edge case)
    if [ "$DURATION_MS" -lt 0 ]; then
      DURATION_MS=0
    fi
  fi
  rm -f "$TMPFILE"
fi

# --- Strip large content fields, then truncate to 500 chars ---
# Removes known high-volume fields (file content, edit strings) while keeping
# short identifying metadata like file_path, command, pattern, description.
TOOL_INPUT_JSON=$(echo "$TOOL_INPUT_RAW" | jq 'del(.content, .new_string, .old_string)' | head -c 500)

# --- Tool output (truncate to 1000 chars; record original length) ---
TOOL_OUTPUT_JSON=$(echo "$TOOL_OUTPUT_RAW" | head -c 1000)
TOOL_OUTPUT_LENGTH=$(echo -n "$TOOL_OUTPUT_RAW" | wc -c | tr -d ' ')

# --- Token counts from transcript (last usage entry) ---
INPUT_TOKENS=""
OUTPUT_TOKENS=""

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] && command -v python3 >/dev/null 2>&1; then
  TOKEN_DATA=$(python3 - "$TRANSCRIPT_PATH" <<'PYEOF'
import json, sys

path = sys.argv[1]
input_tokens = output_tokens = None

try:
    with open(path, "r", errors="replace") as f:
        lines = f.readlines()

    # Walk backwards through transcript lines looking for a usage entry
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        # Try several known transcript shapes
        usage = (
            entry.get("usage")
            or (entry.get("message") or {}).get("usage")
            or (entry.get("result") or {}).get("usage")
        )

        if usage and isinstance(usage, dict):
            input_tokens  = usage.get("input_tokens")
            output_tokens = usage.get("output_tokens")
            break

except Exception:
    pass

print(json.dumps({"input_tokens": input_tokens, "output_tokens": output_tokens}))
PYEOF
  )

  INPUT_TOKENS=$(echo "$TOKEN_DATA"  | jq -r '.input_tokens  // ""')
  OUTPUT_TOKENS=$(echo "$TOKEN_DATA" | jq -r '.output_tokens // ""')
fi

# --- Load available tools list ---
if [ -f "$TOOLS_FILE" ]; then
  AVAILABLE_TOOLS=$(cat "$TOOLS_FILE")
else
  AVAILABLE_TOOLS="[]"
fi

# --- Build Iglu self-describing JSON payload ---
PAYLOAD=$(jq -n \
  --arg schema         "iglu:com.anthropic.claude_code/post_tool_use/jsonschema/1-0-0" \
  --arg timestamp      "$TIMESTAMP" \
  --arg session_id     "$SESSION_ID" \
  --arg tool_use_id    "$TOOL_USE_ID" \
  --arg tool_name      "$TOOL_NAME" \
  --arg tool_input     "$TOOL_INPUT_JSON" \
  --arg cwd            "$CWD" \
  --arg transcript     "$TRANSCRIPT_PATH" \
  --argjson tools      "$AVAILABLE_TOOLS" \
  --argjson success    "$SUCCESS" \
  --arg duration       "$DURATION_MS" \
  --arg output_json    "$TOOL_OUTPUT_JSON" \
  --arg output_length  "$TOOL_OUTPUT_LENGTH" \
  --arg input_tokens   "$INPUT_TOKENS" \
  --arg output_tokens  "$OUTPUT_TOKENS" \
  '{
    schema: $schema,
    data: (
      {
        timestamp:          $timestamp,
        session_id:         $session_id,
        tool_name:          $tool_name,
        tool_input_json:    $tool_input,
        cwd:                $cwd,
        transcript_path:    $transcript,
        success:            $success,
        tool_output_json:   $output_json,
        tool_output_length: ($output_length | tonumber)
      }
      + (if $tool_use_id   != ""  then {tool_use_id:     $tool_use_id}              else {} end)
      + (if ($tools | length) > 0 then {available_tools:  $tools}                   else {} end)
      + (if $duration      != ""  then {duration_ms:     ($duration  | tonumber)}   else {} end)
      + (if $input_tokens  != ""  then {input_tokens:    ($input_tokens  | tonumber)} else {} end)
      + (if $output_tokens != ""  then {output_tokens:   ($output_tokens | tonumber)} else {} end)
    )
  }')

# --- POST to collector (fire-and-forget) ---
curl -s --max-time 5 \
  -X POST \
  "${SNOWPLOW_COLLECTOR_URL}/com.snowplowanalytics.iglu/v1" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  > /dev/null 2>&1 &

exit 0
