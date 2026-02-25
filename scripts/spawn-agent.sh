#!/bin/bash
# spawn_agent.sh
# Expected ENV variables from ptui: REPO_PATH, PEARL_ID

set -euo pipefail

if [ -z "${PEARL_ID:-}" ] || [ -z "${REPO_PATH:-}" ]; then
    echo "Missing required environment variables."
    exit 1
fi

cd "$REPO_PATH" || exit 1

echo "Setting up isolated Git worktree..."
# Ensure worktrees directory exists outside the main git tracking but nearby
mkdir -p "$HOME/dev/worktrees"
WORKTREE_PATH="$HOME/dev/worktrees/$PEARL_ID"

if [ -d "$WORKTREE_PATH" ]; then
    echo "Worktree already exists. Entering..."
else
    # No worktree assumes no branch should exist, so we wipe it.
    git worktree prune
    git branch -D "agent/$PEARL_ID" 2>/dev/null || true

    # from REPO_PATH
    git worktree add -b "agent/$PEARL_ID" "$WORKTREE_PATH"
fi

cd "$WORKTREE_PATH" || exit 1

echo "Updating $PEARL_ID to 'in_progress'..."
# Update the strict FSM state
prl update "$PEARL_ID" --status in_progress

# Fetch the pearl description to pass to the agent
PEARL_DESC=$(prl show "$PEARL_ID" --format plain)

# Build a prompt file so multiline issue descriptions are preserved exactly.
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE//$'\n'/}"
TMP_BASE="${TMP_BASE//$'\r'/}"
TMP_BASE="${TMP_BASE%/}"
PROMPT_FILE=$(mktemp "${TMP_BASE}/ptui-prompt.XXXXXX" 2>/dev/null || true)
if [ -z "$PROMPT_FILE" ]; then
    PROMPT_FILE=$(mktemp "/tmp/ptui-prompt.XXXXXX")
fi

cat > "$PROMPT_FILE" <<PROMPTEOF
I have moved Pearl $PEARL_ID to in_progress.

Here is the issue context:

$PEARL_DESC

Please analyze the repository and implement a solution.
PROMPTEOF

echo "-----------------------------------"
echo "Spawning Agent in: $WORKTREE_PATH"
echo "-----------------------------------"
echo "Pearl: $PEARL_ID"
printf 'Description:\n%s\n' "$PEARL_DESC"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/cc-run.sh" "$WORKTREE_PATH" "$PEARL_ID" "$PROMPT_FILE"
rm -f "$PROMPT_FILE"

echo "-----------------------------------"
echo "Agent session ended."
read -rp "Do you want to commit, push, and close this Pearl? (y/N) " confirm

if [[ "$confirm" =~ ^[Yy]$ ]]; then
    git add .
    git commit -m "Fixes ($PEARL_ID): Agent implementation via ptui"
    git push -u origin "agent/$PEARL_ID"
    prl close "$PEARL_ID" # Close the pearl
    echo "Pearl closed and branch pushed!"
fi
