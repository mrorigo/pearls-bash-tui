#!/bin/bash
# Expected ENV variables from ptui: REPO_PATH, PEARL_ID

set -euo pipefail

if [ -z "${PEARL_ID:-}" ] || [ -z "${REPO_PATH:-}" ]; then
    echo "Missing required environment variables."
    exit 1
fi

cd "$REPO_PATH" || exit 1

PEARL_JSON=$(prl show "$PEARL_ID" --format json)

# Resolve execution context:
# - If exactly one epic:<id> label exists, use <id> as shared context.
# - Otherwise, use PEARL_ID for per-pearl execution.
EPIC_CONTEXT_LABELS=()
while IFS= read -r label; do
    EPIC_CONTEXT_LABELS+=("$label")
done < <(echo "$PEARL_JSON" | jq -r '.labels[]? | select(startswith("epic:"))')

if [ "${#EPIC_CONTEXT_LABELS[@]}" -gt 1 ]; then
    echo "FATAL: More than one epic:<id> label found on $PEARL_ID."
    exit 1
fi

EXEC_CONTEXT_ID="$PEARL_ID"
IS_SHARED_CONTEXT=0
if [ "${#EPIC_CONTEXT_LABELS[@]}" -eq 1 ]; then
    EXEC_CONTEXT_ID="${EPIC_CONTEXT_LABELS[0]#epic:}"
    if [ -z "$EXEC_CONTEXT_ID" ]; then
        echo "FATAL: Invalid epic label '${EPIC_CONTEXT_LABELS[0]}' on $PEARL_ID."
        exit 1
    fi
    IS_SHARED_CONTEXT=1
fi

if [ "$IS_SHARED_CONTEXT" -eq 1 ]; then
    SIBLINGS_IN_PROGRESS=$(prl list --status in_progress --json | jq -r --arg current "$PEARL_ID" --arg epic_label "epic:$EXEC_CONTEXT_ID" '.pearls[]? | select(.id != $current and any(.labels[]?; . == $epic_label)) | .id')

    if [ -n "$SIBLINGS_IN_PROGRESS" ] && [ "${PTUI_FORCE_REMOVE:-0}" != "1" ]; then
        echo "Refusing to remove shared worktree for execution context '$EXEC_CONTEXT_ID'."
        echo "Sibling subtasks still in progress:"
        echo "$SIBLINGS_IN_PROGRESS"
        echo "Set PTUI_FORCE_REMOVE=1 to override."
        exit 1
    fi
fi

WORKTREE_PATH="$HOME/dev/worktrees/$EXEC_CONTEXT_ID"

echo "Removing worktree for execution context '$EXEC_CONTEXT_ID': $WORKTREE_PATH"
if git worktree list --porcelain | awk '/^worktree / {print $2}' | grep -Fxq "$WORKTREE_PATH"; then
    git worktree remove -f "$WORKTREE_PATH"
else
    echo "Worktree path not found in git worktree list; skipping remove."
fi

prl update "$PEARL_ID" --status open
