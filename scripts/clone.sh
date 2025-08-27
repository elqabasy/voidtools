#!/bin/bash
# ====================================================================
# Site Cloner & Discovery Tool - Authorized Pen-Testing Use Only
# Author: Red Team Learner
# ====================================================================

# =====================[ CONFIGURATION ]=============================
VERSION="1.0"
BANNER=$(cat << "EOF"

    █████ █╗██╗      ██████╗ ███╗   ██╗███████╗
    ██╔════╝██║     ██╔═══██╗████╗  ██║██╔════╝
    ██║     ██║     ██║   ██║██╔██╗ ██║█████╗  
    ██║     ██║     ██║   ██║██║╚██╗██║██╔══╝  
    ╚██████╗███████╗╚██████╔╝██║ ╚████║███████╗
    ╚═════╝╚══════╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝
          Site Cloner & Discovery Tool

EOF
)

# Default stealth parameters
STEALTH_MIN=2
STEALTH_MAX=6
USER_AGENTS=("Mozilla/5.0" "Chrome/112.0" "Safari/537.36" "Edge/111.0")

# Default directories
OUTPUT_DIR="./output"
MIRRORS_DIR="$OUTPUT_DIR/mirrors"
REPORTS_DIR="$OUTPUT_DIR/reports"

# Default modes
COLOR=true
VERBOSE=false
QUIET=false
RESUME=false
UPDATE=false
DRY_RUN=false
IGNORE_ROBOTS=false
CHECKPOINT_FILE=""
THREADS=1
MAX_SIZE=0  # Bytes, 0 = unlimited

# =====================[ LOGGING FUNCTIONS ]=========================
info()    { $QUIET || echo -e "\e[32m[INFO]\e[0m $1"; }
warn()    { echo -e "\e[33m[WARN]\e[0m $1"; }
error()   { echo -e "\e[31m[ERROR]\e[0m $1" >&2; }
debug()   { $VERBOSE && echo -e "\e[34m[DEBUG]\e[0m $1"; }
banner()  { echo -e "$BANNER\n"; }

# =====================[ UTILITY FUNCTIONS ]=========================
random_wait() {
    local min=$1
    local max=$2
    local sleep_time=$(awk -v min=$min -v max=$max 'BEGIN{srand(); print int(min+rand()*(max-min+1))}')
    debug "Sleeping for $sleep_time seconds (stealth)"
    sleep $sleep_time
}

random_user_agent() {
    echo "${USER_AGENTS[$RANDOM % ${#USER_AGENTS[@]}]}"
}

ensure_directories() {
    mkdir -p "$MIRRORS_DIR" "$REPORTS_DIR"
    info "Output directories created: $MIRRORS_DIR , $REPORTS_DIR"
}

validate_url() {
    if [[ ! "$1" =~ ^https?:// ]]; then
        error "Invalid URL: $1"
        exit 1
    fi
}

human_size() {
    local bytes=$1
    if ((bytes<1024)); then echo "${bytes}B"
    elif ((bytes<1048576)); then echo "$((bytes/1024))KB"
    elif ((bytes<1073741824)); then echo "$((bytes/1048576))MB"
    else echo "$((bytes/1073741824))GB"; fi
}

# =====================[ CLI ARGUMENT PARSING ]======================
usage() {
cat << EOF
Usage: $0 <URL> [options]

Options:
  -o, --output DIR       Output directory (default: ./output)
  -v                     Verbose output
  -q                     Quiet mode
  --no-color             Disable colored output
  --resume               Resume partial downloads
  --update               Delta sync/update
  --threads=N            Parallel downloads (default: 1)
  --max-size=SIZE        Max download size (B, KB, MB, GB, TB)
  --include=PATTERN      Include filter regex
  --exclude=PATTERN      Exclude filter regex
  --log-urls             Save URL list
  --dry-run              Show planned actions only
  --ignore-robots        Ignore robots.txt (requires confirmation)
  --checkpoint=FILE      Save checkpoint
  --restore=FILE         Restore checkpoint
  --config=FILE          Load config file
  -h, --help             Show this help message

Examples:
  $0 https://example.com -o ./myclone
  $0 https://example.com --resume --max-size=50MB
EOF
}

parse_args() {
    POSITIONAL=()
    while [[ $# -gt 0 ]]; do
        case $1 in
            -o|--output) OUTPUT_DIR="$2"; shift 2;;
            -v) VERBOSE=true; shift;;
            -q) QUIET=true; shift;;
            --no-color) COLOR=false; shift;;
            --resume) RESUME=true; shift;;
            --update) UPDATE=true; shift;;
            --threads=*) THREADS="${1#*=}"; shift;;
            --max-size=*) MAX_SIZE="${1#*=}"; shift;;
            --include=*) INCLUDE_FILTER="${1#*=}"; shift;;
            --exclude=*) EXCLUDE_FILTER="${1#*=}"; shift;;
            --log-urls) LOG_URLS=true; shift;;
            --dry-run) DRY_RUN=true; shift;;
            --ignore-robots) IGNORE_ROBOTS=true; shift;;
            --checkpoint=*) CHECKPOINT_FILE="${1#*=}"; shift;;
            --restore=*) RESTORE_FILE="${1#*=}"; shift;;
            --config=*) CONFIG_FILE="${1#*=}"; shift;;
            -h|--help) usage; exit 0;;
            *) POSITIONAL+=("$1"); shift;;
        esac
    done
    set -- "${POSITIONAL[@]}"
    URL="$1"
    if [[ -z "$URL" ]]; then
        error "URL is required"
        usage
        exit 1
    fi
}

# =====================[ SITE DISCOVERY & DOWNLOAD ]=================
discover_urls() {
    info "Starting URL discovery for $URL"
    # Placeholder: actual discovery logic here (wget/curl + parsing)
    URL_LIST=("$URL")
}

download_site() {
    info "Starting site download..."
    for url in "${URL_LIST[@]}"; do
        debug "Downloading $url"
        [[ $DRY_RUN == true ]] && echo "[DRY-RUN] Would download $url" && continue
        random_wait $STEALTH_MIN $STEALTH_MAX
        USER_AGENT=$(random_user_agent)
        debug "Using User-Agent: $USER_AGENT"
        # Example wget usage, real download logic would include recursion, max-size, resume, delta
        wget -q --recursive --no-parent --page-requisites --adjust-extension \
             --convert-links --restrict-file-names=windows --directory-prefix="$MIRRORS_DIR" \
             --user-agent="$USER_AGENT" "$url"
    done
}

# =====================[ ANALYSIS & REPORTS ]========================
analyze_site() {
    info "Analyzing downloaded site..."
    # Placeholder: file type breakdown, keyword detection, largest file
}

save_reports() {
    info "Saving reports..."
    # Placeholder: save TXT/JSON/CSV/SQLite
}

# =====================[ MAIN EXECUTION ]===========================
main() {
    banner
    parse_args "$@"
    validate_url "$URL"
    ensure_directories
    discover_urls
    download_site
    analyze_site
    save_reports
    info "Site cloning & discovery completed!"
}

# Graceful exit
trap 'info "Ctrl+C detected, saving checkpoint..."; exit 1' SIGINT

main "$@"
