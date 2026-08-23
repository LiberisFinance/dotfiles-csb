#!/bin/bash
# Sets up user-level Claude Code configuration from dotfiles.
# Idempotent — safe to run on every workspace start.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_SRC="$DOTFILES_DIR/config/claude"
CLAUDE_DIR="$HOME/.claude"

mkdir -p \
  "$CLAUDE_DIR/agents" \
  "$CLAUDE_DIR/skills" \
  "$CLAUDE_DIR/hooks"

# --- CLAUDE.md ---
cp "$CLAUDE_SRC/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"

# --- Status line script ---
cp "$CLAUDE_SRC/statusline.sh" "$CLAUDE_DIR/statusline.sh"
chmod +x "$CLAUDE_DIR/statusline.sh"

# --- Status line pricing table: only seed if missing — the statusline-pricing-refresh
# skill updates verified_on/prices in place over time, so re-applying the template on
# every setup run would clobber a more recent refresh with this stale snapshot.
if [ ! -f "$CLAUDE_DIR/statusline-pricing.json" ]; then
  cp "$CLAUDE_SRC/statusline-pricing.json" "$CLAUDE_DIR/statusline-pricing.json"
  echo "claude: seeded statusline-pricing.json"
else
  echo "claude: statusline-pricing.json already exists, skipping (run the statusline-pricing-refresh skill to update)"
fi

# --- Agents ---
cp "$CLAUDE_SRC/agents/"*.md "$CLAUDE_DIR/agents/"

# --- Skills ---
rsync -a "$CLAUDE_SRC/skills/" "$CLAUDE_DIR/skills/"

# --- Hooks ---
cp "$CLAUDE_SRC/hooks/langfuse_hook.py" "$CLAUDE_DIR/hooks/langfuse_hook.py"

# --- settings.json: substitute __HOME__ with actual $HOME ---
# Only write if settings.json does not already exist or differs from template
SETTINGS_TEMPLATE="$CLAUDE_SRC/settings.json"
SETTINGS_TARGET="$CLAUDE_DIR/settings.json"

if [ ! -f "$SETTINGS_TARGET" ]; then
  sed "s|__HOME__|$HOME|g" "$SETTINGS_TEMPLATE" > "$SETTINGS_TARGET"
  echo "claude: created settings.json"
else
  # Re-apply to pick up any changes to the template; merge would be ideal but
  # Claude Code manages settings.json at runtime so we only write if the target
  # is missing — update manually when template changes are intentional.
  echo "claude: settings.json already exists, skipping (delete to re-apply template)"
fi

echo "claude: configuration applied"
