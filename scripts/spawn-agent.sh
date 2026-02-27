#!/bin/bash
# spawn_agent.sh
# Expected ENV variables from ptui: REPO_PATH, PEARL_ID

set -euo pipefail

if [ -z "${PEARL_ID:-}" ] || [ -z "${REPO_PATH:-}" ]; then
    echo "Missing required environment variables."
    exit 1
fi

cd "$REPO_PATH" || exit 1

PEARL_JSON=$(prl show "$PEARL_ID" --format json)

# If the pearl itself is an epic, do not run agent execution on it.
IS_EPIC=$(echo "$PEARL_JSON" | jq -r 'any(.labels[]?; . == "epic")')
if [ "$IS_EPIC" = "true" ]; then
    echo "Pearl $PEARL_ID is an Epic and should not be sent to opencode."
    exit 1
fi

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
if [ "${#EPIC_CONTEXT_LABELS[@]}" -eq 1 ]; then
    EXEC_CONTEXT_ID="${EPIC_CONTEXT_LABELS[0]#epic:}"
    if [ -z "$EXEC_CONTEXT_ID" ]; then
        echo "FATAL: Invalid epic label '${EPIC_CONTEXT_LABELS[0]}' on $PEARL_ID."
        exit 1
    fi
fi

echo "Setting up isolated Git worktree..."
mkdir -p "$HOME/dev/worktrees"

BRANCH_NAME="agent/$EXEC_CONTEXT_ID"
WORKTREE_PATH="$HOME/dev/worktrees/$EXEC_CONTEXT_ID"

if [ -d "$WORKTREE_PATH" ]; then
    echo "Worktree already exists for execution context '$EXEC_CONTEXT_ID'. Reusing..."
else
    git worktree prune
    git branch -D "$BRANCH_NAME" 2>/dev/null || true
    git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH"
fi

cd "$WORKTREE_PATH" || exit 1

PEARL_STATUS=$(echo "$PEARL_JSON" | jq -r '.status')
case "$PEARL_STATUS" in
    open)
        echo "Updating $PEARL_ID to 'in_progress'..."
        prl update "$PEARL_ID" --status in_progress
        ;;
    in_progress)
        echo "Pearl already in_progress"
        ;;
    *)
        echo "Pearl $PEARL_ID is not open."
        ;;
esac

# Stage selection from labels.
STAGE_LABELS=()
while IFS= read -r label; do
    STAGE_LABELS+=("$label")
done < <(echo "$PEARL_JSON" | jq -r '.labels[]? | select(. == "stage:planning" or . == "stage:implementation" or . == "stage:verification")')

if [ "${#STAGE_LABELS[@]}" -gt 1 ]; then
    echo "FATAL: More than one stage label found on $PEARL_ID."
    exit 1
fi

if [ "${#STAGE_LABELS[@]}" -eq 0 ]; then
    echo "WARN: No stage labels found. Defaulting to stage:implementation."
    PEARL_STAGE="stage:implementation"
else
    PEARL_STAGE="${STAGE_LABELS[0]}"
fi

PEARL_DESC=$(prl show "$PEARL_ID" --format plain)

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE//$'\n'/}"
TMP_BASE="${TMP_BASE//$'\r'/}"
TMP_BASE="${TMP_BASE%/}"
PROMPT_FILE=$(mktemp "${TMP_BASE}/ptui-prompt.XXXXXX" 2>/dev/null || true)
if [ -z "$PROMPT_FILE" ]; then
    PROMPT_FILE=$(mktemp "/tmp/ptui-prompt.XXXXXX")
fi

cleanup_prompt_file() {
    [ -n "${PROMPT_FILE:-}" ] && rm -f "$PROMPT_FILE"
}
trap cleanup_prompt_file EXIT

case "$PEARL_STAGE" in
    "stage:planning")
        STAGE_PROMPT="Task: Create a plan for the implementation, and store it in ISSUE_PLAN.md"
        ;;
    "stage:implementation")
        STAGE_PROMPT="Task: Implement the solution described in ISSUE_PLAN.md and store it in ISSUE_SOLUTION.md"
        ;;
    "stage:verification")
        STAGE_PROMPT="Task: Verify the solution planned in ISSUE_PLAN.md and implemented in ISSUE_SOLUTION.md. Store the verification results in ISSUE_VERIFICATION.md"
        ;;
    *)
        STAGE_PROMPT="Task: Plan and implement"
        ;;
esac

cat > "$PROMPT_FILE" <<PROMPTEOF
Here is the issue context:

---
$PEARL_DESC
---

$STAGE_PROMPT
PROMPTEOF

echo "-----------------------------------"
echo "Spawning Agent in: $WORKTREE_PATH"
echo "Branch: $BRANCH_NAME"
echo "Pearl: $PEARL_ID"
echo "Execution context: $EXEC_CONTEXT_ID"
echo "-----------------------------------"

cat "$PROMPT_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/oc-run.sh" "$WORKTREE_PATH" "$PEARL_ID" "$PROMPT_FILE"

echo "-----------------------------------"
echo "Agent session ended."
read -rp "Do you want to commit, push, and close this Pearl? (y/N) " confirm

if [[ "$confirm" =~ ^[Yy]$ ]]; then
    prl close "$PEARL_ID"
    git add .
    git commit -m "Fixes ($PEARL_ID): Agent implementation via ptui"
    git push -u origin "$BRANCH_NAME"
    echo "Pearl closed and branch pushed!"
fi
