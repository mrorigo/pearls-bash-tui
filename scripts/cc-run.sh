#!/bin/bash
# Usage: ./cc-run.sh WORKTREE_PATH PEARL_ID PROMPT_OR_FILE

set -euo pipefail

if [ $# -ne 3 ]; then
    echo "Usage: $0 WORKTREE_PATH PEARL_ID PROMPT_OR_FILE"
    exit 1
fi

WORKTREE_PATH="$1"
PEARL_ID="$2"
PROMPT_INPUT="$3"
MAP_FILE=".opencode_sessions"

cd "$WORKTREE_PATH"

# Ensure the map file exists
if [ ! -f "$MAP_FILE" ]; then
    touch "$MAP_FILE"
fi

if [ -f "$PROMPT_INPUT" ]; then
    PROMPT=$(cat "$PROMPT_INPUT")
else
    PROMPT="$PROMPT_INPUT"
fi

# Look up the mapped OpenCode session ID
SESSION_ID=$(awk -F':' -v id="$PEARL_ID" '$1 == id { print $2; exit }' "$MAP_FILE")

if [ -n "$SESSION_ID" ]; then
    opencode run --session "$SESSION_ID" "$PROMPT"
    echo "Resumed existing mapped session: $SESSION_ID"
else
    # Create a new session (OpenCode generates the ID natively)
    opencode run "$PROMPT"

    # Fetch the newly generated session ID (requires jq)
    NEW_SESSION_ID=$(opencode session list --max-count 1 --format json | jq -r '.[0].id')

    # Store the mapping for future runs
    echo "$PEARL_ID:$NEW_SESSION_ID" >> "$MAP_FILE"
    echo "Created a new session: $NEW_SESSION_ID"
fi
