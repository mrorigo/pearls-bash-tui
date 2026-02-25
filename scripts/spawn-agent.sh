#!/bin/bash
# spawn_agent.sh
# Expected ENV variables from ptui: REPO_PATH, PEARL_ID

if [ -z "$PEARL_ID" ] || [ -z "$REPO_PATH" ]; then
    echo "Missing required environment variables."
    exit 1
fi

cd "$REPO_PATH" || exit 1

echo "Updating $PEARL_ID to 'in_progress'..."
# Update the strict FSM state
prl update "$PEARL_ID" --status in_progress

echo "Setting up isolated Git worktree..."
# Ensure worktrees directory exists outside the main git tracking but nearby
mkdir -p "../worktrees"
WORKTREE_PATH="../worktrees/$PEARL_ID"

if [ -d "$WORKTREE_PATH" ]; then
    echo "Worktree already exists. Entering..."
else
    git worktree add -b "agent/$PEARL_ID" "$WORKTREE_PATH"
fi

cd "$WORKTREE_PATH" || exit 1

# Fetch the pearl description to pass to the agent
PEARL_DESC=$(prl show "$PEARL_ID" --format plain)

echo "-----------------------------------"
echo "Spawning Agent in: $WORKTREE_PATH"
echo "-----------------------------------"

# Example: Spawning an interactive OpenCode session.
# We pass the Pearl details directly into the initial prompt.
opencode --prompt "I have moved Pearl $PEARL_ID to in_progress. Here is the issue context: $PEARL_DESC. Please analyze the repository and implement a solution."

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
