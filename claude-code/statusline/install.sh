#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
SCRIPT_DEST="$CLAUDE_DIR/statusline-command.sh"

# ── Dependency check ──────────────────────────────────────────────────────────
install_hint() {
  cmd=$1
  if [ "$(uname)" = "Darwin" ]; then
    echo "  brew install $cmd"
  elif command -v apt-get >/dev/null 2>&1; then
    echo "  sudo apt-get install $cmd"
  elif command -v dnf >/dev/null 2>&1; then
    echo "  sudo dnf install $cmd"
  elif command -v yum >/dev/null 2>&1; then
    echo "  sudo yum install $cmd"
  else
    echo "  (install '$cmd' via your system package manager)"
  fi
}

missing=0
for cmd in jq bc git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is required but not installed." >&2
    echo "Install it with:" >&2
    install_hint "$cmd" >&2
    missing=1
  fi
done
[ "$missing" -eq 1 ] && exit 1

# ── Install script ────────────────────────────────────────────────────────────
mkdir -p "$CLAUDE_DIR"
cp "$REPO_DIR/statusline-command.sh" "$SCRIPT_DEST"
chmod +x "$SCRIPT_DEST"
echo "Installed: $SCRIPT_DEST"

# ── Merge statusLine into settings.json ───────────────────────────────────────
STATUS_LINE_CONFIG='{"type":"command","command":"bash $HOME/.claude/statusline-command.sh"}'

if [ -f "$SETTINGS" ]; then
  # Merge into existing settings — preserve all other keys
  tmp=$(mktemp)
  jq --argjson sl "$STATUS_LINE_CONFIG" '. + {statusLine: $sl}' "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
  echo "Updated:   $SETTINGS"
else
  # Create minimal settings file
  jq -n --argjson sl "$STATUS_LINE_CONFIG" '{statusLine: $sl}' > "$SETTINGS"
  echo "Created:   $SETTINGS"
fi

echo ""
echo "Done. Restart Claude Code to see the status bar."
