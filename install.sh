#!/usr/bin/env bash
# install.sh — Install Snowplow agent tracking hooks into Claude Code
#
# Usage:
#   bash install.sh --global             # install globally (all projects on this machine)
#   bash install.sh                      # install into current directory
#   bash install.sh /path/to/project     # install into specified directory

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
GLOBAL=false
TARGET_DIR=""
for arg in "$@"; do
  case "$arg" in
    --global) GLOBAL=true ;;
    -*) echo "Unknown flag: $arg"; exit 1 ;;
    *) TARGET_DIR="$arg" ;;
  esac
done

if $GLOBAL; then
  HOOKS_DIR="$PACKAGE_DIR/hooks"
  SETTINGS_DIR="$HOME/.claude"
  SETTINGS_FILE="$SETTINGS_DIR/settings.json"
  echo "Installing Snowplow agent tracking hooks (global — all projects)"
  echo "  Package : $PACKAGE_DIR"
  echo "  Settings: $SETTINGS_FILE"
  echo ""
else
  TARGET_DIR="${TARGET_DIR:-$(pwd)}"
  CLAUDE_DIR="$TARGET_DIR/.claude"
  HOOKS_DIR="$CLAUDE_DIR/hooks"
  SETTINGS_DIR="$CLAUDE_DIR"
  SETTINGS_FILE="$SETTINGS_DIR/settings.json"
  echo "Installing Snowplow agent tracking hooks (project)"
  echo "  Package : $PACKAGE_DIR"
  echo "  Target  : $TARGET_DIR"
  echo ""
fi

# ---------------------------------------------------------------------------
# 0. Dependency check
# ---------------------------------------------------------------------------
MISSING_DEPS=""
command -v jq   >/dev/null 2>&1 || MISSING_DEPS="jq"
command -v curl >/dev/null 2>&1 || MISSING_DEPS="${MISSING_DEPS:+$MISSING_DEPS, }curl"

if [ -n "$MISSING_DEPS" ]; then
  echo "WARNING: $MISSING_DEPS not found — hooks will not send events until installed."
  echo "  Install: brew install $MISSING_DEPS   (macOS)"
  echo "           apt install $MISSING_DEPS    (Debian/Ubuntu)"
  echo ""
fi

# ---------------------------------------------------------------------------
# 1. Copy hook scripts (project install only; global uses package dir directly)
# ---------------------------------------------------------------------------
mkdir -p "$SETTINGS_DIR"

if ! $GLOBAL; then
  mkdir -p "$HOOKS_DIR"
  cp "$PACKAGE_DIR/hooks/pre-tool-use.sh"  "$HOOKS_DIR/pre-tool-use.sh"
  cp "$PACKAGE_DIR/hooks/post-tool-use.sh" "$HOOKS_DIR/post-tool-use.sh"
  chmod +x "$HOOKS_DIR/pre-tool-use.sh"
  chmod +x "$HOOKS_DIR/post-tool-use.sh"
  echo "Copied hook scripts to $HOOKS_DIR"
else
  chmod +x "$HOOKS_DIR/pre-tool-use.sh" "$HOOKS_DIR/post-tool-use.sh"
  echo "Using hook scripts from $HOOKS_DIR"
fi

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
# 3. Merge hook registration into settings.json
# ---------------------------------------------------------------------------
if $GLOBAL; then
  HOOKS_JSON='{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "'"$PACKAGE_DIR"'/hooks/pre-tool-use.sh"
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
            "command": "'"$PACKAGE_DIR"'/hooks/post-tool-use.sh",
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
            "command": "'"$PACKAGE_DIR"'/hooks/post-tool-use.sh",
            "async": true
          }
        ]
      }
    ]
  }
}'
else
  HOOKS_JSON='{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/pre-tool-use.sh"
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
fi

if [ -f "$SETTINGS_FILE" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo ""
    echo "WARNING: jq not found — cannot auto-merge $SETTINGS_FILE."
    echo "Manually add the hooks block from:"
    echo "  $PACKAGE_DIR/hooks/settings.json.example"
    exit 1
  fi

  # Deep merge: preserve all existing keys and existing hook arrays,
  # append new hook entries, deduplicate by command string — new entry wins
  # over old so reinstalls pick up changes.
  NEW_SETTINGS=$(jq -s '
    .[0] as $e | .[1].hooks as $n |
    $e |
    .hooks = (
      ($e.hooks // {}) + {
        PreToolUse: (
          (($e.hooks.PreToolUse // []) + ($n.PreToolUse // []))
          | reverse | unique_by(.hooks[0].command) | reverse
        ),
        PostToolUse: (
          (($e.hooks.PostToolUse // []) + ($n.PostToolUse // []))
          | reverse | unique_by(.hooks[0].command) | reverse
        ),
        PostToolUseFailure: (
          (($e.hooks.PostToolUseFailure // []) + ($n.PostToolUseFailure // []))
          | reverse | unique_by(.hooks[0].command) | reverse
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
# 5. Add snowplow-config.env to .gitignore (project install only)
# ---------------------------------------------------------------------------
if ! $GLOBAL; then
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
fi

echo ""
echo "Done. Next steps:"
echo "  1. Edit $HOOKS_DIR/snowplow-config.env  →  set SNOWPLOW_COLLECTOR_URL"
echo "  2. Restart Claude Code to load the new hooks"
if ! $GLOBAL; then
  echo "  3. Use /init_with_tracking in any project to initialise + set up hooks in one step"
fi
