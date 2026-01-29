#!/usr/bin/env bash
# pai-lite/lib/tasks.sh - Task aggregation
# Pulls tasks from GitHub issues, README TODOs, and other sources

# Requires: STATE_DIR, CONFIG_FILE to be set by the main script

#------------------------------------------------------------------------------
# Task file operations
#------------------------------------------------------------------------------

tasks_file() {
    echo "$STATE_DIR/tasks.yaml"
}

#------------------------------------------------------------------------------
# Task ID format
#   GitHub issues: project#123 (e.g., ocannl#42)
#   README TODOs:  project:readme:N (e.g., ocannl:readme:1)
#   Roadmap items: project:roadmap:N
#------------------------------------------------------------------------------

parse_task_id() {
    local task_id="$1"
    local project="" type="" number=""

    if [[ "$task_id" =~ ^([a-zA-Z0-9_-]+)#([0-9]+)$ ]]; then
        project="${BASH_REMATCH[1]}"
        type="issue"
        number="${BASH_REMATCH[2]}"
    elif [[ "$task_id" =~ ^([a-zA-Z0-9_-]+):([a-z]+):([0-9]+)$ ]]; then
        project="${BASH_REMATCH[1]}"
        type="${BASH_REMATCH[2]}"
        number="${BASH_REMATCH[3]}"
    else
        return 1
    fi

    echo "project=$project"
    echo "type=$type"
    echo "number=$number"
}

#------------------------------------------------------------------------------
# GitHub issue fetching
#------------------------------------------------------------------------------

fetch_github_issues() {
    local repo="$1"
    local project_name="$2"

    require_command gh

    debug "fetching issues from $repo..."

    # Fetch open issues as JSON, then format
    gh issue list --repo "$repo" --state open --limit 100 --json number,title,labels,updatedAt 2>/dev/null | \
    while IFS= read -r line; do
        # Parse JSON lines (simplified - gh outputs one JSON array)
        echo "$line"
    done
}

# Parse gh issue list JSON output into task entries
parse_issues_json() {
    local project_name="$1"
    local json="$2"

    # Use simple text parsing since we can't rely on jq
    # gh issue list --json outputs: [{"number":1,"title":"...","labels":[...],"updatedAt":"..."},...]

    echo "$json" | tr ',' '\n' | while IFS= read -r fragment; do
        if [[ "$fragment" =~ \"number\":([0-9]+) ]]; then
            current_number="${BASH_REMATCH[1]}"
        fi
        if [[ "$fragment" =~ \"title\":\"([^\"]+)\" ]]; then
            current_title="${BASH_REMATCH[1]}"
            # Output task entry
            if [[ -n "$current_number" && -n "$current_title" ]]; then
                echo "  - id: ${project_name}#${current_number}"
                echo "    title: \"$current_title\""
                echo "    type: issue"
                echo "    source: github"
            fi
        fi
    done
}

#------------------------------------------------------------------------------
# README TODO parsing
#------------------------------------------------------------------------------

parse_readme_todos() {
    local repo_dir="$1"
    local project_name="$2"

    local readme=""
    for f in README.md README.rst README.txt README; do
        if [[ -f "$repo_dir/$f" ]]; then
            readme="$repo_dir/$f"
            break
        fi
    done

    [[ -z "$readme" ]] && return 0

    debug "parsing TODOs from $readme..."

    local todo_num=0
    local in_todo_section=false

    while IFS= read -r line; do
        # Look for TODO section headers
        if [[ "$line" =~ ^#+[[:space:]]*(TODO|Tasks|Roadmap) ]]; then
            in_todo_section=true
            continue
        fi

        # End TODO section at next major header
        if $in_todo_section && [[ "$line" =~ ^#[^#] ]]; then
            in_todo_section=false
        fi

        # Parse TODO items (checkboxes or bullet points with TODO)
        if [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]*\[[[:space:]]\][[:space:]]+(.*) ]]; then
            ((todo_num++))
            local title="${BASH_REMATCH[1]}"
            echo "  - id: ${project_name}:readme:${todo_num}"
            echo "    title: \"$title\""
            echo "    type: todo"
            echo "    source: readme"
        elif [[ "$line" =~ TODO:[[:space:]]*(.*) ]]; then
            ((todo_num++))
            local title="${BASH_REMATCH[1]}"
            echo "  - id: ${project_name}:readme:${todo_num}"
            echo "    title: \"$title\""
            echo "    type: todo"
            echo "    source: readme"
        fi
    done < "$readme"
}

#------------------------------------------------------------------------------
# CHANGES.md / Roadmap parsing
#------------------------------------------------------------------------------

parse_roadmap() {
    local repo_dir="$1"
    local project_name="$2"

    local changes_file=""
    for f in CHANGES.md CHANGELOG.md ROADMAP.md; do
        if [[ -f "$repo_dir/$f" ]]; then
            changes_file="$repo_dir/$f"
            break
        fi
    done

    [[ -z "$changes_file" ]] && return 0

    debug "parsing roadmap from $changes_file..."

    local item_num=0
    local in_unreleased=false

    while IFS= read -r line; do
        # Look for Unreleased/Next section
        if [[ "$line" =~ ^#+[[:space:]]*(Unreleased|Next|Upcoming|Planned) ]]; then
            in_unreleased=true
            continue
        fi

        # End at next version header
        if $in_unreleased && [[ "$line" =~ ^#+[[:space:]]*\[?[0-9]+\.[0-9]+ ]]; then
            break
        fi

        # Parse bullet items in unreleased section
        if $in_unreleased && [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]+(.*) ]]; then
            ((item_num++))
            local title="${BASH_REMATCH[1]}"
            # Skip if it's a completed item (starts with checkmark or done)
            [[ "$title" =~ ^(\[x\]|Done:|Completed:) ]] && continue

            echo "  - id: ${project_name}:roadmap:${item_num}"
            echo "    title: \"$title\""
            echo "    type: roadmap"
            echo "    source: changes"
        fi
    done < "$changes_file"
}

#------------------------------------------------------------------------------
# Task sync - main aggregation function
#------------------------------------------------------------------------------

tasks_sync() {
    info "syncing tasks from all sources..."

    local tasks_yaml
    tasks_yaml="$(tasks_file)"

    # Start fresh tasks file
    cat > "$tasks_yaml" <<EOF
# pai-lite task index
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Do not edit manually - regenerated by 'pai-lite tasks sync'

tasks:
EOF

    # Read projects from config
    local projects_count=0
    local current_project=""
    local current_repo=""
    local issues_enabled=false
    local readme_todos=false

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Detect project entries
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.+) ]]; then
            # Process previous project if any
            if [[ -n "$current_project" && -n "$current_repo" ]]; then
                sync_project "$current_project" "$current_repo" "$issues_enabled" "$readme_todos" >> "$tasks_yaml"
            fi

            current_project="${BASH_REMATCH[1]}"
            current_repo=""
            issues_enabled=false
            readme_todos=false
            ((projects_count++))
        elif [[ "$line" =~ ^[[:space:]]*repo:[[:space:]]*(.+) ]]; then
            current_repo="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*issues:[[:space:]]*(true|yes) ]]; then
            issues_enabled=true
        elif [[ "$line" =~ ^[[:space:]]*readme_todos:[[:space:]]*(true|yes) ]]; then
            readme_todos=true
        fi
    done < "$CONFIG_FILE"

    # Process last project
    if [[ -n "$current_project" && -n "$current_repo" ]]; then
        sync_project "$current_project" "$current_repo" "$issues_enabled" "$readme_todos" >> "$tasks_yaml"
    fi

    success "synced $projects_count projects to $tasks_yaml"
}

sync_project() {
    local project_name="$1"
    local repo="$2"
    local issues_enabled="$3"
    local readme_todos="$4"

    debug "syncing project: $project_name ($repo)"

    echo ""
    echo "  # $project_name"

    # GitHub issues
    if [[ "$issues_enabled" == "true" ]]; then
        # Check for gh only once when first needed
        if [[ -z "${_GH_CHECKED:-}" ]]; then
            require_command gh
            _GH_CHECKED=1
        fi
        local issues_json
        issues_json="$(gh issue list --repo "$repo" --state open --limit 50 --json number,title 2>/dev/null || echo "")"

        if [[ -n "$issues_json" && "$issues_json" != "[]" ]]; then
            # Parse JSON (simple approach without jq)
            # Format: [{"number":1,"title":"foo"},{"number":2,"title":"bar"}]
            echo "$issues_json" | sed 's/},{/}\n{/g' | while IFS= read -r item; do
                local num title
                if [[ "$item" =~ \"number\":([0-9]+) ]]; then
                    num="${BASH_REMATCH[1]}"
                fi
                if [[ "$item" =~ \"title\":\"([^\"]+)\" ]]; then
                    title="${BASH_REMATCH[1]}"
                fi
                if [[ -n "$num" && -n "$title" ]]; then
                    echo "  - id: \"${project_name}#${num}\""
                    echo "    title: \"$title\""
                    echo "    type: issue"
                    echo "    repo: \"$repo\""
                fi
            done
        fi
    fi

    # README TODOs
    if [[ "$readme_todos" == "true" ]]; then
        local repo_name="${repo##*/}"
        local repo_dir="$HOME/$repo_name"

        if [[ -d "$repo_dir" ]]; then
            parse_readme_todos "$repo_dir" "$project_name"
            parse_roadmap "$repo_dir" "$project_name"
        else
            debug "repo not cloned locally: $repo_dir"
        fi
    fi
}

#------------------------------------------------------------------------------
# Task listing and display
#------------------------------------------------------------------------------

tasks_list() {
    local tasks_yaml
    tasks_yaml="$(tasks_file)"

    if [[ ! -f "$tasks_yaml" ]]; then
        warn "no tasks file found. Run 'pai-lite tasks sync' first."
        return 1
    fi

    echo -e "${BOLD}Tasks${NC}"
    echo ""

    local current_project=""

    while IFS= read -r line; do
        # Skip header comments
        [[ "$line" =~ ^# ]] && continue

        # Project headers
        if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*(.+) ]]; then
            current_project="${BASH_REMATCH[1]}"
            echo -e "${BOLD}$current_project${NC}"
            continue
        fi

        # Task entries
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*id:[[:space:]]*\"?([^\"]+)\"? ]]; then
            local task_id="${BASH_REMATCH[1]}"
            # Read next line for title
            read -r title_line
            if [[ "$title_line" =~ title:[[:space:]]*\"?([^\"]+)\"? ]]; then
                local title="${BASH_REMATCH[1]}"
                echo "  ${BLUE}$task_id${NC}: $title"
            fi
        fi
    done < "$tasks_yaml"
}

tasks_recent() {
    local limit="${1:-5}"
    local tasks_yaml
    tasks_yaml="$(tasks_file)"

    if [[ ! -f "$tasks_yaml" ]]; then
        return 0
    fi

    echo -e "${BOLD}Recent Tasks:${NC}"

    local count=0
    while IFS= read -r line; do
        [[ $count -ge $limit ]] && break

        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*id:[[:space:]]*\"?([^\"]+)\"? ]]; then
            local task_id="${BASH_REMATCH[1]}"
            read -r title_line
            if [[ "$title_line" =~ title:[[:space:]]*\"?([^\"]+)\"? ]]; then
                local title="${BASH_REMATCH[1]}"
                echo "  $task_id: $title"
                ((count++))
            fi
        fi
    done < "$tasks_yaml"

    [[ $count -eq 0 ]] && echo "  (no tasks - run 'pai-lite tasks sync')"
}

tasks_pending() {
    local limit="${1:-10}"
    # For now, just list tasks (future: filter by priority/labels)
    tasks_recent "$limit"
}

task_show() {
    local task_id="$1"

    # Parse task ID
    local parsed
    parsed="$(parse_task_id "$task_id")" || die "invalid task ID format: $task_id"

    eval "$parsed"

    echo -e "${BOLD}Task: $task_id${NC}"
    echo ""

    case "$type" in
        issue)
            # Fetch from GitHub
            local repo
            repo="$(get_repo_for_project "$project")" || die "unknown project: $project"

            echo -e "${BOLD}Type:${NC} GitHub Issue"
            echo -e "${BOLD}Repository:${NC} $repo"
            echo ""

            # Show issue details using gh
            gh issue view "$number" --repo "$repo" 2>/dev/null || die "failed to fetch issue"
            ;;
        readme|todo)
            echo -e "${BOLD}Type:${NC} README TODO"
            echo -e "${BOLD}Project:${NC} $project"
            echo -e "${BOLD}Item:${NC} #$number"

            # Try to find the actual TODO text
            local tasks_yaml
            tasks_yaml="$(tasks_file)"
            if [[ -f "$tasks_yaml" ]]; then
                grep -A1 "id:.*$task_id" "$tasks_yaml" | grep "title:" | sed 's/.*title:[[:space:]]*"\?\([^"]*\)"\?/\nTitle: \1/'
            fi
            ;;
        roadmap)
            echo -e "${BOLD}Type:${NC} Roadmap Item"
            echo -e "${BOLD}Project:${NC} $project"
            echo -e "${BOLD}Item:${NC} #$number"
            ;;
        *)
            die "unknown task type: $type"
            ;;
    esac
}

task_get_title() {
    local task_id="$1"
    local tasks_yaml
    tasks_yaml="$(tasks_file)"

    [[ ! -f "$tasks_yaml" ]] && return 1

    grep -A1 "id:.*$task_id" "$tasks_yaml" 2>/dev/null | grep "title:" | sed 's/.*title:[[:space:]]*"\?\([^"]*\)"\?/\1/' | head -1
}

get_repo_for_project() {
    local project_name="$1"

    local in_project=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*$project_name[[:space:]]*$ ]]; then
            in_project=true
            continue
        fi

        if $in_project; then
            if [[ "$line" =~ ^[[:space:]]*repo:[[:space:]]*(.+) ]]; then
                echo "${BASH_REMATCH[1]}"
                return 0
            fi
            # Next project starts
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name: ]]; then
                break
            fi
        fi
    done < "$CONFIG_FILE"

    return 1
}
