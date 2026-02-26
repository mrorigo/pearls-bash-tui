#!/bin/bash
# Expected ENV variables from ptui: REPO_PATH, PEARL_ID

if [ -z "$PEARL_ID" ] || [ -z "$REPO_PATH" ]; then
    echo "Missing required environment variables."
    exit 1
fi

IS_EPIC=$(prl show $PEARL_ID --format json | jq -r .labels|grep epic)

if [ -z "$IS_EPIC" ]; then
    PEARL_DESC=$(prl show "$PEARL_ID" --format plain)

    # Create 3 new pearls: Plan, Implement, Verify
    PLAN_ID=$(echo "plan: $PEARL_DESC" | prl create "plan: epic $PEARL_ID" --description-file - --label stage:planning --label epic:$PEARL_ID --format json|jq -r .pearl.id)
    IMPLEMENT_ID=$(echo "implement: $PEARL_DESC" | prl create "implement: epic $PEARL_ID" --description-file - --label stage:implementation  --label epic:$PEARL_ID --format json|jq -r .pearl.id)
    VERIFY_ID=$(echo "verify: $PEARL_DESC" | prl create "verify: epic $PEARL_ID" --description-file - --label stage:verification --label epic:$PEARL_ID --format json|jq -r .pearl.id)

    # Set relationships
    prl link $IMPLEMENT_ID $PLAN_ID blocks     # PLAN blocks IMPLEMENT
    prl link $VERIFY_ID $IMPLEMENT_ID blocks   # IMPLEMENT blocks VERIFY
    prl link $PEARL_ID $VERIFY_ID blocks     # VERIFY blocks epic

    # Label epic pearl
    prl update $PEARL_ID --add-label epic

    # Add comment
    prl comments add $PEARL_ID "Converted to Epic"
else
    echo "Pearl $PEARL_ID is already an Epic."

fi
