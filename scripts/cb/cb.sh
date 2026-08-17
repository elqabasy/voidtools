#!/bin/bash
#
# cb — Copy text, file contents, or piped input to the clipboard
#       with safe limits, cross-platform backends, and professional logging.

set -o pipefail

# ========= Locate library =========
CB_SCRIPT_DIR="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
# shellcheck source=lib/clipboard.sh
source "${CB_SCRIPT_DIR}/lib/clipboard.sh"

# ========= Colors (tput adaptive) =========
if tput setaf 1 >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    MAGENTA=$(tput setaf 5)
    CYAN=$(tput setaf 6)
    RESET=$(tput sgr0)
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    MAGENTA=""
    CYAN=""
    RESET=""
fi

# ========= Logging =========
log()   { echo "$*" 1>&2; }
info()  { log "${CYAN}[+]${RESET} $*"; }
warn()  { log "${YELLOW}[!]${RESET} $*"; }
err()   { log "${RED}[-]${RESET} $*"; exit 1; }
dbg()   { $VERBOSE && log "${MAGENTA}[*]${RESET} $*"; }

# ========= Defaults =========
CONFIG_SYSTEM="/etc/cbrc"
CONFIG_USER="$HOME/.cbrc"

MODE="clipboard"
DIR=false
RECURSIVE=false
INCLUDE_DIRS=false
MAX_SIZE="1MB"
EXCLUDES=("*.log" "*.tmp" "*.bak" "node_modules/" "build/" "dist/" "__pycache__/")

VERBOSE=false
DRY_RUN=false
BACKEND="auto"
SHOW_BACKEND=false

# ========= Helpers =========
parse_size() {
    local size="$1" num unit
    num=$(echo "$size" | grep -Eo '^[0-9]+')
    unit=$(echo "$size" | grep -Eo '[A-Za-z]+$' | tr '[:upper:]' '[:lower:]')
    case "$unit" in
        kb) echo $((num * 1024));;
        mb) echo $((num * 1024 * 1024));;
        gb) echo $((num * 1024 * 1024 * 1024));;
        "" ) echo "$num";;
        * ) err "Invalid size unit: $unit";;
    esac
}

human_size() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        printf "%.2f GB" "$((bytes * 100 / 1073741824))e-2"
    elif (( bytes >= 1048576 )); then
        printf "%.2f MB" "$((bytes * 100 / 1048576))e-2"
    elif (( bytes >= 1024 )); then
        printf "%.2f KB" "$((bytes * 100 / 1024))e-2"
    else
        printf "%d B" "$bytes"
    fi
}

load_config() {
    [[ -f "$CONFIG_SYSTEM" ]] && source "$CONFIG_SYSTEM"
    [[ -f "$CONFIG_USER" ]] && source "$CONFIG_USER"
    if [[ ! -f "$CONFIG_USER" ]]; then
        cat > "$CONFIG_USER" <<EOF
# ~/.cbrc — User defaults for cb
MODE=$MODE
DIR=$DIR
RECURSIVE=$RECURSIVE
INCLUDE_DIRS=$INCLUDE_DIRS
MAX_SIZE=$MAX_SIZE
BACKEND=$BACKEND
EOF
    fi
}

show_help() {
cat <<EOF
Usage:
  cb [options] [files... | text...]

${CYAN}Description:${RESET}
  Copy file contents, text arguments, or piped input to the clipboard.
  Automatically selects a clipboard backend (pbcopy, wl-copy, xsel, xclip,
  or OSC 52 over SSH/headless terminals).

${CYAN}Options:${RESET}
  ${YELLOW}-d, --dir${RESET}           Copy contents of files in given directories (non-recursive by default)
  ${YELLOW}-r, --recursive${RESET}     Recursively include files in subdirectories
  ${YELLOW}-i, --include-dirs${RESET}  Include directory names as plain text
  ${YELLOW}--max-size=N${RESET}        Maximum total size (e.g. 500KB, 2MB, 1GB). Default: ${GREEN}1MB${RESET}
  ${YELLOW}--backend=NAME${RESET}      Clipboard backend: auto, pbcopy, wl-copy, xsel, xclip, osc52 (default: auto)
  ${YELLOW}--show-backend${RESET}        Print the resolved clipboard backend and exit
  ${YELLOW}--dry-run${RESET}           Show what would be copied without modifying clipboard
  ${YELLOW}--show-config${RESET}       Display effective configuration
  ${YELLOW}-v, --verbose${RESET}       Enable debug messages
  ${YELLOW}-h, --help${RESET}          Show this help menu

${CYAN}Configuration:${RESET}
  Reads defaults from:
    - ${BLUE}/etc/cbrc${RESET}   (system-wide)
    - ${BLUE}~/.cbrc${RESET}     (user-specific, auto-created if missing)

${CYAN}Examples:${RESET}
  ${GREEN}cb "Hello World"${RESET}
    Copy plain text to clipboard.

  ${GREEN}cb file.txt${RESET}
    Copy contents of a file.

  ${GREEN}cb -d ./docs${RESET}
    Copy all top-level files inside ./docs.

  ${GREEN}cb -d -r ./src --max-size=5MB${RESET}
    Recursively copy files from ./src (up to 5 MB).

  ${GREEN}echo "test" | cb${RESET}
    Copy piped input.

  ${GREEN}cb --show-backend${RESET}
    Show which clipboard backend would be used.
EOF
}

CB_COLLECTED_PAYLOAD=""
CB_STDIN_BUFFER=""

read_exact_stream() {
    local stream=$1
    local tmp result line had_trailing_newline=0
    tmp=$(mktemp)
    cat "$stream" > "$tmp"

    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        CB_STDIN_BUFFER=""
        return 0
    fi

    if [[ $(tail -c 1 "$tmp" | wc -l | tr -d ' ') -eq 1 ]]; then
        had_trailing_newline=1
    fi

    result=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -n "$result" ]]; then
            result+=$'\n'
        fi
        result+="$line"
    done < "$tmp"

    if (( had_trailing_newline )); then
        result+=$'\n'
    fi

    rm -f "$tmp"
    CB_STDIN_BUFFER="$result"
}

read_stdin_exact() {
    read_exact_stream /dev/stdin
}

collect_input() {
    local arg f file output="" first=1

    collect_file() {
        local cf="$1"
        if [[ -f "$cf" ]]; then
            if (( first == 0 )); then
                output+=$'\n'
            fi
            read_exact_stream "$cf"
            output+="$CB_STDIN_BUFFER"
            first=0
        elif [[ -d "$cf" && "$INCLUDE_DIRS" == true ]]; then
            if (( first == 0 )); then
                output+=$'\n'
            fi
            output+="$cf"
            first=0
        fi
    }

    if [[ $# -gt 0 ]]; then
        for arg in "$@"; do
            if [[ -f "$arg" ]]; then
                collect_file "$arg"
            elif [[ -d "$arg" ]]; then
                if [[ "$DIR" == true ]]; then
                    if [[ "$RECURSIVE" == true ]]; then
                        while IFS= read -r -d '' file; do
                            collect_file "$file"
                        done < <(find "$arg" -type f -print0)
                    else
                        for f in "$arg"/*; do
                            [[ -e "$f" ]] && collect_file "$f"
                        done
                    fi
                elif [[ "$INCLUDE_DIRS" == true ]]; then
                    collect_file "$arg"
                fi
            else
                if (( first == 0 )); then
                    output+=$'\n'
                fi
                output+="$arg"
                first=0
            fi
        done
    fi

    if [[ ! -t 0 ]] && { [[ -p /dev/stdin ]] || [[ $# -eq 0 ]]; }; then
        local piped=""
        read_stdin_exact
        piped="$CB_STDIN_BUFFER"
        if [[ -n "$piped" ]]; then
            if (( first == 0 )); then
                output+=$'\n'
            fi
            output+="$piped"
        fi
    fi

    CB_COLLECTED_PAYLOAD="$output"
}

# ========= Main =========
main() {
    load_config

    local ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dir) DIR=true; shift;;
            -r|--recursive) RECURSIVE=true; shift;;
            -i|--include-dirs) INCLUDE_DIRS=true; shift;;
            --max-size=*) MAX_SIZE="${1#*=}"; shift;;
            --backend=*) BACKEND="${1#*=}"; shift;;
            --backend)
                if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
                    BACKEND="$2"
                    shift 2
                else
                    SHOW_BACKEND=true
                    shift
                fi
                ;;
            --show-backend) SHOW_BACKEND=true; shift;;
            --dry-run) DRY_RUN=true; shift;;
            --show-config)
                echo "MODE=$MODE"
                echo "DIR=$DIR"
                echo "RECURSIVE=$RECURSIVE"
                echo "INCLUDE_DIRS=$INCLUDE_DIRS"
                echo "MAX_SIZE=$MAX_SIZE"
                echo "BACKEND=$BACKEND"
                exit 0
                ;;
            -v|--verbose) VERBOSE=true; shift;;
            -h|--help) show_help; exit 0;;
            --) shift; while [[ $# -gt 0 ]]; do ARGS+=("$1"); shift; done; break;;
            *) ARGS+=("$1"); shift;;
        esac
    done

    if ! cb_validate_backend_name "$BACKEND"; then
        local valid_backends
        valid_backends="$(cb_list_valid_backends)"
        err "Invalid backend: $BACKEND (valid: $valid_backends)"
    fi

    if ! cb_detect_clipboard_backend "$BACKEND"; then
        if [[ "$SHOW_BACKEND" == true ]]; then
            if $VERBOSE; then
                cb_verbose_environment >&2
                log "${MAGENTA}[*]${RESET} Clipboard backend: none"
                log "${MAGENTA}[*]${RESET} Reason: ${CB_RESOLVED_REASON}"
            else
                printf '%s\n' "none"
            fi
            exit 1
        fi
        if [[ ${#ARGS[@]} -eq 0 && -t 0 ]]; then
            # Allow --show-backend / early diagnostics without input.
            cb_no_backend_message
            exit 1
        fi
    fi

    if [[ "$SHOW_BACKEND" == true ]]; then
        if $VERBOSE; then
            cb_verbose_environment >&2
            log "${MAGENTA}[*]${RESET} Clipboard backend: ${CB_RESOLVED_BACKEND}"
            log "${MAGENTA}[*]${RESET} Reason: ${CB_RESOLVED_REASON}"
        else
            printf '%s\n' "$CB_RESOLVED_BACKEND"
        fi
        exit 0
    fi

    collect_input "${ARGS[@]}"

    [[ -z "$CB_COLLECTED_PAYLOAD" ]] && err "Empty output. Nothing copied!"
    local payload="$CB_COLLECTED_PAYLOAD"

    local payload_size max_bytes
    payload_size="$(cb_payload_size "$payload")"
    max_bytes=$(parse_size "$MAX_SIZE")

    if (( max_bytes > 0 && payload_size > max_bytes )); then
        warn "Aborted: total size $(human_size "$payload_size") exceeds max allowed ($MAX_SIZE)."
        warn "Use --max-size=5MB to override, or --max-size=0 to disable safety."
        exit 1
    elif (( max_bytes == 0 )); then
        warn "Warning: safety limit disabled! Proceeding without size checks..."
    fi

    if $VERBOSE; then
        cb_verbose_environment >&2
        dbg "Selected clipboard backend: ${CB_RESOLVED_BACKEND}"
        dbg "Backend reason: ${CB_RESOLVED_REASON}"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would copy $(human_size "$payload_size")"
        dbg "Resolved backend: ${CB_RESOLVED_BACKEND}"
        exit 0
    fi

    if [[ "$CB_RESOLVED_BACKEND" == "$CB_BACKEND_NONE" ]]; then
        cb_no_backend_message
        exit 1
    fi

    if cb_copy_to_clipboard "$payload" "$CB_RESOLVED_BACKEND"; then
        info "Copied to clipboard! ($(human_size "$payload_size"))"
        exit 0
    fi

    if [[ "$CB_RESOLVED_BACKEND" == "$CB_BACKEND_OSC52" && -n "${CB_OSC52_ERROR:-}" ]]; then
        err "$CB_OSC52_ERROR"
    fi

    err "Failed to copy to clipboard using backend: ${CB_RESOLVED_BACKEND}"
}

main "$@"
