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
  "terminal_command": null,
  "scripts": [
    {
      "name": "Spawn Agent",
      "target_status": "open",
      "command": "$CONFIG_DIR/spawn_agent.sh",
      "run_in_tmux": false
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
sanitize_tmux_name() {
    local value="$1"
    value="${value//[^A-Za-z0-9_-]/-}"
    if [ -z "$value" ]; then
        value="item"
    fi
    printf '%s' "$value"
}

repo_tmux_session_name() {
    local repo_slug
    local repo_hash

    repo_slug=$(sanitize_tmux_name "$(basename "$SELECTED_REPO")")
    repo_hash=$(printf '%s' "$SELECTED_REPO" | cksum | awk '{print $1}')
    printf 'ptui-%s-%s' "$repo_slug" "$repo_hash"
}

pearl_tmux_window_name() {
    local pearl_id="$1"
    sanitize_tmux_name "$pearl_id"
}

build_tmux_script_command() {
    local pearl_id="$1"
    local script_cmd="$2"
    printf 'cd %q || exit 1; export REPO_PATH=%q; export PEARL_ID=%q; eval %q' "$SELECTED_REPO" "$SELECTED_REPO" "$pearl_id" "$script_cmd"
}

build_tmux_shell_command() {
    local pearl_id="$1"
    printf 'cd %q || exit 1; export REPO_PATH=%q; export PEARL_ID=%q; exec "${SHELL:-bash}" -l' "$SELECTED_REPO" "$SELECTED_REPO" "$pearl_id"
}

attach_tmux_target() {
    local target="$1"
    echo "Detach with Ctrl-b d"
    read -n 1 -s -r -p "Press any key to attach..."
    tmux attach-session -t "$target"
}
open_new_terminal_with_tmux_target() {
    local target="$1"
    local attach_cmd
    local configured_terminal_cmd

    attach_cmd=$(printf 'tmux attach-session -t %q' "$target")
    configured_terminal_cmd=$(jq -r '.terminal_command // empty' "$CONFIG_FILE" 2>/dev/null)
    configured_terminal_cmd="${configured_terminal_cmd//$'\r'/}"
    configured_terminal_cmd="${configured_terminal_cmd//$'\n'/ }"

    if [ -n "$configured_terminal_cmd" ] && [ "$configured_terminal_cmd" != "null" ]; then
        configured_terminal_cmd="${configured_terminal_cmd//\{\{TMUX_TARGET\}\}/$target}"
        configured_terminal_cmd="${configured_terminal_cmd//\{\{TMUX_ATTACH_CMD\}\}/$attach_cmd}"
        eval "$configured_terminal_cmd"
        return $?
    fi

    if [ "$(uname -s)" = "Darwin" ] && command -v osascript &> /dev/null; then
        osascript -e 'tell application "Terminal" to activate' \
                  -e "tell application \"Terminal\" to do script \"tmux attach-session -t $target\""
        return $?
    fi

    if command -v x-terminal-emulator &> /dev/null; then
        x-terminal-emulator -e "tmux attach-session -t $target" >/dev/null 2>&1 &
        return $?
    fi

    echo "Unable to open a new terminal automatically on this platform."
    echo "Configure terminal_command in $CONFIG_FILE or run manually: tmux attach-session -t $target"
    return 1
}

ensure_tmux_for_script() {
    local pearl_id="$1"
    local script_cmd="$2"
    local tmux_session
    local tmux_window
    local tmux_cmd

    tmux_session=$(repo_tmux_session_name)
    tmux_window=$(pearl_tmux_window_name "$pearl_id")
    tmux_cmd=$(build_tmux_script_command "$pearl_id" "$script_cmd")

    if tmux has-session -t "$tmux_session" 2>/dev/null; then
        if tmux list-windows -t "$tmux_session" -F '#W' | grep -Fxq "$tmux_window"; then
            echo "Attaching to existing tmux window: ${tmux_session}:${tmux_window}" >&2
        else
            tmux new-window -t "$tmux_session" -n "$tmux_window" "$tmux_cmd"
            echo "Started tmux window: ${tmux_session}:${tmux_window}" >&2
        fi
    else
        tmux new-session -d -s "$tmux_session" -n "$tmux_window" "$tmux_cmd"
        echo "Started tmux session/window: ${tmux_session}:${tmux_window}" >&2
    fi

    printf '%s:%s\n' "$tmux_session" "$tmux_window"
}

create_new_tmux_shell_window() {
    local pearl_id="$1"
    local tmux_session
    local tmux_base_window
    local tmux_window
    local tmux_cmd
    local suffix

    tmux_session=$(repo_tmux_session_name)
    tmux_base_window=$(pearl_tmux_window_name "$pearl_id")
    tmux_window="${tmux_base_window}-shell"

    if tmux has-session -t "$tmux_session" 2>/dev/null; then
        suffix=2
        while tmux list-windows -t "$tmux_session" -F '#W' | grep -Fxq "$tmux_window"; do
            tmux_window="${tmux_base_window}-shell-${suffix}"
            suffix=$((suffix + 1))
        done
    fi

    tmux_cmd=$(build_tmux_shell_command "$pearl_id")

    if tmux has-session -t "$tmux_session" 2>/dev/null; then
        tmux new-window -t "$tmux_session" -n "$tmux_window" "$tmux_cmd"
        echo "Started tmux window: ${tmux_session}:${tmux_window}" >&2
    else
        tmux new-session -d -s "$tmux_session" -n "$tmux_window" "$tmux_cmd"
        echo "Started tmux session/window: ${tmux_session}:${tmux_window}" >&2
    fi

    printf '%s:%s\n' "$tmux_session" "$tmux_window"
}

select_pearl_id_for_tmux_window() {
    local json_data
    local items_json
    local selected_line
    local pearl_id

    json_data=$(prl list --status open --json 2>/dev/null)
    items_json=$(echo "$json_data" | jq -c 'if type == "object" and has("pearls") then .pearls else . end' 2>/dev/null)

    if [ -n "$items_json" ] && [ "$items_json" != "null" ] && [ "$items_json" != "[]" ]; then
        selected_line=$(echo "$items_json" | jq -r '.[] | "[\(.id)] (\(.status)) \(.title)"' | fzf --prompt="Pearl for new shell: " --height=60% --layout=reverse)
        if [ -n "$selected_line" ]; then
            pearl_id=$(echo "$selected_line" | awk -F'[][]' '{print $2}')
            printf '%s\n' "$pearl_id"
            return 0
        fi
    fi

    read -rp "Pearl ID for new shell window: " pearl_id
    if [ -n "$pearl_id" ]; then
        printf '%s\n' "$pearl_id"
        return 0
    fi

    return 1
}


summarize_tmux_repo_session() {
    local repo_session="$1"
    local window_count
    local window_preview
    local display_limit

    if ! tmux has-session -t "$repo_session" 2>/dev/null; then
        printf 'not running'
        return
    fi

    window_count=$(tmux list-windows -t "$repo_session" -F '#W' 2>/dev/null | wc -l | tr -d '[:space:]')
    window_preview=$(tmux list-windows -t "$repo_session" -F '#W' 2>/dev/null)
    display_limit=3
    window_preview=$(printf '%s\n' "$window_preview" | head -n "$display_limit" | paste -sd ', ' -)

    if [ -z "$window_preview" ]; then
        printf 'running (%s windows)' "$window_count"
        return
    fi

    if [ "$window_count" -gt "$display_limit" ]; then
        window_preview="${window_preview}, ..."
    fi

    printf 'running (%s windows: %s)' "$window_count" "$window_preview"
}

tmux_command_center() {
    if ! command -v tmux &> /dev/null; then
        echo "tmux is required, but it is not installed."
        read -n 1 -s -r -p "Press any key to continue..."
        return
    fi

    local repo_session
    local choice
    local target
    local session
    local window
    local sessions
    local new_pearl_id
    local repo_session_status
    local ptui_session_count
    local create_missing_choice

    repo_session=$(repo_tmux_session_name)

    while true; do
        repo_session_status=$(summarize_tmux_repo_session "$repo_session")
        ptui_session_count=$(tmux list-sessions -F '#S' 2>/dev/null | grep '^ptui-' | wc -l | tr -d '[:space:]')
        choice=$(printf "[Status] Current Repo Session: %s (%s)\n[Status] ptui Sessions: %s\nAttach Here (Current Repo Session)\nOpen New Terminal (Current Repo Session)\nNew Pearl Shell (Attach Here)\nNew Pearl Shell (Open New Terminal)\nAttach Here (Pick ptui Session/Window)\nOpen New Terminal (Pick ptui Session/Window)\nBack" \
            "$repo_session" \
            "$repo_session_status" \
            "$ptui_session_count" | \
            fzf --prompt="Tmux Command Center: " --height=65% --layout=reverse)

        case "$choice" in
            "Back"|"")
                return
                ;;
            "[Status]"*)
                continue
                ;;
            "Attach Here (Current Repo Session)")
                if ! tmux has-session -t "$repo_session" 2>/dev/null; then
                    echo "No tmux session for current repo: $repo_session"
                    create_missing_choice=$(printf "Create now with New Pearl Shell (Attach Here)\nBack" | fzf --prompt="Current repo session is not running: " --height=25% --layout=reverse)
                    if [ "$create_missing_choice" = "Create now with New Pearl Shell (Attach Here)" ]; then
                        new_pearl_id=$(select_pearl_id_for_tmux_window) || continue
                        target=$(create_new_tmux_shell_window "$new_pearl_id")
                        tmux attach-session -t "$target"
                    fi
                    continue
                fi
                tmux attach-session -t "$repo_session"
                ;;
            "Open New Terminal (Current Repo Session)")
                if ! tmux has-session -t "$repo_session" 2>/dev/null; then
                    echo "No tmux session for current repo: $repo_session"
                    create_missing_choice=$(printf "Create now with New Pearl Shell (Open New Terminal)\nBack" | fzf --prompt="Current repo session is not running: " --height=25% --layout=reverse)
                    if [ "$create_missing_choice" = "Create now with New Pearl Shell (Open New Terminal)" ]; then
                        new_pearl_id=$(select_pearl_id_for_tmux_window) || continue
                        target=$(create_new_tmux_shell_window "$new_pearl_id")
                        open_new_terminal_with_tmux_target "$target"
                        read -n 1 -s -r -p "Press any key to continue..."
                    fi
                    continue
                fi
                open_new_terminal_with_tmux_target "$repo_session"
                read -n 1 -s -r -p "Press any key to continue..."
                ;;
            "New Pearl Shell (Attach Here)"|"New Pearl Shell (Open New Terminal)")
                new_pearl_id=$(select_pearl_id_for_tmux_window) || continue
                target=$(create_new_tmux_shell_window "$new_pearl_id")

                if [ "$choice" = "New Pearl Shell (Attach Here)" ]; then
                    tmux attach-session -t "$target"
                else
                    open_new_terminal_with_tmux_target "$target"
                    read -n 1 -s -r -p "Press any key to continue..."
                fi
                ;;
            "Attach Here (Pick ptui Session/Window)"|"Open New Terminal (Pick ptui Session/Window)")
                sessions=$(tmux list-sessions -F '#S' 2>/dev/null | grep '^ptui-' || true)
                if [ -z "$sessions" ]; then
                    echo "No ptui tmux sessions found."
                    read -n 1 -s -r -p "Press any key to continue..."
                    continue
                fi

                session=$(echo "$sessions" | fzf --prompt="Tmux session: " --height=35% --layout=reverse)
                if [ -z "$session" ]; then
                    continue
                fi

                window=$(printf "[Session default]\n%s\n" "$(tmux list-windows -t "$session" -F '#W' 2>/dev/null)" | fzf --prompt="Tmux window: " --height=40% --layout=reverse)
                if [ -z "$window" ] || [ "$window" = "[Session default]" ]; then
                    target="$session"
                else
                    target="$session:$window"
                fi

                if [ "$choice" = "Attach Here (Pick ptui Session/Window)" ]; then
                    tmux attach-session -t "$target"
                else
                    open_new_terminal_with_tmux_target "$target"
                    read -n 1 -s -r -p "Press any key to continue..."
                fi
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
        prl show "$pearl_id" --format plain
        echo "----------------------------------------"

        local valid_scripts
        valid_scripts=$(jq -r --arg status "$pearl_status" '.scripts[] | select(.target_status == $status or .target_status == "any") | [.name, .command, ((.run_in_tmux // false) | tostring)] | @tsv' "$CONFIG_FILE")

        local options="[Update Pearl]\n[View JSON]\n[Back]"
        if [ -n "$valid_scripts" ]; then
            local script_names
            script_names=$(echo "$valid_scripts" | awk -F'\t' '{print "[Run] " $1}')
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
                local chosen_name="${choice#\[Run\] }"
                local script_record
                local script_cmd
                local run_in_tmux
                script_record=$(echo "$valid_scripts" | awk -F'\t' -v name="$chosen_name" '$1 == name { print $0; exit }')
                script_cmd=$(echo "$script_record" | awk -F'\t' '{print $2}')
                run_in_tmux=$(echo "$script_record" | awk -F'\t' '{print $3}')

                if [ -n "$script_cmd" ]; then
                    clear
                    echo "Executing: $chosen_name..."
                    export REPO_PATH="$SELECTED_REPO"
                    export PEARL_ID="$pearl_id"

                    if [ "$run_in_tmux" = "true" ]; then
                        if ! command -v tmux &> /dev/null; then
                            echo "tmux is required for this script, but it is not installed."
                            read -n 1 -s -r -p "Press any key to continue..."
                            return
                        fi

                        local tmux_target
                        tmux_target=$(ensure_tmux_for_script "$pearl_id" "$script_cmd")
                        attach_tmux_target "$tmux_target"
                        return
                    fi

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
                    return
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

    # Format for fzf: ID | Priority | Status | Title | Labels
    local selected_line
    selected_line=$(echo "$items_json" | jq -r '.[] | "[\(.id)] P\(.priority) (\(.status)) \(.title) [labels: \(((.labels // []) | if length > 0 then join(",") else "-" end))]"' | fzf --prompt="$prompt_msg" --height=8 --layout=reverse)

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
    cat <<EOB
┌────────────────────────────────────────────────────────┐
│                                                        │
│                                                        │
│                                    [0;1;30;90m███[0m                 │
│                                      [0;1;30;90m█[0m                 │
│                                      [0;1;34;94m█[0m                 │
│        [0;1;30;90m█▓██[0m    [0;1;30;90m███[0m   [0;1;30;90m░█[0;1;34;94m██░[0m   [0;1;34;94m█▒██▒[0m   [0;1;34;94m█[0m    [0;34m▒███▒[0m        │
│        [0;1;30;90m█▓[0m [0;1;30;90m▓█[0m  [0;1;30;90m▓[0;1;34;94m▓[0m [0;1;34;94m▒█[0m  [0;1;34;94m█▒[0m [0;1;34;94m▒█[0m   [0;1;34;94m██[0m  [0;34m█[0m   [0;34m█[0m    [0;34m█▒[0m [0;34m░█[0m        │
│        [0;1;34;94m█[0m   [0;1;34;94m█[0m  [0;1;34;94m█[0m   [0;1;34;94m█[0m      [0;34m█[0m   [0;34m█[0m       [0;34m█[0m    [0;37m█▒░[0m          │
│        [0;1;34;94m█[0m   [0;1;34;94m█[0m  [0;1;34;94m█[0;34m████[0m  [0;34m▒████[0m   [0;34m█[0m       [0;37m█[0m    [0;37m░███▒[0m        │
│        [0;34m█[0m   [0;34m█[0m  [0;34m█[0m      [0;34m█▒[0m  [0;37m█[0m   [0;37m█[0m       [0;37m█[0m       [0;1;30;90m▒█[0m        │
│        [0;34m█▓[0m [0;34m▓█[0m  [0;34m▓[0;37m▓[0m  [0;37m█[0m  [0;37m█░[0m [0;37m▓█[0m   [0;37m█[0m       [0;1;30;90m█░[0m   [0;1;30;90m█░[0m [0;1;30;90m▒█[0m        │
│        [0;37m█▓██[0m    [0;37m███▒[0m  [0;37m▒█[0;1;30;90m█▒█[0m   [0;1;30;90m█[0m       [0;1;30;90m▒█[0;1;34;94m█[0m  [0;1;34;94m▒███▒[0m        │
│        [0;37m█[0m                                               │
│        [0;1;30;90m█[0m                                               │
│        [0;1;30;90m█[0m                                               │
└────────────────────────────────────────────────────────┘
EOB

    main_choice=$(printf "1. Ready Queue\n2. All Open\n3. Create New Pearl\n4. Change Repo\n5. Tmux Command Center\n6. Exit" | fzf --prompt="Menu: " --height=35% --layout=reverse)

    case "$main_choice" in
        "1. Ready Queue") list_pearls "ready" ;;
        "2. All Open") list_pearls "open" ;;
        "3. Create New Pearl") create_pearl ;;
        "4. Change Repo") select_repo ;;
        "5. Tmux Command Center") tmux_command_center ;;
        "6. Exit"|"") clear; exit 0 ;;
    esac
done
