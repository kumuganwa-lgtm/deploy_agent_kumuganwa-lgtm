# deploy_agent

A shell script that deploys, runs and archives logs for the Student Attendance Tracker, with clean Ctrl+C / Ctrl+Z handling during deployment.

## Repository layout

```
deploy_agent_<GithubUsername>/
├── deploy_agent.sh
├── README.md
└── templates/
    ├── attendance_checker.py   (unmodified)
    ├── assets.csv              (unmodified)
    └── config.json             (unmodified)
```

## How to run

Requires `bash`, `python3` and `zip`.

```bash
chmod +x deploy_agent.sh
./deploy_agent.sh              # interactive menu (1 Deploy, 2 Run, 3 Archive, 4 Quit)
./deploy_agent.sh --deploy     # or use flags to pick a feature directly
./deploy_agent.sh --run [name]
./deploy_agent.sh --archive [name]
```

I chose **both** an interactive menu (no arguments) and command-line flags. `name` is the part after `attendance_tracker_` (e.g. `v1`); if omitted, the script asks.

## Feature 1: Deploy

1. **Pre-flight**: checks `python3` and `zip` exist (prints `python3 --version`) and that the three templates are present. Exits early with a clear message otherwise.
2. **Name**: asks for a name and creates `attendance_tracker_<name>/` with `Helpers/` and `reports/`. Names are validated (letters, digits, `_`, `-`). If the directory exists, you are asked whether to overwrite; answering no aborts without touching it.
3. **Files**: `attendance_checker.py` and `config.json` are copied unmodified. The roster `Helpers/assets.csv` is built via:
   - **Option A**: copy N students (plus header) from `templates/assets.csv`.
   - **Option B**: generate N students from name arrays in the script, with counts at 0.
4. **Consistency**: Option A rows carry 4 prior sessions, so `total_sessions` stays `5`. Option B starts fresh, so the script sets `total_sessions` to `1` with `sed`. Rule: `total_sessions = prior sessions + 1`.
5. **Permissions**: `chmod +x attendance_checker.py`, `chmod 600 Helpers/config.json`, and the resulting permissions are printed.
6. **Thresholds**: asked whether to update. Warning (default 75) and failure (default 50) are read; empty input uses the default. Input must be a whole number from 0 to 100, and failure must be lower than warning, otherwise it re-prompts. Only the `"warning": N` and `"failure": N` lines are changed using `sed`, so formatting and order are preserved.
7. **Verify**: the deploy ends by launching the app (Feature 2).

## Feature 2: Run

`cd attendance_tracker_<name> && python3 attendance_checker.py`. The terminal is handed to the instructor to mark students.

## Feature 3: Archive

For each of `reports/attendance.log` and `reports/absent.log` that exists, the file is moved to:

```
attendance_tracker_<name>/archives/attendance/attendance_YYYYMMDD_HHMMSS.log
attendance_tracker_<name>/archives/absent/absent_YYYYMMDD_HHMMSS.log
```

Both files from one run share a timestamp. A missing log (e.g. nobody absent) is reported and skipped, not an error. The final paths are printed.

## Signal handling (Ctrl+C / Ctrl+Z)

From the moment the project directory is created until deployment completes, `SIGINT` and `SIGTSTP` are trapped. On either signal the script:

1. prints that deployment was interrupted,
2. zips whatever exists into `attendance_tracker_<name>_archive.zip`,
3. deletes the incomplete `attendance_tracker_<name>/` directory,
4. exits with code 130.

The trap is removed once deployment finishes, so it does not affect the marking session.

**To test:** run `./deploy_agent.sh --deploy`, enter a name, and press Ctrl+C (or Ctrl+Z) at the roster prompt. Then run `unzip -l attendance_tracker_<name>_archive.zip`. The zip contains the partial project (`attendance_checker.py`, `Helpers/config.json`, the empty `reports/`, plus whatever else was created before the interrupt).

## How I tested

- Deploy with Option A and Option B; inspected `Helpers/assets.csv` and `total_sessions` (5 vs 1).
- Checked `ls -l`: `-rwxr-xr-x` on the script, `-rw-------` on `config.json`.
- Threshold update with valid, empty and non-numeric input; confirmed `config.json` formatting unchanged.
- Re-deploy over an existing name (overwrite and abort paths).
- Ran a marking session, then archived: both logs, and the one-log-missing case.
- Sent SIGINT and SIGTSTP mid-deploy: zip created, directory removed, exit code 130.
