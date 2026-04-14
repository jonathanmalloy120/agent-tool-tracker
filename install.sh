#!/usr/bin/env bash
# install.sh — Install Snowplow agent tracking hooks into a Claude Code project
#
# Usage:
#   bash install.sh                  # installs into current directory
#   bash install.sh /path/to/project # installs into specified directory

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$(pwd)}"
CLAUDE_DIR="$TARGET_DIR/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

echo "Installing Snowplow agent tracking hooks"
echo "  Package : $PACKAGE_DIR"
echo "  Target  : $TARGET_DIR"
echo ""

# ---------------------------------------------------------------------------
# 1. Copy hook scripts
# ---------------------------------------------------------------------------
mkdir -p "$HOOKS_DIR"

cp "$PACKAGE_DIR/hooks/pre-tool-use.sh"       "$HOOKS_DIR/pre-tool-use.sh"
cp "$PACKAGE_DIR/hooks/post-tool-use.sh"      "$HOOKS_DIR/post-tool-use.sh"
cp "$PACKAGE_DIR/hooks/available-tools.json"  "$HOOKS_DIR/available-tools.json"
chmod +x "$HOOKS_DIR/pre-tool-use.sh"
chmod +x "$HOOKS_DIR/post-tool-use.sh"

echo "Copied hook scripts to $HOOKS_DIR"

# ---------------------------------------------------------------------------
# 2. Collector config — skip if already present so we don't overwrite the URL
# ---------------------------------------------------------------------------
if [ ! -f "$HOOKS_DIR/snowplow-config.env" ]; then
  cp "$PACKAGE_DIR/hooks/snowplow-config.env.example" "$HOOKS_DIR/snowplow-config.env"
  echo "Created $HOOKS_DIR/snowplow-config.env"
  echo "  --> Edit it and set SNOWPLOW_COLLECTOR_URL before using"
else
  echo "Skipped snowplow-config.env (already exists)"
fi

# ---------------------------------------------------------------------------
# 3. Merge hook registration into .claude/settings.json
# ---------------------------------------------------------------------------
HOOKS_JSON='{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/pre-tool-use.sh",
            "async": true
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/post-tool-use.sh",
            "async": true
          }
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/post-tool-use.sh",
            "async": true
          }
        ]
      }
    ]
  }
}'

if [ -f "$SETTINGS_FILE" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo ""
    echo "WARNING: jq not found — cannot auto-merge $SETTINGS_FILE."
    echo "Manually add the hooks block from:"
    echo "  $PACKAGE_DIR/hooks/settings.json.example"
    exit 1
  fi

  # Deep merge: preserve all existing keys and existing hook arrays,
  # append new hook entries, deduplicate by command string.
  NEW_SETTINGS=$(jq -s '
    .[0] as $e | .[1].hooks as $n |
    $e |
    .hooks = (
      ($e.hooks // {}) + {
        PreToolUse: (
          (($e.hooks.PreToolUse // []) + ($n.PreToolUse // []))
          | unique_by(.hooks[0].command)
        ),
        PostToolUse: (
          (($e.hooks.PostToolUse // []) + ($n.PostToolUse // []))
          | unique_by(.hooks[0].command)
        ),
        PostToolUseFailure: (
          (($e.hooks.PostToolUseFailure // []) + ($n.PostToolUseFailure // []))
          | unique_by(.hooks[0].command)
        )
      }
    )
  ' "$SETTINGS_FILE" <(echo "$HOOKS_JSON"))

  printf '%s\n' "$NEW_SETTINGS" > "$SETTINGS_FILE"
  echo "Merged hooks into $SETTINGS_FILE"
else
  printf '%s\n' "$HOOKS_JSON" > "$SETTINGS_FILE"
  echo "Created $SETTINGS_FILE"
fi

# ---------------------------------------------------------------------------
# 4. Install /init_with_tracking slash command (optional — global Claude commands)
# ---------------------------------------------------------------------------
GLOBAL_COMMANDS_DIR="$HOME/.claude/commands"
COMMAND_SRC="$PACKAGE_DIR/commands/init_with_tracking.md"
COMMAND_DEST="$GLOBAL_COMMANDS_DIR/init_with_tracking.md"

if [ -f "$COMMAND_SRC" ]; then
  mkdir -p "$GLOBAL_COMMANDS_DIR"
  if [ ! -f "$COMMAND_DEST" ]; then
    cp "$COMMAND_SRC" "$COMMAND_DEST"
    echo "Installed /init_with_tracking slash command to $COMMAND_DEST"
  else
    echo "Skipped /init_with_tracking command (already exists at $COMMAND_DEST)"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Add snowplow-config.env to .gitignore
# ---------------------------------------------------------------------------
GITIGNORE="$TARGET_DIR/.gitignore"
IGNORE_ENTRY=".claude/hooks/snowplow-config.env"

if [ -f "$GITIGNORE" ]; then
  if ! grep -qF "$IGNORE_ENTRY" "$GITIGNORE"; then
    printf '\n# Snowplow collector credentials\n%s\n' "$IGNORE_ENTRY" >> "$GITIGNORE"
    echo "Added $IGNORE_ENTRY to .gitignore"
  fi
else
  printf '# Snowplow collector credentials\n%s\n' "$IGNORE_ENTRY" > "$GITIGNORE"
  echo "Created .gitignore with $IGNORE_ENTRY"
fi

echo ""
echo "Done. Next steps:"
echo "  1. Edit $HOOKS_DIR/snowplow-config.env  →  set SNOWPLOW_COLLECTOR_URL"
echo "  2. Restart Claude Code to load the new hooks"
echo "  3. Use /init_with_tracking in any project to initialise + set up hooks in one step"
