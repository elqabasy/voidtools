#!/bin/bash

set -o pipefail

# ===== Colors =====
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; MAGENTA="\e[35m"; CYAN="\e[36m"; RESET="\e[0m"


# ===== Banner =====
banner() {
  $SHOW_BANNER || return 0
  echo -e "${BLUE}
    ██╗     ██╗██╗   ██╗███████╗██████╗ ███╗   ██╗███████╗
    ██║     ██║██║   ██║██╔════╝██╔══██╗████╗  ██║██╔════╝
    ██║     ██║██║   ██║█████╗  ██║  ██║██╔██╗ ██║███████╗
    ██║     ██║╚██╗ ██╔╝██╔══╝  ██║  ██║██║╚██╗██║╚════██║
    ███████╗██║ ╚████╔╝ ███████╗██████╔╝██║ ╚████║███████║
    ╚══════╝╚═╝  ╚═══╝  ╚══════╝╚═════╝ ╚═╝  ╚═══╝╚══════╝
               Passive & Active Domain Checker
${RESET}" 1>&2
}

banner


# ===== Logging (stderr only) =====
log()   { echo -e "$*" 1>&2; }
info()  { log "${CYAN}[+]${RESET} $*"; }
warn()  { log "${YELLOW}[!]${RESET} $*"; }
err()   { log "${RED}[-]${RESET} $*"; }
dbg()   { $VERBOSE && log "${MAGENTA}[*]${RESET} $*"; }


show_help() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -h, --help            Show this help message"
  echo "  -d, --domains FILE    Path to domains file"
  echo "  -o, --output FILE     Path to output file"
  echo "  -p, --parallelism N   Number of parallel processes (default: 1)"
}

# Default values
parallelism=1

# Parse parameters
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    -d|--domains)
      DOMAINS="$2"
      shift 2
      ;;
    -o|--output)
      OUTPUT="$2"
      shift 2
      ;;
    -p|--parallelism)
      parallelism="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done


[[ -z "$DOMAINS" ]] && { err "Domains are required."; usage; }
[[ -z "$OUTPUT" ]] && { err "Output file is required."; usage; }




# LOG
info "Starting DNS lookup for domains in $DOMAINS"


# if there is no output option specified, echo the results only.
if [[ -z "$OUTPUT" ]]; then
  cat "$DOMAINS" | xargs -I{} -P"$parallelism" sh -c 'ip=$(dig +short {}); [ -n "$ip" ] && echo {}'
else
  cat "$DOMAINS" | xargs -I{} -P"$parallelism" sh -c 'ip=$(dig +short {}); [ -n "$ip" ] && echo {}' > "$OUTPUT"
fi



# COMPLETION
info "DNS lookup completed. Results saved to $OUTPUT"
