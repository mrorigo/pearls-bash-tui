#!/bin/bash
# ptui: A bash/fzf TUI for the Pearls Issue Tracker

# --- Dependencies Check ---
for cmd in prl jq fzf; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: '$cmd' is not installed or not in PATH."
        exit 1
    fi
done

# --- Configuration Setup ---
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ptui"
CONFIG_FILE="$CONFIG_DIR/config.json"
EDITOR="${EDITOR:-vi}"

mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_FILE" ]; then
    cat <<CFGEOF > "$CONFIG_FILE"
{
  "repos": [
    "$PWD"
  ],
  "scripts": [
    {
      "name": "Spawn Claude Agent",
      "target_status": "open",
      "command": "$CONFIG_DIR/spawn_agent.sh"
    }
  ]
}
CFGEOF
    echo "Created default config at $CONFIG_FILE"
fi

# --- Core Functions ---

select_repo() {
    local repos
    repos=$(jq -r '.repos[]' "$CONFIG_FILE")

    if [ -z "$repos" ]; then
        echo "No repositories configured in $CONFIG_FILE."
        exit 1
    fi

    # Single repo auto-select, otherwise fzf
    if [ "$(echo "$repos" | wc -l)" -eq 1 ]; then
        SELECTED_REPO="$repos"
    else
        SELECTED_REPO=$(echo "$repos" | fzf --prompt="📂 Select Repository: " --height=40% --layout=reverse)
    fi

    if [ -z "$SELECTED_REPO" ]; then exit 0; fi
    cd "$SELECTED_REPO" || { echo "Failed to cd into $SELECTED_REPO"; exit 1; }
}

create_pearl() {
    clear
    echo "=== Create New Pearl ==="
    read -rp "Title: " title
    if [ -z "$title" ]; then return; fi

    read -rp "Priority (0=Critical, 4=Trivial): " priority
    priority=${priority:-2}

    read -rp "Labels (comma-separated, optional): " labels

    # Use editor for the markdown description
    desc_file=$(mktemp)
    echo -e "\n\n# Add your description above. Save and exit to create." > "$desc_file"
    "$EDITOR" "$desc_file"

    # Strip the helper text
    sed -i.bak '/# Add your description above./d' "$desc_file"

    # Build command
    cmd=("prl" "create" "$title" "--priority" "$priority" "--description-file" "$desc_file")
    if [ -n "$labels" ]; then cmd+=("--label" "$labels"); fi

    echo "Creating Pearl..."
    "${cmd[@]}"
    rm -f "$desc_file" "$desc_file.bak"

    read -n 1 -s -r -p "Press any key to continue..."
}

update_pearl() {
    local pearl_id=$1
    local current_json
    local current_title
    local current_priority
    local current_status
    local current_labels
    local current_desc

    current_json=$(prl show "$pearl_id" --json 2>/dev/null)
    if [ -z "$current_json" ]; then
        echo "Failed to load Pearl $pearl_id"
        read -n 1 -s -r -p "Press any key to continue..."
        return
    fi

    current_title=$(echo "$current_json" | jq -r '.title // ""')
    current_priority=$(echo "$current_json" | jq -r '.priority // ""')
    current_status=$(echo "$current_json" | jq -r '.status // ""')
    current_labels=$(echo "$current_json" | jq -r '(.labels // []) | join(",")')
    current_desc=$(echo "$current_json" | jq -r '.description // ""')

    clear
    echo "=== Update Pearl: $pearl_id ==="
    echo "Leave fields blank to keep current values."
    echo

    read -rp "Title [$current_title]: " new_title
    read -rp "Priority [$current_priority]: " new_priority

    local new_status
    new_status=$(printf "[Keep current: %s]\nopen\nin_progress\nblocked\ndeferred\nclosed" "$current_status" | fzf --prompt="Status: " --height=35% --layout=reverse)
    if [ -z "$new_status" ]; then
        new_status="[Keep current: $current_status]"
    fi

    read -rp "Add labels (comma-separated, optional): " add_labels
    read -rp "Remove labels (comma-separated, optional): " remove_labels

    local edit_desc
    local edit_with_editor_option
    edit_with_editor_option="Edit in $EDITOR"
    edit_desc=$(printf "No\n%s\nClear description" "$edit_with_editor_option" | fzf --prompt="Description: " --height=30% --layout=reverse)

    local desc_file=""
    if [ "$edit_desc" = "$edit_with_editor_option" ]; then
        desc_file=$(mktemp)
        printf "%s\n" "$current_desc" > "$desc_file"
        "$EDITOR" "$desc_file"
    elif [ "$edit_desc" = "Clear description" ]; then
        desc_file=$(mktemp)
        : > "$desc_file"
    fi

    local cmd
    local has_changes=0
    cmd=("prl" "update" "$pearl_id")

    if [ -n "$new_title" ]; then
        cmd+=("--title" "$new_title")
        has_changes=1
    fi

    if [ -n "$new_priority" ]; then
        cmd+=("--priority" "$new_priority")
        has_changes=1
    fi

    if [ "$new_status" != "[Keep current: $current_status]" ]; then
        cmd+=("--status" "$new_status")
        has_changes=1
    fi

    if [ -n "$add_labels" ]; then
        cmd+=("--add-label" "$add_labels")
        has_changes=1
    fi

    if [ -n "$remove_labels" ]; then
        cmd+=("--remove-label" "$remove_labels")
        has_changes=1
    fi

    if [ -n "$desc_file" ]; then
        cmd+=("--description-file" "$desc_file")
        has_changes=1
    fi

    if [ "$has_changes" -eq 0 ]; then
        echo "No changes selected."
        [ -n "$desc_file" ] && rm -f "$desc_file"
        read -n 1 -s -r -p "Press any key to continue..."
        return
    fi

    clear
    echo "Updating Pearl..."
    "${cmd[@]}"
    local rc=$?

    [ -n "$desc_file" ] && rm -f "$desc_file"

    if [ "$rc" -ne 0 ]; then
        echo
        echo "Update failed (exit code $rc)."
    fi

    read -n 1 -s -r -p "Press any key to continue..."
}

action_menu() {
    local pearl_id=$1
    local pearl_status=$2

    while true; do
        local current_json
        local refreshed_status

        current_json=$(prl show "$pearl_id" --json 2>/dev/null)
        refreshed_status=$(echo "$current_json" | jq -r '.status // empty' 2>/dev/null)
        if [ -n "$refreshed_status" ]; then
            pearl_status="$refreshed_status"
        fi

        clear
        echo "=== Pearl: $pearl_id ($pearl_status) ==="
        # Show plain format details
        prl show "$pearl_id" --format plain
        echo "----------------------------------------"

        # Find scripts matching this status
        local valid_scripts
        valid_scripts=$(jq -r --arg status "$pearl_status" '.scripts[] | select(.target_status == $status or .target_status == "any") | "\(.name)|\(.command)"' "$CONFIG_FILE")

        local options="[Update Pearl]\n[View JSON]\n[Back]"
        if [ -n "$valid_scripts" ]; then
            # Extract just the script names for the menu
            local script_names
            script_names=$(echo "$valid_scripts" | cut -d'|' -f1 | sed 's/^/[Run] /')
            options="$script_names\n$options"
        fi

        local choice
        choice=$(echo -e "$options" | fzf --prompt="Action for $pearl_id: " --height=35% --layout=reverse)

        case "$choice" in
            "[Back]"|"") return ;;
            "[Update Pearl]")
                update_pearl "$pearl_id"
                ;;
            "[View JSON]")
                prl show "$pearl_id" --json | jq . | less
                ;;
            "[Run]"*)
                # Extract the pure name and find the corresponding command
                local chosen_name="${choice#[Run] }"
                local script_cmd
                script_cmd=$(echo "$valid_scripts" | grep "^$chosen_name|" | cut -d'|' -f2)

                if [ -n "$script_cmd" ]; then
                    clear
                    echo "Executing: $chosen_name..."
                    export REPO_PATH="$SELECTED_REPO"
                    export PEARL_ID="$pearl_id"
                    # Evaluate the script allowing arguments
                    eval "$script_cmd"
                    read -n 1 -s -r -p "Script finished. Press any key..."
                    return # Exit action menu after running a script
                fi
                ;;
        esac
    done
}

list_pearls() {
    local list_type=$1
    local json_data
    local items_json
    local prompt_msg

    if [ "$list_type" == "ready" ]; then
        # Load Ready Queue
        json_data=$(prl ready --json 2>/dev/null)
        prompt_msg="Ready Queue (Unblocked): "
    else
        # Load All Open
        json_data=$(prl list --status open --json 2>/dev/null)
        prompt_msg="Open Pearls: "
    fi

    # Normalize command output into an array of pearl objects.
    # - prl ready --json => {"ready":[...], "total":..., ...}
    # - prl list  --json => {"pearls":[...], "total":...}
    items_json=$(echo "$json_data" | jq -c 'if type == "object" and has("ready") then .ready elif type == "object" and has("pearls") then .pearls else . end' 2>/dev/null)

    # If JSON is empty/invalid or no items, return
    if [ -z "$items_json" ] || [ "$items_json" == "null" ] || [ "$items_json" == "[]" ]; then
        echo "No pearls found."
        read -n 1 -s -r -p "Press any key..."
        return
    fi

    # Format for fzf: ID | Priority | Status | Title
    local selected_line
    selected_line=$(echo "$items_json" | jq -r '.[] | "[\(.id)] P\(.priority) (\(.status)) \(.title)"' | fzf --prompt="$prompt_msg" --height=80% --layout=reverse)

    if [ -n "$selected_line" ]; then
        # Extract ID and Status from the selected line
        local p_id p_status
        p_id=$(echo "$selected_line" | awk -F'[][]' '{print $2}')
        p_status=$(echo "$selected_line" | grep -o '(.*)' | tr -d '()' | awk '{print $1}')
        action_menu "$p_id" "$p_status"
    fi
}

# --- Main Loop ---
select_repo

while true; do
    clear
    echo "====================================="
    echo " Pearls TUI Manager (ptui) "
    echo " Repo: $(basename "$SELECTED_REPO")"
    echo "====================================="

    main_choice=$(printf "1. Ready Queue\n2. All Open\n3. Create New Pearl\n4. Change Repo\n5. Exit" | fzf --prompt="Menu: " --height=30% --layout=reverse)

    case "$main_choice" in
        "1. Ready Queue") list_pearls "ready" ;;
        "2. All Open") list_pearls "open" ;;
        "3. Create New Pearl") create_pearl ;;
        "4. Change Repo") select_repo ;;
        "5. Exit"|"") clear; exit 0 ;;
    esac
done
