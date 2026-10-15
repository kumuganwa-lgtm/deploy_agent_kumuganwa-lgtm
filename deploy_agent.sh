#!/usr/bin/env bash
# deploy_agent.sh - deploy, run and archive the Student Attendance Tracker
#
# Usage:
#   ./deploy_agent.sh              interactive menu
#   ./deploy_agent.sh --deploy     deploy a new project
#   ./deploy_agent.sh --run        run an existing project
#   ./deploy_agent.sh --archive    archive the logs of a project
#
# Needs a templates/ folder next to this script holding the three
# unmodified files: attendance_checker.py, assets.csv, config.json

# Always work from the folder this script lives in, so templates/ is found
# no matter where the script is started from.
cd "$(dirname "$0")" || exit 1

# Name of the project folder being built. The interrupt handler uses it.
PROJECT_DIR=""

# ----------------------------------------------------------------------------
# Signal handling: Ctrl+C (SIGINT) and Ctrl+Z (SIGTSTP) during deployment
# ----------------------------------------------------------------------------
cleanup_on_interrupt() {
    trap '' INT TSTP        # ignore more signals while we clean up
    echo
    echo "Deployment interrupted!"

    if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
        # Zip what exists so far. Only delete the folder if the zip worked.
        if zip -rq "${PROJECT_DIR}_archive.zip" "$PROJECT_DIR"; then
            rm -rf "$PROJECT_DIR"
            echo "Saved the incomplete project as ${PROJECT_DIR}_archive.zip"
            echo "Removed the incomplete folder $PROJECT_DIR"
        else
            echo "Could not create the zip, so $PROJECT_DIR was left in place."
        fi
    else
        echo "Nothing had been created yet."
    fi

    echo "Session closed."
    exit 130
}

# Used when a normal error happens during deployment: remove the half-made
# project and turn the trap off. The caller then does "return 1".
fail_deploy() {
    echo "Error: $1"
    if [ -n "$PROJECT_DIR" ]; then
        rm -rf "$PROJECT_DIR"
    fi
    PROJECT_DIR=""
    trap - INT TSTP
}

# ----------------------------------------------------------------------------
# Feature 1: deploy
# ----------------------------------------------------------------------------
deploy_project() {
    echo "=== Deploy the application ==="

    # --- 1. Pre-flight checks ---
    for tool in python3 zip; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Error: $tool is not installed. Install it and try again."
            return 1
        fi
    done
    python3 --version

    for file in attendance_checker.py assets.csv config.json; do
        if [ ! -f "templates/$file" ]; then
            echo "Error: templates/$file is missing."
            return 1
        fi
    done

    # --- 2. Project name ---
    read -r -p "Project name (folder will be attendance_tracker_<name>): " name
    if ! [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "Error: use only letters, digits, - and _ (and not empty)."
        return 1
    fi

    dir="attendance_tracker_$name"

    if [ -e "$dir" ]; then
        read -r -p "$dir already exists. Overwrite? (y/n): " answer
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            rm -rf "$dir" || { echo "Error: could not remove $dir."; return 1; }
        else
            echo "Deployment cancelled. Nothing was changed."
            return 1
        fi
    fi

    # From here on, Ctrl+C / Ctrl+Z archive and clean up.
    PROJECT_DIR="$dir"
    trap cleanup_on_interrupt INT TSTP

    # --- 3. Create the structure and copy the unmodified files ---
    mkdir -p "$dir/Helpers" "$dir/reports" \
        || { fail_deploy "could not create directories (permission denied?)"; return 1; }
    cp templates/attendance_checker.py "$dir/attendance_checker.py" \
        || { fail_deploy "could not copy attendance_checker.py"; return 1; }
    cp templates/config.json "$dir/Helpers/config.json" \
        || { fail_deploy "could not copy config.json"; return 1; }
    echo "Created $dir/ with Helpers/ and reports/"

    # --- 4. Build the roster ---
    echo
    echo "How should the roster be built?"
    echo "  1) Copy students from the template"
    echo "  2) Generate a new roster"
    read -r -p "Choose 1 or 2: " option

    if [ "$option" = "1" ]; then
        # awk counts the last line even when the file has no trailing newline
        available=$(( $(awk 'END{print NR}' templates/assets.csv) - 1 ))
        read -r -p "How many students to copy (1-$available)? " count
        if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ] || [ "$count" -gt "$available" ]; then
            fail_deploy "enter a whole number from 1 to $available"
            return 1
        fi
        # header line + the first $count students
        head -n $((count + 1)) templates/assets.csv > "$dir/Helpers/assets.csv"
        sessions=5      # template students already have 4 sessions recorded

    elif [ "$option" = "2" ]; then
        first_names=(Alice Bob Charlie Diana Ethan Fatima George Hannah Ibrahim Jasmine)
        read -r -p "How many students to generate (1-10)? " count
        if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ] || [ "$count" -gt 10 ]; then
            fail_deploy "enter a whole number from 1 to 10"
            return 1
        fi
        echo "Email,Names,Attendance Count,Absence Count" > "$dir/Helpers/assets.csv"
        i=0
        while [ "$i" -lt "$count" ]; do
            student="${first_names[$i]}"
            lower=$(echo "$student" | tr '[:upper:]' '[:lower:]')
            echo "$lower@example.com,$student Student,0,0" >> "$dir/Helpers/assets.csv"
            i=$((i + 1))
        done
        sessions=1      # brand new roster: today is the first session

    else
        fail_deploy "please choose 1 or 2"
        return 1
    fi
    echo "Roster created."

    # total_sessions must equal (sessions already recorded) + 1
    sed -i.bak "s/\"total_sessions\": [0-9]*/\"total_sessions\": $sessions/" "$dir/Helpers/config.json"
    rm -f "$dir/Helpers/config.json.bak"
    echo "total_sessions set to $sessions"

    # --- 5. Permissions ---
    chmod +x "$dir/attendance_checker.py"
    chmod 600 "$dir/Helpers/config.json"
    echo "Permissions set:"
    ls -l "$dir/attendance_checker.py" "$dir/Helpers/config.json"

    # --- 6. Optional: update the alert thresholds ---
    read -r -p "Update the attendance alert thresholds? (y/n): " update
    if [ "$update" = "y" ] || [ "$update" = "Y" ]; then
        read -r -p "Warning threshold [75]: " warn
        warn=${warn:-75}
        read -r -p "Failure threshold [50]: " fail
        fail=${fail:-50}

        # Check the input BEFORE touching the file
        if ! [[ "$warn" =~ ^[0-9]+$ ]] || ! [[ "$fail" =~ ^[0-9]+$ ]]; then
            echo "Both values must be whole numbers. Thresholds unchanged."
        elif [ "$warn" -gt 100 ] || [ "$fail" -ge "$warn" ]; then
            echo "Warning must be 100 or less and failure lower than warning. Thresholds unchanged."
        else
            # Only the two threshold lines are edited
            sed -i.bak "s/\"warning\": [0-9]*/\"warning\": $warn/" "$dir/Helpers/config.json"
            sed -i.bak "s/\"failure\": [0-9]*/\"failure\": $fail/" "$dir/Helpers/config.json"
            rm -f "$dir/Helpers/config.json.bak"
            echo "Thresholds updated: warning=$warn, failure=$fail"
        fi
    fi

    # Deployment is finished, so the interrupt trap is switched off.
    trap - INT TSTP
    PROJECT_DIR=""
    echo "Deployment complete."

    # --- 7. Verify by running the application ---
    echo "Verifying the deployment by starting the application..."
    run_project "$name"
}

# ----------------------------------------------------------------------------
# Feature 2: run
# ----------------------------------------------------------------------------
run_project() {
    name="$1"
    if [ -z "$name" ]; then
        read -r -p "Project name: " name
    fi
    dir="attendance_tracker_$name"

    if [ ! -f "$dir/attendance_checker.py" ]; then
        echo "Error: no deployed project found at $dir. Deploy it first."
        return 1
    fi

    # The app uses relative paths, so it must run from the project folder.
    # The parentheses run it in a subshell so our own folder does not change.
    ( cd "$dir" && python3 attendance_checker.py )
}

# ----------------------------------------------------------------------------
# Feature 3: archive the logs
# ----------------------------------------------------------------------------
archive_logs() {
    echo "=== Archive log files ==="
    name="$1"
    if [ -z "$name" ]; then
        read -r -p "Project name: " name
    fi
    dir="attendance_tracker_$name"

    if [ ! -d "$dir" ]; then
        echo "Error: $dir does not exist."
        return 1
    fi

    mkdir -p "$dir/archives/attendance" "$dir/archives/absent"
    stamp=$(date +%Y%m%d_%H%M%S)
    archived=0

    for kind in attendance absent; do
        if [ -f "$dir/reports/$kind.log" ]; then
            target="$dir/archives/$kind/${kind}_${stamp}.log"
            mv "$dir/reports/$kind.log" "$target"
            echo "Archived $kind.log -> $target"
            archived=$((archived + 1))
        else
            echo "No $kind.log found, skipping."
        fi
    done

    if [ "$archived" -eq 0 ]; then
        echo "Nothing was archived. Run the application first."
    fi
}

# ----------------------------------------------------------------------------
# Menu and command-line options
# ----------------------------------------------------------------------------
show_menu() {
    while true; do
        echo
        echo "===== Attendance Tracker Deploy Agent ====="
        echo "1) Deploy the application"
        echo "2) Run the application"
        echo "3) Archive the log files"
        echo "4) Quit"
        read -r -p "Choose an option: " choice

        case "$choice" in
            1) deploy_project ;;
            2) run_project "" ;;
            3) archive_logs "" ;;
            4) echo "Goodbye."; exit 0 ;;
            *) echo "Invalid option." ;;
        esac
    done
}

case "$1" in
    "")        show_menu ;;
    --deploy)  deploy_project ;;
    --run)     run_project "$2" ;;
    --archive) archive_logs "$2" ;;
    *)         echo "Usage: $0 [--deploy | --run [name] | --archive [name]]"; exit 1 ;;
esac
