#!/bin/bash
# Expected ENV variables from ptui: REPO_PATH, PEARL_ID

if [ -z "$PEARL_ID" ] || [ -z "$REPO_PATH" ]; then
    echo "Missing required environment variables."
    exit 1
fi

WORKTREE_PATH="$HOME/dev/worktrees/$PEARL_ID"

cd "$REPO_PATH" || exit 1
# Wipe the worktree
git worktree remove -f "$WORKTREE_PATH"

prl update "$PEARL_ID" --status open
