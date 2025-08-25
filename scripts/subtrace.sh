#!/usr/bin/env bash
# subtrace v1.4.0 — Passive & Active Subdomain Enumeration (Streaming output + per-tool stats)
# License: MIT

set -o pipefail

# ===== Colors =====
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; MAGENTA="\e[35m"; CYAN="\e[36m"; RESET="\e[0m"

# ===== Defaults =====
MODE="passive"
VERBOSE=false
SHOW_BANNER=true
DOMAIN=""
OUTPUT=""
WORDLIST=""
RESOLVERS=""
KEEP_UNRESOLVED=false
LIST_TOOLS=false

# ===== Banner =====
banner() {
  $SHOW_BANNER || return 0
  echo -e "${BLUE}
   ███████╗██╗   ██╗██████╗ ████████╗██████╗  █████╗  ██████╗███████╗
   ██╔════╝██║   ██║██╔══██╗╚══██╔══╝██╔══██╗██╔══██╗██╔════╝██╔════╝
   ███████╗██║   ██║██████╔╝   ██║   ██████╔╝███████║██║     █████╗
   ╚════██║██║   ██║██╔═══╝    ██║   ██╔═══╝ ██╔══██║██║     ██╔══╝
   ███████║╚██████╔╝██║        ██║   ██║     ██║  ██║╚██████╗███████╗
   ╚══════╝ ╚═════╝ ╚═╝        ╚═╝   ╚═╝     ╚═╝  ╚═╝ ╚═════╝╚══════╝
               Passive & Active Subdomain Enumeration
${RESET}" 1>&2
}

# ===== Logging (stderr only) =====
log()   { echo -e "$*" 1>&2; }
info()  { log "${CYAN}[+]${RESET} $*"; }
warn()  { log "${YELLOW}[!]${RESET} $*"; }
err()   { log "${RED}[-]${RESET} $*"; }
dbg()   { $VERBOSE && log "${MAGENTA}[*]${RESET} $*"; }

# ===== Usage =====
usage() {
  cat 1>&2 <<EOF
Usage: subtrace -d <domain> [-o <file>] [--mode passive|active] [--wordlist <file>] [--resolvers <file>] [--keep-unresolved] [-v] [--no-banner] [--tools] [-h]

Required:
  -d, --domain <domain>       Target apex domain (e.g., example.com)

Options:
  --mode <passive|active>     Recon mode (default: passive)
  -o, --output <file>         Output file path (default: subtrace_<domain>.txt)
  --wordlist <file>           (Active) Wordlist for brute-force/permutations
  --resolvers <file>          (Active) Resolvers file for puredns/dnsx
  --keep-unresolved           Keep domains even if they don't resolve (active mode)
  -v, --verbose               Verbose progress (to stderr)
  --no-banner                 Disable banner
  --tools                     List supported integrations
  -h, --help                  Show this help

Output:
  • Always plain text, one domain per line.
  • Results are streamed to the output file in real-time.
  • Verbose mode shows a live counter of discovered domains + per-tool summary.
EOF
  exit 1
}

# ===== Parse Args =====
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain) DOMAIN="$2"; shift 2;;
    -o|--output) OUTPUT="$2"; shift 2;;
    --mode) MODE="$2"; shift 2;;
    --wordlist) WORDLIST="$2"; shift 2;;
    --resolvers) RESOLVERS="$2"; shift 2;;
    --keep-unresolved) KEEP_UNRESOLVED=true; shift;;
    -v|--verbose) VERBOSE=true; shift;;
    --no-banner) SHOW_BANNER=false; shift;;
    --tools) LIST_TOOLS=true; shift;;
    -h|--help) usage;;
    *) err "Unknown option: $1"; usage;;
  esac
done

[[ -z "$DOMAIN" ]] && { err "Domain is required."; usage; }
[[ -z "$OUTPUT" ]] && OUTPUT="subtrace_${DOMAIN}.txt"

# ===== Seen set & counter =====
COUNT=0
TMP_SEEN="$(mktemp -t subtrace.seen.XXXXXX)"
trap 'rm -f "$TMP_SEEN"' EXIT
: > "$OUTPUT"

handle_new_domain() {
    local d="$1"
    [[ -z "$d" ]] && return 1
    if ! grep -qxF "$d" "$TMP_SEEN" 2>/dev/null; then
        echo "$d" >> "$TMP_SEEN"
        echo "$d" >> "$OUTPUT"
        COUNT=$((COUNT+1))
        $VERBOSE && echo "[*] Found: $d (total: $COUNT)" 1>&2
        return 0  # new
    fi
    return 1  # duplicate
}

# ===== Validation =====
sanitize_domains() {
  awk '
    {
      gsub(/\r/,""); gsub(/\*\./,""); gsub(/\\\./,".");
      gsub(/^\.|\.$/,""); d=tolower($0);
      if (length(d) <= 253 && d ~ /^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)+$/)
        print d
    }'
}

# ===== Sources =====
src_assetfinder() {
  need_cmd assetfinder || return 0
  dbg "assetfinder…"
  local FOUND_THIS=0
  while read -r s; do handle_new_domain "$s" && FOUND_THIS=$((FOUND_THIS+1)); done < <(
    assetfinder --subs-only "$DOMAIN" 2>/dev/null | sanitize_domains
  )
  $VERBOSE && echo "[*] assetfinder finished — $FOUND_THIS new (total: $COUNT)" 1>&2
}
src_subfinder() {
  need_cmd subfinder || return 0
  dbg "subfinder…"
  local FOUND_THIS=0
  while read -r s; do handle_new_domain "$s" && FOUND_THIS=$((FOUND_THIS+1)); done < <(
    subfinder -silent -d "$DOMAIN" 2>/dev/null | sanitize_domains
  )
  $VERBOSE && echo "[*] subfinder finished — $FOUND_THIS new (total: $COUNT)" 1>&2
}
src_amass_passive() {
  need_cmd amass || return 0
  dbg "amass (passive)…"
  local FOUND_THIS=0
  while read -r s; do handle_new_domain "$s" && FOUND_THIS=$((FOUND_THIS+1)); done < <(
    amass enum -passive -d "$DOMAIN" 2>/dev/null | sanitize_domains
  )
  $VERBOSE && echo "[*] amass passive finished — $FOUND_THIS new (total: $COUNT)" 1>&2
}
src_crtsh() {
  need_cmd curl || return 0
  need_cmd jq || return 0
  dbg "crt.sh…"
  local FOUND_THIS=0
  while read -r s; do handle_new_domain "$s" && FOUND_THIS=$((FOUND_THIS+1)); done < <(
    curl -s "https://crt.sh/?q=%25.$DOMAIN&output=json" \
      | jq -r '.[].name_value' 2>/dev/null \
      | tr " " "\n" | sanitize_domains
  )
  $VERBOSE && echo "[*] crt.sh finished — $FOUND_THIS new (total: $COUNT)" 1>&2
}
src_waybackurls() {
  need_cmd waybackurls || return 0
  dbg "waybackurls…"
  local FOUND_THIS=0
  while read -r s; do handle_new_domain "$s" && FOUND_THIS=$((FOUND_THIS+1)); done < <(
    echo "$DOMAIN" | waybackurls 2>/dev/null | awk -F/ '{print $3}' | sanitize_domains
  )
  $VERBOSE && echo "[*] waybackurls finished — $FOUND_THIS new (total: $COUNT)" 1>&2
}
src_github_subdomains() {
  need_cmd github-subdomains || return 0
  dbg "github-subdomains…"
  local FOUND_THIS=0
  while read -r s; do handle_new_domain "$s" && FOUND_THIS=$((FOUND_THIS+1)); done < <(
    github-subdomains -d "$DOMAIN" 2>/dev/null | sanitize_domains
  )
  $VERBOSE && echo "[*] github-subdomains finished — $FOUND_THIS new (total: $COUNT)" 1>&2
}

run_passive() {
  src_assetfinder
  src_subfinder
  src_amass_passive
  src_crtsh
  src_waybackurls
  src_github_subdomains
}

# ===== Helpers =====
need_cmd() { command -v "$1" >/dev/null 2>&1; }

check_dependencies() {
  info "Checking dependencies..."
  for d in curl jq sort uniq grep awk sed; do
    need_cmd "$d" || warn "Missing: $d"
  done
}

# ===== Active mode =====
run_active() {
  run_passive  # include passive first
  if [[ -n "$WORDLIST" && -f "$WORDLIST" ]]; then
    dbg "Bruteforce candidates…"
    local FOUND_THIS=0
    while read -r s; do handle_new_domain "$s" && FOUND_THIS=$((FOUND_THIS+1)); done < <(
      awk -v d="$DOMAIN" '{print $0"."d}' "$WORDLIST" | sanitize_domains
    )
    $VERBOSE && echo "[*] brute-force finished — $FOUND_THIS new (total: $COUNT)" 1>&2
  fi
  if need_cmd dnsx; then
    dbg "Resolving with dnsx…"
    local FOUND_THIS=0
    while read -r s; do handle_new_domain "$s" && FOUND_THIS=$((FOUND_THIS+1)); done < <(
      dnsx -silent -l "$OUTPUT" 2>/dev/null | sanitize_domains
    )
    $VERBOSE && echo "[*] dnsx finished — $FOUND_THIS new (total: $COUNT)" 1>&2
  fi
}

# ===== Main =====
main() {
  banner
  check_dependencies
  info "Target: $DOMAIN"
  info "Mode:   $MODE"
  info "Output: $OUTPUT"

  if [[ "$MODE" == "passive" ]]; then
    run_passive
  elif [[ "$MODE" == "active" ]]; then
    run_active
  else
    err "Invalid mode: $MODE"
    exit 2
  fi

  # Final dedup
  sort -u "$OUTPUT" -o "$OUTPUT"
  info "Total unique subdomains: $COUNT"
  info "Saved: $OUTPUT"
}

main "$@"
