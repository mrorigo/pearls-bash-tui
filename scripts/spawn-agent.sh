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
# Ensure worktrees directory exists
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

# Pearl label logic:
# - label:stage-* specifies the stage to use for the agent

PEARL_STATUS=$(prl show "$PEARL_ID" --format json|jq -r '.status')
case $PEARL_STATUS in
    open)
        echo "Updating $PEARL_ID to 'in_progress'..."
        # Update the strict FSM state
        prl update "$PEARL_ID" --status in_progress
        ;;
    in_progress)
        echo "Pearl already in_progress"
        ;;
    *)
        echo "Pearl $PEARL_ID is not open."
        ;;
esac

# If the pearl is an epic, it should not be sent to opencode
IS_EPIC=$(prl show $PEARL_ID --format json | jq -r .labels|grep epic)
if [ ! -z "$IS_EPIC" ]; then
    echo "Pearl $PEARL_ID is an Epic, should not be sent to opencode"
    exit 1
fi

# All pearls should have one of the stage: labels
# Missing stage labels means 'stage:implementation'
STAGE_LABELS="stage:planning stage:implementation stage:verification"
RESULTS=()
for LABEL in $STAGE_LABELS; do
    TAGGED=($(prl show $PEARL_ID --format json | jq 'select(.labels | index("'$LABEL'"))'))
    if [ ! -z "$TAGGED" ]; then
        RESULTS+=("$LABEL")
    fi
done

if [ ${#RESULTS[@]} -eq 0 ]; then
    echo "WARN: No stage labels found."
    RESULTS+=("default")
else
    if [ ${#RESULTS[@]} -ne 1 ]; then
        echo "FATAL: More than one label found"
        exit 1
    fi
fi

PEARL_STAGE=${RESULTS[0]}

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

cleanup_prompt_file() {
    [ -n "${PROMPT_FILE:-}" ] && rm -f "$PROMPT_FILE"
}
trap cleanup_prompt_file EXIT

case $PEARL_STAGE in
    "stage:planning")
        STAGE_PROMPT=<<EOF
Task: Create a plan for the implementation, and store it in ISSUE_PLAN.md
EOF
    ;;
    "stage:implementation")
        STAGE_PROMPT=<<EOF
Task: Implement the solution described in ISSUE_PLAN.md and store it in ISSUE_SOLUTION.md
EOF
    ;;
    "stage:verification")
        STAGE_PROMPT=<<EOF
Task: Verify the solution planned in ISSUE_PLAN.md and implemented in ISSUE_SOLUTION.md. Store the verification results in ISSUE_VERIFICATION.md
EOF
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
echo "-----------------------------------"
echo "Pearl: $PEARL_ID"
# printf 'Description:\n%s\n' "$PEARL_DESC"

cat $PROMPT_FILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/oc-run.sh" "$WORKTREE_PATH" "$PEARL_ID" "$PROMPT_FILE"

echo "-----------------------------------"
echo "Agent session ended."
read -rp "Do you want to commit, push, and close this Pearl? (y/N) " confirm

if [[ "$confirm" =~ ^[Yy]$ ]]; then
    prl close "$PEARL_ID" # Close the pearl
    git add .
    git commit -m "Fixes ($PEARL_ID): Agent implementation via ptui"
    git push -u origin "agent/$PEARL_ID"
    # TODO: Robust error handling
    echo "Pearl closed and branch pushed!"
fi
