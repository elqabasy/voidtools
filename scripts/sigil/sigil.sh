#!/bin/bash

# ========= Configuration =========
set -euo pipefail
VERSION="1.0.0"
SHOW_BANNER=true
VERBOSE=false
FORCE=false
OUT_FILE=""

# ========= Colors =========
RESET="\e[0m"
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"

# ========= Signatures =========
declare -A SIGNATURES
SIGNATURES=(
    [png]=$'\x89PNG\r\n\x1a\n'
    [jpg]=$'\xff\xd8\xff'
    [gif]=$'GIF89a'
    [pdf]=$'%PDF-'
    [zip]=$'PK\x03\x04'
    [exe]=$'MZ'
    [elf]=$'\x7fELF'
    [rar]=$'Rar!\x1a\x07\x00'
    [7z]=$'7z\xBC\xAF\x27\x1C'
    [mp3]=$'\xFF\xFB'
    [doc]=$'\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1'
    [xlsx]=$'PK\x03\x04\x14\x00\x06\x00'
    [mp4]=$'\x00\x00\x00\x18ftypmp42'
    [avi]=$'RIFF....AVI '
    [bmp]=$'BM'
    [wav]=$'RIFF....WAVE'
    [tar]=$'ustar'
    [gz]=$'\x1f\x8b\x08'
    [bz2]=$'BZh'
    [xml]=$'<?xml'
    [html]=$'<!DOCTYPE html'
)

# ========= Banner =========
banner() {
  $SHOW_BANNER || return 0
  echo -e "${BLUE}
  ███████╗██╗ ██████╗ ██╗██╗     
  ██╔════╝██║██╔════╝ ██║██║     
  ███████╗██║██║  ███╗██║██║     
  ╚════██║██║██║   ██║██║██║     
  ███████║██║╚██████╔╝██║███████╗
  ╚══════╝╚═╝ ╚═════╝ ╚═╝╚══════╝
    Flexible File Signature Tool
${RESET}" 1>&2
}

# ========= Logging =========
log()   { echo -e "$*" 1>&2; }
info()  { log "${CYAN}[+]${RESET} $*"; }
warn()  { log "${YELLOW}[!]${RESET} $*"; }
err()   { log "${RED}[-]${RESET} $*"; exit 1; }
dbg()   { $VERBOSE && log "${MAGENTA}[*]${RESET} $*"; }

# ========= Utility =========
normalize() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

detect_signature_type() {
    local file="$1"
    local head_hex
    head_hex=$(head -c 12 "$file" | xxd -p)
    for key in "${!SIGNATURES[@]}"; do
        local sig_hex
        sig_hex=$(echo -ne "${SIGNATURES[$key]}" | xxd -p)
        if [[ "$head_hex" == "$sig_hex"* ]]; then
            echo "$key"
            return
        fi
    done
    echo ""
}

# ========= Core Actions =========

get_sig() {
    local type
    type=$(normalize "$1")
    [[ -z "${SIGNATURES[$type]:-}" ]] && err "Unknown type: $type"
    echo -ne "${SIGNATURES[$type]}"
    dbg "Output signature for $type"
}

prepend_sig() {
    local type file
    type=$(normalize "$1"); file="$2"
    [[ ! -f "$file" ]] && err "File not found: $file"
    [[ -z "${SIGNATURES[$type]:-}" ]] && err "Unknown type: $type"

    [[ -z "$OUT_FILE" ]] && OUT_FILE="sigil_prepended_$(basename "$file")"
    [[ -f "$OUT_FILE" && "$FORCE" = false ]] && err "Output file exists: $OUT_FILE (use --force)"

    { echo -ne "${SIGNATURES[$type]}"; cat "$file"; } > "$OUT_FILE"
    info "Prepended $type to $file -> $OUT_FILE"
}

remove_sig() {
    local type file
    if [[ $# -eq 1 ]]; then
        file="$1"
        type=$(detect_signature_type "$file")
        [[ -z "$type" ]] && err "No known signature detected in $file"
    elif [[ $# -eq 2 ]]; then
        type=$(normalize "$1"); file="$2"
    else
        err "Invalid usage for --remove"
    fi

    [[ ! -f "$file" ]] && err "File not found: $file"
    [[ -z "${SIGNATURES[$type]:-}" ]] && err "Unknown type: $type"

    local sig_len
    sig_len=$(echo -ne "${SIGNATURES[$type]}" | wc -c)
    local file_head
    file_head=$(head -c "$sig_len" "$file")
    [[ "$file_head" != "$(echo -ne "${SIGNATURES[$type]}")" ]] && err "File does not start with $type signature"

    [[ -z "$OUT_FILE" ]] && OUT_FILE="sigil_removed_$(basename "$file")"
    [[ -f "$OUT_FILE" && "$FORCE" = false ]] && err "Output file exists: $OUT_FILE"

    tail -c +$((sig_len + 1)) "$file" > "$OUT_FILE"
    info "Removed $type signature from $file -> $OUT_FILE"
}

replace_sig() {
    local old_type new_type file
    if [[ $# -eq 2 ]]; then
        new_type=$(normalize "$1"); file="$2"
        old_type=$(detect_signature_type "$file")
        [[ -z "$old_type" ]] && err "No detectable signature in $file"
    elif [[ $# -eq 3 ]]; then
        old_type=$(normalize "$1"); new_type=$(normalize "$2"); file="$3"
    else
        err "Invalid usage for --replace"
    fi

    [[ -z "${SIGNATURES[$old_type]:-}" ]] && err "Unknown old type: $old_type"
    [[ -z "${SIGNATURES[$new_type]:-}" ]] && err "Unknown new type: $new_type"
    [[ ! -f "$file" ]] && err "File not found: $file"

    local old_len
    old_len=$(echo -ne "${SIGNATURES[$old_type]}" | wc -c)
    local file_head
    file_head=$(head -c "$old_len" "$file")
    [[ "$file_head" != "$(echo -ne "${SIGNATURES[$old_type]}")" ]] && err "File does not start with $old_type signature"

    [[ -z "$OUT_FILE" ]] && OUT_FILE="sigil_replaced_$(basename "$file")"
    [[ -f "$OUT_FILE" && "$FORCE" = false ]] && err "Output file exists: $OUT_FILE"

    { echo -ne "${SIGNATURES[$new_type]}"; tail -c +$((old_len + 1)) "$file"; } > "$OUT_FILE"
    info "Replaced $old_type with $new_type in $file -> $OUT_FILE"
}

check_sig() {
    local file="$1"
    [[ ! -f "$file" ]] && err "File not found: $file"
    local detected
    detected=$(detect_signature_type "$file")
    if [[ -n "$detected" ]]; then
        info "$file matches signature: $detected"
    else
        warn "$file: No known signature detected"
    fi
}

list_types() {
    echo "Supported file types:"
    for key in "${!SIGNATURES[@]}"; do
        local hexval
        hexval=$(echo -ne "${SIGNATURES[$key]}" | xxd -p)
        printf "  %-10s : %s\n" "$key" "$hexval"
    done
}

help_menu() {
    banner
    cat <<EOF
Usage: sigil.sh [options]

Actions:
  --get <type>                    Output raw signature
  --prepend <type> <file>         Prepend signature to file
  --remove [<type>] <file>        Remove signature (detected or by type)
  --replace [<old>] <new> <file>  Replace existing signature
  --check <file>                  Detect file signature
  --list                          List supported signature types

Options:
  --output, -o <file>             Set output file
  --force                         Overwrite output file if exists
  -v                              Enable verbose output
  --banner                       
  --banner                        Show banner and exit
  --version                       Show version and exit
  --help                          Show this help message

Example usage:
  ./sigil.sh --get png
  ./sigil.sh --prepend png input.txt -o output.png
  ./sigil.sh --remove input.png
  ./sigil.sh --replace png jpg input.png -o out.jpg
  ./sigil.sh --check suspicious.file
  ./sigil.sh --list

Author: Mahros AL-Qabasy <mahros.elqabasy@hotmail.com>
Project: https://github.com/elqabasy/voidtools
EOF
    exit 0
}

# ========= Argument Parsing =========

CMD=""
ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --get)        shift; CMD="get"; ARGS=("$1");;
        --prepend)    shift; CMD="prepend"; ARGS=("$1" "$2"); shift;;
        --remove)
            shift; CMD="remove"
            if [[ $# -eq 1 ]]; then
                ARGS=("$1")
            else
                ARGS=("$1" "$2"); shift
            fi
            ;;
        --replace)
            shift; CMD="replace"
            if [[ $# -eq 2 ]]; then
                ARGS=("$1" "$2")
            else
                ARGS=("$1" "$2" "$3"); shift 2
            fi
            ;;
        --check)      shift; CMD="check"; ARGS=("$1");;
        --list)       CMD="list";;
        --help)       help_menu;;
        --banner)     banner; exit 0;;
        --version)    echo "$VERSION"; exit 0;;
        --output|-o)  shift; OUT_FILE="$1";;
        --force)      FORCE=true;;
        -v)           VERBOSE=true;;
        *) err "Unknown option or argument: $1";;
    esac
    shift
done

# ========= Run Command =========

case "$CMD" in
    get)      get_sig "${ARGS[0]}";;
    prepend)  prepend_sig "${ARGS[0]}" "${ARGS[1]}";;
    remove)   remove_sig "${ARGS[@]}";;
    replace)  replace_sig "${ARGS[@]}";;
    check)    check_sig "${ARGS[0]}";;
    list)     list_types;;
    "")       help_menu;;
    *)        err "Invalid or unknown command";;
esac
