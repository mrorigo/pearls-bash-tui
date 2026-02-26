#!/bin/bash
# Usage: ./cc-run.sh WORKTREE_PATH PEARL_ID PROMPT_OR_FILE

# set -euox pipefail

if [ $# -ne 3 ]; then
    echo "Usage: $0 WORKTREE_PATH PEARL_ID PROMPT_OR_FILE"
    exit 1
fi

WORKTREE_PATH="$1"
PEARL_ID="$2"
PROMPT_INPUT="$3"

cd "$WORKTREE_PATH"

if [ -f "$PROMPT_INPUT" ]; then
    PROMPT="--file $PROMPT_INPUT")
else
    PROMPT="$PROMPT_INPUT"
fi

opencode run --log-level DEBUG --format json --thinking "$PROMPT" | tee ../log.$PEARL_ID.json

FINAL_TEXT=$(cat ../log.$PEARL_ID.json | grep '{"type":"text"' log.json|tail -1|jq .part.text)

prl comments add $PEARL_ID "opencode: $FINAL_TEXT"
