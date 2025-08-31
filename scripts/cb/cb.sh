#!/bin/bash
#
# cb.sh — Copy text, file contents, or piped input to clipboard
#         with safe limits, excludes, and professional logging.

# ========= Colors (tput adaptive) =========
if tput setaf 1 &>/dev/null; then
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
        printf "%.2f GB" "$((bytes*100/1073741824))e-2"
    elif (( bytes >= 1048576 )); then
        printf "%.2f MB" "$((bytes*100/1048576))e-2"
    elif (( bytes >= 1024 )); then
        printf "%.2f KB" "$((bytes*100/1024))e-2"
    else
        printf "%d B" "$bytes"
    fi
}

load_config() {
    [[ -f "$CONFIG_SYSTEM" ]] && source "$CONFIG_SYSTEM"
    [[ -f "$CONFIG_USER" ]] && source "$CONFIG_USER"
    if [[ ! -f "$CONFIG_USER" ]]; then
        cat > "$CONFIG_USER" <<EOF
# ~/.cbrc — User defaults for cb.sh
MODE=$MODE
DIR=$DIR
RECURSIVE=$RECURSIVE
INCLUDE_DIRS=$INCLUDE_DIRS
MAX_SIZE=$MAX_SIZE
EOF
    fi
}

show_help() {
cat <<EOF
Usage:
  cb [options] [files... | text...]

${CYAN}Description:${RESET}
  Copy file contents, text arguments, or piped input to the system clipboard.
  Supports configuration, excludes, size limits, and safe defaults.

${CYAN}Options:${RESET}
  ${YELLOW}-d, --dir${RESET}           Copy contents of files in given directories (non-recursive by default)
  ${YELLOW}-r, --recursive${RESET}     Recursively include files in subdirectories
  ${YELLOW}-i, --include-dirs${RESET}  Include directory names as plain text
  ${YELLOW}--max-size=N${RESET}        Maximum total size (e.g. 500KB, 2MB, 1GB). Default: ${GREEN}1MB${RESET}
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
EOF
}

# ========= Main =========
main() {
    command -v xsel >/dev/null 2>&1 || err "xsel is not installed. Run: sudo apt install -y xsel"

    load_config

    ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dir) DIR=true; shift;;
            -r|--recursive) RECURSIVE=true; shift;;
            -i|--include-dirs) INCLUDE_DIRS=true; shift;;
            --max-size=*) MAX_SIZE="${1#*=}"; shift;;
            --dry-run) DRY_RUN=true; shift;;
            --show-config) echo "MODE=$MODE"; echo "DIR=$DIR"; echo "RECURSIVE=$RECURSIVE"; echo "INCLUDE_DIRS=$INCLUDE_DIRS"; echo "MAX_SIZE=$MAX_SIZE"; exit 0;;
            -v|--verbose) VERBOSE=true; shift;;
            -h|--help) show_help; exit 0;;
            *) ARGS+=("$1"); shift;;
        esac
    done

    local output=""
    local total_size=0
    local max_bytes
    max_bytes=$(parse_size "$MAX_SIZE")

    collect_file() {
        local f="$1"
        local size
        if [[ -f "$f" ]]; then
            size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
            (( total_size += size ))
            output+=$(cat "$f")
            output+=$'\n'
        elif [[ -d "$f" && "$INCLUDE_DIRS" == true ]]; then
            output+="$f"$'\n'
        fi
    }

    if [[ ${#ARGS[@]} -gt 0 ]]; then
        for arg in "${ARGS[@]}"; do
            if [[ -f "$arg" ]]; then
                collect_file "$arg"
            elif [[ -d "$arg" ]]; then
                if [[ "$DIR" == true ]]; then
                    if [[ "$RECURSIVE" == true ]]; then
                        while IFS= read -r -d '' file; do collect_file "$file"; done < <(find "$arg" -type f -print0)
                    else
                        for f in "$arg"/*; do [[ -e "$f" ]] && collect_file "$f"; done
                    fi
                elif [[ "$INCLUDE_DIRS" == true ]]; then
                    collect_file "$arg"
                fi
            else
                output+="$arg"$'\n'
            fi
        done
    fi

    if [ ! -t 0 ]; then
        piped=$(cat)
        [[ -n "$piped" ]] && output+="$piped"$'\n'
    fi

    [[ -z "$output" ]] && err "Empty output. Nothing copied!"

    if (( max_bytes > 0 && total_size > max_bytes )); then
        warn "Aborted: total size $(human_size $total_size) exceeds max allowed ($MAX_SIZE)."
        warn "Use --max-size=5MB to override, or --max-size=0 to disable safety."
        exit 1
    elif (( max_bytes == 0 )); then
        warn "Warning: safety limit disabled! Proceeding without size checks..."
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would copy $(human_size $total_size)"
        exit 0
    fi

    echo -n "$output" | xsel --clipboard --input
    info "Copied to clipboard! (size: $(human_size $total_size))"
}

main "$@"
