#!/usr/bin/env bash
# =============================================================================
# deploy_agent.sh - Bootstrap, run and archive the Student Attendance Tracker
#
# Usage:
#   ./deploy_agent.sh                 interactive menu
#   ./deploy_agent.sh --deploy        feature 1: deploy
#   ./deploy_agent.sh --run           feature 2: run
#   ./deploy_agent.sh --archive       feature 3: archive logs
#   ./deploy_agent.sh --help
#
# Expects a templates/ folder next to this script containing the three
# unmodified source files: attendance_checker.py, assets.csv, config.json
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

# Set once creation of a project directory begins; used by the signal handler.
DEPLOY_DIR=""
DEPLOY_NAME=""

# ----------------------------------------------------------------- helpers ---
info()  { printf '[INFO]  %s\n' "$*"; }
ok()    { printf '[ OK ]  %s\n' "$*"; }
warn()  { printf '[WARN]  %s\n' "$*" >&2; }
err()   { printf '[ERROR] %s\n' "$*" >&2; }

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# Ask for a project name; sets global NAME_INPUT (letters, digits, _ and - only)
ask_project_name() {
    local raw
    while true; do
        read -r -p "Project name (directory will be attendance_tracker_<name>): " raw
        if [[ -z "$raw" ]]; then
            err "Name cannot be empty."
        elif [[ ! "$raw" =~ ^[A-Za-z0-9_-]+$ ]]; then
            err "Use only letters, digits, '_' and '-'."
        else
            NAME_INPUT="$raw"
            return 0
        fi
    done
}

# Ask for an integer in [min,max]; sets global INT_INPUT
ask_int_in_range() {
    local prompt="$1" min="$2" max="$3" val
    while true; do
        read -r -p "$prompt ($min-$max): " val
        if is_uint "$val" && (( val >= min && val <= max )); then
            INT_INPUT="$val"
            return 0
        fi
        err "Please enter a whole number between $min and $max."
    done
}

# ------------------------------------------------------------ signal handling
# Called on Ctrl+C (SIGINT) or Ctrl+Z (SIGTSTP) while deploying:
# zip whatever exists, delete the half-made directory, exit cleanly.
handle_interrupt() {
    trap '' INT TSTP   # ignore further signals while cleaning up
    echo
    warn "Deployment interrupted by user (signal received)."

    if [[ -n "$DEPLOY_DIR" && -d "$SCRIPT_DIR/$DEPLOY_DIR" ]]; then
        local zipfile="${DEPLOY_DIR}_archive.zip"
        info "Archiving incomplete project into $zipfile ..."
        if ( cd "$SCRIPT_DIR" && rm -f "$zipfile" && zip -rq "$zipfile" "$DEPLOY_DIR" ); then
            ok "Archive created: $SCRIPT_DIR/$zipfile"
            rm -rf "${SCRIPT_DIR:?}/$DEPLOY_DIR"
            ok "Removed incomplete directory: $DEPLOY_DIR"
        else
            err "Could not create the zip archive; leaving $DEPLOY_DIR in place."
        fi
    else
        info "Nothing had been created yet, so there is nothing to archive."
    fi

    info "Session closed cleanly."
    exit 130
}

# Called on a normal deployment error: remove what we created, no zip.
abort_deploy() {
    err "$*"
    if [[ -n "$DEPLOY_DIR" && -d "$SCRIPT_DIR/$DEPLOY_DIR" ]]; then
        rm -rf "${SCRIPT_DIR:?}/$DEPLOY_DIR"
        info "Removed partially created directory: $DEPLOY_DIR"
    fi
    trap - INT TSTP
    exit 1
}

# ------------------------------------------------------- feature 1: deploy ---
preflight_checks() {
    local missing=0
    for cmd in python3 zip; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            err "Required command '$cmd' is not installed."
            missing=1
        fi
    done
    (( missing )) && { err "Install the missing tool(s) and try again."; exit 1; }

    ok "$(python3 --version 2>&1) found"
    ok "zip found"

    for f in attendance_checker.py assets.csv config.json; do
        if [[ ! -f "$TEMPLATES_DIR/$f" ]]; then
            err "Missing template: $TEMPLATES_DIR/$f"
            exit 1
        fi
    done
    ok "All templates present in templates/"
}

# Option A: copy N student rows (plus header) from the template.
build_roster_copy() {
    local dest="$1"
    local available
    available=$(( $(wc -l < "$TEMPLATES_DIR/assets.csv") - 1 ))
    (( available < 1 )) && abort_deploy "Template assets.csv has no student rows."
    ask_int_in_range "How many students to copy from the template" 1 "$available"
    head -n $(( INT_INPUT + 1 )) "$TEMPLATES_DIR/assets.csv" > "$dest" \
        || abort_deploy "Could not write $dest"
    ok "Copied header + $INT_INPUT student(s) from template."
    SESSIONS_VALUE=5    # template rows carry 4 prior sessions
}

# Option B: generate a fresh roster with zeroed counts.
build_roster_generate() {
    local dest="$1"
    local first=(Alice Bob Carol David Emma Frank Grace Henry Irene James
                 Karen Liam Mia Noah Olivia Peter Queen Ryan Sara Tom)
    local last=(Johnson Smith Williams Brown Jones Garcia Miller Davis Wilson Moore)
    local max=${#first[@]}
    ask_int_in_range "How many students to generate" 1 "$max"
    {
        echo "Email,Names,Attendance Count,Absence Count"
        local i fn ln
        for (( i = 0; i < INT_INPUT; i++ )); do
            fn="${first[$i]}"
            ln="${last[$(( i % ${#last[@]} ))]}"
            printf '%s@example.com,%s %s,0,0\n' "$(tr '[:upper:]' '[:lower:]' <<< "$fn")" "$fn" "$ln"
        done
    } > "$dest" || abort_deploy "Could not write $dest"
    ok "Generated fresh roster with $INT_INPUT student(s)."
    SESSIONS_VALUE=1    # nobody has any prior sessions
}

update_thresholds() {
    local cfg="$1" ans warn_val fail_val
    read -r -p "Update attendance alert thresholds? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "Keeping default thresholds."; return 0; }

    while true; do
        read -r -p "Warning threshold % (default 75): " warn_val
        warn_val="${warn_val:-75}"
        read -r -p "Failure threshold % (default 50): " fail_val
        fail_val="${fail_val:-50}"

        if ! is_uint "$warn_val" || ! is_uint "$fail_val"; then
            err "Both values must be whole numbers."; continue
        fi
        if (( warn_val > 100 || fail_val > 100 )); then
            err "Values must be between 0 and 100."; continue
        fi
        if (( fail_val >= warn_val )); then
            err "Failure threshold must be lower than the warning threshold."; continue
        fi
        break
    done

    # In-place edit of just those two lines (portable: GNU and BSD sed).
    sed -i.bak \
        -e "s/\"warning\": *[0-9][0-9]*/\"warning\": $warn_val/" \
        -e "s/\"failure\": *[0-9][0-9]*/\"failure\": $fail_val/" "$cfg" \
        || abort_deploy "sed failed to update $cfg"
    rm -f "$cfg.bak"
    ok "Thresholds updated: warning=$warn_val, failure=$fail_val"
}

deploy_project() {
    echo "=== Deploy the application ==="
    preflight_checks

    ask_project_name
    DEPLOY_NAME="$NAME_INPUT"
    local dir="attendance_tracker_${DEPLOY_NAME}"
    local full="$SCRIPT_DIR/$dir"

    if [[ -e "$full" ]]; then
        warn "'$dir' already exists."
        local ow
        read -r -p "Overwrite it? [y/N]: " ow
        if [[ "$ow" =~ ^[Yy]$ ]]; then
            rm -rf "$full" || { err "Could not remove existing directory (permission denied?)."; exit 1; }
        else
            err "Aborted: existing directory left untouched."
            exit 1
        fi
    fi

    # From here on, an interrupt must archive + clean up.
    DEPLOY_DIR="$dir"
    trap handle_interrupt INT TSTP

    info "Creating structure in $dir/ ..."
    mkdir -p "$full/Helpers" "$full/reports" \
        || abort_deploy "Could not create directories (permission denied?)."

    cp "$TEMPLATES_DIR/attendance_checker.py" "$full/attendance_checker.py" \
        || abort_deploy "Could not copy attendance_checker.py"
    cp "$TEMPLATES_DIR/config.json" "$full/Helpers/config.json" \
        || abort_deploy "Could not copy config.json"

    echo
    echo "How should the roster (Helpers/assets.csv) be built?"
    echo "  A) Copy students from the template (4 prior sessions each)"
    echo "  B) Generate a fresh roster (counts start at 0)"
    local choice
    while true; do
        read -r -p "Choose A or B: " choice
        case "$choice" in
            [Aa]) build_roster_copy     "$full/Helpers/assets.csv"; break ;;
            [Bb]) build_roster_generate "$full/Helpers/assets.csv"; break ;;
            *) err "Please enter A or B." ;;
        esac
    done

    # Keep total_sessions consistent with the roster (prior sessions + 1).
    if [[ "$SESSIONS_VALUE" != "5" ]]; then
        sed -i.bak "s/\"total_sessions\": *[0-9][0-9]*/\"total_sessions\": $SESSIONS_VALUE/" \
            "$full/Helpers/config.json" || abort_deploy "Could not set total_sessions"
        rm -f "$full/Helpers/config.json.bak"
    fi
    ok "total_sessions set to $SESSIONS_VALUE to match the roster."

    chmod +x "$full/attendance_checker.py" || abort_deploy "chmod +x failed"
    chmod 600 "$full/Helpers/config.json" || abort_deploy "chmod 600 failed"
    ok "Permissions: attendance_checker.py -> $(stat -c '%A' "$full/attendance_checker.py" 2>/dev/null || ls -l "$full/attendance_checker.py" | cut -c1-10)," \
       "config.json -> $(stat -c '%A' "$full/Helpers/config.json" 2>/dev/null || ls -l "$full/Helpers/config.json" | cut -c1-10)"

    echo
    update_thresholds "$full/Helpers/config.json"

    # Deployment finished: the trap no longer applies (it is for deploy only).
    trap - INT TSTP
    DEPLOY_DIR=""
    ok "Deployment complete."

    echo
    info "Verifying deployment by starting the application ..."
    run_project "$DEPLOY_NAME"
}

# --------------------------------------------------------- feature 2: run ---
run_project() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "=== Run the application ==="
        ask_project_name
        name="$NAME_INPUT"
    fi
    local full="$SCRIPT_DIR/attendance_tracker_${name}"

    if [[ ! -d "$full" || ! -f "$full/attendance_checker.py" ]]; then
        err "No deployed project found at attendance_tracker_${name}. Deploy it first."
        return 1
    fi
    command -v python3 >/dev/null 2>&1 || { err "python3 is not installed."; return 1; }

    ( cd "$full" && python3 attendance_checker.py )
    local rc=$?
    (( rc == 0 )) && ok "Application exited normally." || warn "Application exited with status $rc."
    return $rc
}

# ------------------------------------------------------ feature 3: archive ---
archive_logs() {
    echo "=== Archive log files ==="
    local name="${1:-}"
    if [[ -z "$name" ]]; then ask_project_name; name="$NAME_INPUT"; fi
    local full="$SCRIPT_DIR/attendance_tracker_${name}"

    [[ -d "$full" ]] || { err "Project attendance_tracker_${name} does not exist."; return 1; }

    local ts archived=0
    ts="$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$full/archives/attendance" "$full/archives/absent" \
        || { err "Could not create archive directories."; return 1; }

    local pair log kind dest
    for pair in "attendance:attendance" "absent:absent"; do
        log="${pair%%:*}"; kind="${pair##*:}"
        dest="$full/archives/$kind/${log}_${ts}.log"
        if [[ -f "$full/reports/${log}.log" ]]; then
            if mv "$full/reports/${log}.log" "$dest"; then
                ok "Archived ${log}.log -> archives/$kind/${log}_${ts}.log"
                archived=$(( archived + 1 ))
            else
                err "Failed to archive ${log}.log"
            fi
        else
            info "reports/${log}.log not found (nothing to archive)."
        fi
    done

    (( archived == 0 )) && warn "No logs were archived. Run the application first." 
    return 0
}

# -------------------------------------------------------------------- menu ---
usage() {
    sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

menu() {
    while true; do
        echo
        echo "======== Attendance Tracker Deploy Agent ========"
        echo " 1) Deploy the application"
        echo " 2) Run the application"
        echo " 3) Archive the log files"
        echo " 4) Quit"
        local c
        read -r -p "Select an option [1-4]: " c
        case "$c" in
            1) deploy_project ;;
            2) run_project ;;
            3) archive_logs ;;
            4) echo "Goodbye."; exit 0 ;;
            *) err "Invalid choice." ;;
        esac
    done
}

case "${1:-}" in
    "")          menu ;;
    --deploy)    deploy_project ;;
    --run)       run_project "${2:-}" ;;
    --archive)   archive_logs "${2:-}" ;;
    -h|--help)   usage ;;
    *)           err "Unknown option: $1"; usage; exit 1 ;;
esac
