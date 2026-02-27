#!/bin/bash
# Usage: ./cc-run.sh WORKTREE_PATH PEARL_ID PROMPT_OR_FILE

# set -euox pipefail

if [ $# -ne 3 ]; then
    echo "Usage: $0 WORKTREE_PATH PEARL_ID PROMPT_MESSAGE"
    exit 1
fi

WORKTREE_PATH="$1"
PEARL_ID="$2"
PROMPT_INPUT="$3"


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

prl show "$PEARL_ID" > "$PROMPT_FILE"

cd "$WORKTREE_PATH"

opencode run --log-level DEBUG --format json --thinking "$PROMPT_INPUT" --file "$PROMPT_FILE" > ../log.$PEARL_ID.json

cat ../log.$PEARL_ID.json | grep '{"type":"text"' ../log.$PEARL_ID.json|tail -1|jq -r .part.text
