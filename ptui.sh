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
      "name": "Spawn Agent",
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

    local has_title=0
    local has_priority=0
    local has_status=0
    local new_title=""
    local new_priority=""
    local new_status=""
    local add_labels=""
    local remove_labels=""
    local desc_mode="keep"
    local desc_file=""

    while true; do
        local title_preview
        local priority_preview
        local status_preview
        local add_labels_preview
        local remove_labels_preview
        local desc_preview
        local choice

        if [ "$has_title" -eq 1 ]; then
            title_preview="$new_title"
        else
            title_preview="(keep: $current_title)"
        fi

        if [ "$has_priority" -eq 1 ]; then
            priority_preview="$new_priority"
        else
            priority_preview="(keep: $current_priority)"
        fi

        if [ "$has_status" -eq 1 ]; then
            status_preview="$new_status"
        else
            status_preview="(keep: $current_status)"
        fi

        if [ -n "$add_labels" ]; then
            add_labels_preview="$add_labels"
        else
            add_labels_preview="(none)"
        fi

        if [ -n "$remove_labels" ]; then
            remove_labels_preview="$remove_labels"
        else
            remove_labels_preview="(none)"
        fi

        case "$desc_mode" in
            keep) desc_preview="(keep current)" ;;
            edit) desc_preview="(edited in $EDITOR)" ;;
            clear) desc_preview="(clear description)" ;;
            *) desc_preview="(keep current)" ;;
        esac

        choice=$(printf "[Apply Changes]\n[Edit Title] %s\n[Edit Priority] %s\n[Edit Status] %s\n[Add Labels] %s\n[Remove Labels] %s\n[Description] %s\n[Back]" \
            "$title_preview" \
            "$priority_preview" \
            "$status_preview" \
            "$add_labels_preview" \
            "$remove_labels_preview" \
            "$desc_preview" | \
            fzf --prompt="Update $pearl_id: " --height=55% --layout=reverse)

        case "$choice" in
            "[Back]"|"")
                [ -n "$desc_file" ] && rm -f "$desc_file"
                return
                ;;
            "[Edit Title]"*)
                read -rp "New title (blank to keep current): " new_title
                if [ -n "$new_title" ]; then
                    has_title=1
                else
                    has_title=0
                fi
                ;;
            "[Edit Priority]"*)
                read -rp "New priority 0-4 (blank to keep current): " new_priority
                if [ -n "$new_priority" ]; then
                    if [[ "$new_priority" =~ ^[0-4]$ ]]; then
                        has_priority=1
                    else
                        echo "Invalid priority. Use a value between 0 and 4."
                        new_priority=""
                        has_priority=0
                        read -n 1 -s -r -p "Press any key to continue..."
                    fi
                else
                    has_priority=0
                fi
                ;;
            "[Edit Status]"*)
                local selected_status
                selected_status=$(printf "[Keep current: %s]\nopen\nin_progress\nblocked\ndeferred\nclosed" "$current_status" | fzf --prompt="Status: " --height=35% --layout=reverse)
                if [ -z "$selected_status" ] || [ "$selected_status" = "[Keep current: $current_status]" ]; then
                    has_status=0
                    new_status=""
                else
                    has_status=1
                    new_status="$selected_status"
                fi
                ;;
            "[Add Labels]"*)
                read -rp "Add labels (comma-separated, blank to clear): " add_labels
                ;;
            "[Remove Labels]"*)
                read -rp "Remove labels (comma-separated, blank to clear): " remove_labels
                ;;
            "[Description]"*)
                local desc_choice
                local edit_with_editor_option
                edit_with_editor_option="Edit in $EDITOR"
                desc_choice=$(printf "Keep current\n%s\nClear description" "$edit_with_editor_option" | fzf --prompt="Description: " --height=30% --layout=reverse)

                if [ "$desc_choice" = "$edit_with_editor_option" ]; then
                    [ -n "$desc_file" ] && rm -f "$desc_file"
                    desc_file=$(mktemp)
                    printf "%s\n" "$current_desc" > "$desc_file"
                    "$EDITOR" "$desc_file"
                    desc_mode="edit"
                elif [ "$desc_choice" = "Clear description" ]; then
                    [ -n "$desc_file" ] && rm -f "$desc_file"
                    desc_file=$(mktemp)
                    : > "$desc_file"
                    desc_mode="clear"
                else
                    [ -n "$desc_file" ] && rm -f "$desc_file"
                    desc_file=""
                    desc_mode="keep"
                fi
                ;;
            "[Apply Changes]")
                local cmd
                local has_changes=0
                cmd=("prl" "update" "$pearl_id")

                if [ "$has_title" -eq 1 ]; then
                    cmd+=("--title" "$new_title")
                    has_changes=1
                fi

                if [ "$has_priority" -eq 1 ]; then
                    cmd+=("--priority" "$new_priority")
                    has_changes=1
                fi

                if [ "$has_status" -eq 1 ]; then
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

                if [ "$desc_mode" = "edit" ] || [ "$desc_mode" = "clear" ]; then
                    cmd+=("--description-file" "$desc_file")
                    has_changes=1
                fi

                if [ "$has_changes" -eq 0 ]; then
                    echo "No changes selected."
                    read -n 1 -s -r -p "Press any key to continue..."
                    continue
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
                return
                ;;
        esac
    done
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
                local chosen_name="${choice#\[Run\] }"
                local script_cmd
                script_cmd=$(echo "$valid_scripts" | awk -F'|' -v name="$chosen_name" '$1 == name { print substr($0, index($0, "|") + 1); exit }')

                if [ -n "$script_cmd" ]; then
                    clear
                    echo "Executing: $chosen_name..."
                    export REPO_PATH="$SELECTED_REPO"
                    export PEARL_ID="$pearl_id"

                    local run_log
                    local run_rc
                    local tmp_base

                    tmp_base="${TMPDIR:-/tmp}"
                    tmp_base="${tmp_base//$'\n'/}"
                    tmp_base="${tmp_base//$'\r'/}"
                    tmp_base="${tmp_base%/}"

                    run_log=$(mktemp "${tmp_base}/ptui-script.XXXXXX" 2>/dev/null)
                    if [ -z "$run_log" ]; then
                        run_log=$(mktemp "/tmp/ptui-script.XXXXXX" 2>/dev/null)
                    fi
                    if [ -z "$run_log" ]; then
                        echo "Failed to create a temporary log file."
                        read -n 1 -s -r -p "Press any key to continue..."
                        return
                    fi

                    # Run from selected repo and capture both live output and a log for postmortem.
                    (
                        cd "$SELECTED_REPO" || exit 1
                        eval "$script_cmd"
                    ) 2>&1 | tee "$run_log"
                    run_rc=${PIPESTATUS[0]}

                    echo
                    if [ "$run_rc" -eq 0 ]; then
                        echo "Script finished successfully."
                    else
                        echo "Script failed (exit code $run_rc)."
                    fi
                    echo "Output log: $run_log"

                    if [ "$run_rc" -ne 0 ]; then
                        echo "Opening log because command failed..."
                        less "$run_log"
                    fi

                    local post_run_action
                    post_run_action=$(printf "Back to Pearl\nView full log" | fzf --prompt="After script: " --height=20% --layout=reverse)
                    if [ "$post_run_action" = "View full log" ]; then
                        less "$run_log"
                    fi
                    return # Exit action menu after running a script
                else
                    echo "Unable to resolve script command for: $chosen_name"
                    read -n 1 -s -r -p "Press any key to continue..."
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
