#!/bin/bash
#
# fort — securely bootstrap, harden, audit, and verify Linux servers.
#
# Design invariant: Fort must never lock the administrator out of a remote
# server. Any step that could remove SSH/sudo access is gated behind
# programmatic verification. When a lockout cannot be ruled out, Fort aborts
# with exit code 5 and restores backups instead of proceeding.
#
# Target platforms: Debian / Ubuntu.
# License: distributed with the Fort source code.

set -euo pipefail

# ========= Metadata =========
VERSION="1.0.0"
PROG="fort"

# ========= Exit codes (see fort.1) =========
EX_OK=0            # success
EX_GENERAL=1       # general error / failed security check
EX_USAGE=2         # invalid command-line usage
EX_UNSUPPORTED=3   # unsupported OS or environment
EX_VALIDATION=4    # security configuration validation failed
EX_LOCKOUT=5       # aborted to prevent possible administrator lockout

# ========= Colors =========
# Use $'...' so escapes work with both echo -e and plain cat/printf.
if [[ -t 2 ]]; then
    RESET=$'\e[0m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
    BLUE=$'\e[34m'; MAGENTA=$'\e[35m'; CYAN=$'\e[36m'; BOLD=$'\e[1m'
else
    RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; BOLD=""
fi

# ========= Defaults / configuration =========
SHOW_BANNER=true
VERBOSE=false
QUIET=false
DRY_RUN=false
ASSUME_YES=false

# harden inputs (env vars are read as defaults, CLI overrides below)
ADMIN_USER="${ADMIN_USER:-}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
CREATE_DEPLOY_USER=true
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
SSH_KEY_FILE=""
SSH_PORT="${SSH_PORT:-22}"

ALLOW_HTTP="${ALLOW_HTTP:-false}"
ALLOW_HTTPS="${ALLOW_HTTPS:-false}"
ALLOW_SSH_TCP_FORWARDING="${ALLOW_SSH_TCP_FORWARDING:-false}"
ALLOW_SSH_AGENT_FORWARDING="${ALLOW_SSH_AGENT_FORWARDING:-false}"

# runtime paths
BACKUP_ROOT="/var/backups/fort"
BACKUP_DIR=""            # populated per-run
STATE_DIR="/var/lib/fort"
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-fort.conf"
NFT_CONF="/etc/nftables.conf"
SYSCTL_CONF="/etc/sysctl.d/99-fort.conf"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/fort.local"

# OS facts (populated by detect_os)
OS_ID=""
OS_VERSION=""

# ========= Banner =========
banner() {
    $SHOW_BANNER || return 0
    $QUIET && return 0
    echo -e "${BLUE}${BOLD}
   ███████╗ ██████╗ ██████╗ ████████╗
   ██╔════╝██╔═══██╗██╔══██╗╚══██╔══╝
   █████╗  ██║   ██║██████╔╝   ██║
   ██╔══╝  ██║   ██║██╔══██╗   ██║
   ██║     ╚██████╔╝██║  ██║   ██║
   ╚═╝      ╚═════╝ ╚═╝  ╚═╝   ╚═╝
     Linux Server Hardening — lockout-safe
${RESET}" 1>&2
}

# ========= Logging =========
log()   { echo -e "$*" 1>&2; }
info()  { $QUIET || log "${CYAN}[+]${RESET} $*"; }
ok()    { $QUIET || log "${GREEN}[✓]${RESET} $*"; }
warn()  { log "${YELLOW}[!]${RESET} $*"; }
dbg()   { $VERBOSE && log "${MAGENTA}[*]${RESET} $*" || true; }

# err prints and exits with the given code (default: general error)
err() {
    local code="$EX_GENERAL"
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then code="$1"; shift; fi
    log "${RED}[-]${RESET} $*"
    exit "$code"
}

# lockout abort: the core safety exit
abort_lockout() {
    log "${RED}${BOLD}[LOCKOUT-ABORT]${RESET} $*"
    log "${RED}Refusing to continue because remote access could be lost.${RESET}"
    maybe_rollback
    exit "$EX_LOCKOUT"
}

# ========= Command execution wrapper (dry-run aware) =========
# Use `run` for every state-changing command so --dry-run is honored uniformly.
run() {
    if $DRY_RUN; then
        log "${YELLOW}[dry-run]${RESET} $*"
        return 0
    fi
    dbg "exec: $*"
    "$@"
}

# run a shell pipeline string (only when unavoidable); still dry-run aware
run_sh() {
    if $DRY_RUN; then
        log "${YELLOW}[dry-run]${RESET} sh -c: $*"
        return 0
    fi
    dbg "exec: sh -c: $*"
    bash -c "$*"
}

# ========= Helpers =========
require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        err "$EX_GENERAL" "This command must be run as root (try: sudo $PROG $*)."
    fi
}

normalize_bool() {
    case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|y|on) echo "true" ;;
        *) echo "false" ;;
    esac
}

have() { command -v "$1" >/dev/null 2>&1; }

fw_has_fort_table() { nft list table inet fort >/dev/null 2>&1; }

# Confirm the Fort input chain is deny-by-default. Prefer JSON — plain `nft
# list` formatting varies by version (named priorities, hook/policy on
# separate lines), which made the old single-line regex a false failure.
fw_input_policy_drop() {
    local json out
    if json="$(nft -j list chain inet fort input 2>/dev/null)"; then
        if echo "$json" | grep -Eq '"policy"[[:space:]]*:[[:space:]]*"drop"'; then
            return 0
        fi
        # JSON available but policy is not drop — treat as a real failure.
        return 1
    fi
    out="$(nft list chain inet fort input 2>/dev/null || true)"
    [[ -n "$out" ]] || return 1
    echo "$out" | grep -Eq 'hook[[:space:]]+input' || return 1
    echo "$out" | grep -Eq 'policy[[:space:]]+drop'
}

confirm() {
    # confirm PROMPT — returns 0 to proceed. Safety-critical steps do NOT use this.
    local prompt="$1"
    if $ASSUME_YES; then
        dbg "auto-confirm (--yes): $prompt"
        return 0
    fi
    if ! [[ -t 0 ]]; then
        warn "No TTY and --yes not given; declining: $prompt"
        return 1
    fi
    local reply
    read -r -p "$(echo -e "${YELLOW}[?]${RESET} $prompt [y/N] ")" reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

detect_os() {
    if [[ ! -r /etc/os-release ]]; then
        err "$EX_UNSUPPORTED" "Cannot read /etc/os-release; unsupported environment."
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    case "$OS_ID" in
        debian|ubuntu) dbg "Detected supported OS: $OS_ID $OS_VERSION" ;;
        *)
            if [[ "${ID_LIKE:-}" == *debian* ]]; then
                warn "OS '$OS_ID' is Debian-like but not officially supported; proceeding cautiously."
            else
                err "$EX_UNSUPPORTED" "Unsupported OS '$OS_ID'. Fort targets Debian/Ubuntu."
            fi
            ;;
    esac
}

new_backup_dir() {
    [[ -n "$BACKUP_DIR" ]] && return 0
    BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
    run install -d -m 0700 "$BACKUP_ROOT"
    run install -d -m 0700 "$BACKUP_DIR"
    run install -d -m 0700 "$STATE_DIR"
    dbg "Backup directory: $BACKUP_DIR"
}

# backup_file PATH — copy an existing file into the timestamped backup dir,
# preserving its relative path so rollback can restore it exactly.
backup_file() {
    local src="$1"
    [[ -e "$src" ]] || { dbg "no backup needed (missing): $src"; return 0; }
    new_backup_dir
    local dest="$BACKUP_DIR${src}"
    run install -d -m 0700 "$(dirname "$dest")"
    run cp -a "$src" "$dest"
    dbg "backed up $src -> $dest"
}

# Record the backup dir so a later `fort rollback` can find the latest one.
record_backup_manifest() {
    [[ -z "$BACKUP_DIR" ]] && return 0
    $DRY_RUN && return 0
    echo "$BACKUP_DIR" > "$STATE_DIR/last-backup"
}

maybe_rollback() {
    [[ -z "$BACKUP_DIR" ]] && return 0
    $DRY_RUN && return 0
    warn "Restoring configuration from backup: $BACKUP_DIR"
    restore_from_backup "$BACKUP_DIR" || warn "Automatic rollback encountered errors; inspect $BACKUP_DIR manually."
}

restore_from_backup() {
    local dir="$1"
    [[ -d "$dir" ]] || err "$EX_GENERAL" "Backup directory not found: $dir"
    # Files were stored under $dir + original absolute path.
    local f target
    while IFS= read -r -d '' f; do
        target="${f#$dir}"
        install -d -m 0755 "$(dirname "$target")"
        cp -a "$f" "$target"
        info "restored $target"
    done < <(find "$dir" -type f -print0)
    # Best-effort reloads after restore.
    if have sshd || have systemctl; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    fi
    if have nft && [[ -f /etc/nftables.conf ]]; then
        nft -f /etc/nftables.conf 2>/dev/null || true
    fi
}

# ========= Usage =========
usage() {
    cat 1>&2 <<EOF
${BOLD}$PROG${RESET} v$VERSION — securely bootstrap, harden, audit, and verify Linux servers

Usage:
  $PROG [global-options] <command> [command-options]

Commands:
  harden      Apply the Fort security baseline (lockout-safe).
  audit       Inspect configuration without modifying anything.
  verify      Verify expected Fort controls are active.
  status      Print a concise security-state summary.
  doctor      Diagnose Fort/OS prerequisites.
  rollback    Restore configuration from the most recent Fort backup.

Global options:
  -h, --help        Show this help.
  -V, --version     Show version.
  -v, --verbose     Verbose diagnostics.
  -q, --quiet       Suppress non-essential output.
      --dry-run     Show intended changes without applying them.
      --yes         Auto-accept non-critical prompts (never safety gates).

Harden options:
      --admin USER              Administrative account to retain SSH+sudo (required).
      --deploy-user USER        Extra sudo-capable deploy account (default: deploy).
      --no-deploy-user          Do not create/manage a deploy account.
      --ssh-key KEY             SSH public key string to install for admin/deploy.
      --ssh-key-file FILE       Read the SSH public key from FILE.
      --ssh-port PORT           SSH listening port (default: 22).
      --allow-http              Permit inbound TCP 80.
      --allow-https             Permit inbound TCP 443.
      --no-http                 Do not permit inbound HTTP (default).
      --no-https                Do not permit inbound HTTPS (default).
      --allow-ssh-forwarding    Permit SSH TCP forwarding.
      --allow-agent-forwarding  Permit SSH agent forwarding.

Examples:
  $PROG harden --admin mahros --ssh-key-file ~/.ssh/id_ed25519.pub
  $PROG harden --admin mahros --ssh-key-file key.pub --allow-http --allow-https
  $PROG audit
  $PROG verify
  $PROG harden --dry-run

Author: Mahros AL-Qabasy <mahros.elqabasy@hotmail.com>
Project: https://github.com/elqabasy/voidtools
EOF
}

# ========= Argument parsing =========
CMD=""
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)    usage; exit "$EX_OK" ;;
            -V|--version) echo "$VERSION"; exit "$EX_OK" ;;
            -v|--verbose) VERBOSE=true ;;
            -q|--quiet)   QUIET=true ;;
            --dry-run)    DRY_RUN=true ;;
            --yes)        ASSUME_YES=true ;;
            --no-banner)  SHOW_BANNER=false ;;

            --admin)             shift; ADMIN_USER="${1:-}" ;;
            --admin=*)           ADMIN_USER="${1#*=}" ;;
            --deploy-user)       shift; DEPLOY_USER="${1:-}"; CREATE_DEPLOY_USER=true ;;
            --deploy-user=*)     DEPLOY_USER="${1#*=}"; CREATE_DEPLOY_USER=true ;;
            --no-deploy-user)    CREATE_DEPLOY_USER=false ;;
            --ssh-key)           shift; SSH_PUBLIC_KEY="${1:-}" ;;
            --ssh-key=*)         SSH_PUBLIC_KEY="${1#*=}" ;;
            --ssh-key-file)      shift; SSH_KEY_FILE="${1:-}" ;;
            --ssh-key-file=*)    SSH_KEY_FILE="${1#*=}" ;;
            --ssh-port)          shift; SSH_PORT="${1:-}" ;;
            --ssh-port=*)        SSH_PORT="${1#*=}" ;;

            --allow-http)   ALLOW_HTTP=true ;;
            --no-http)      ALLOW_HTTP=false ;;
            --allow-https)  ALLOW_HTTPS=true ;;
            --no-https)     ALLOW_HTTPS=false ;;

            --allow-ssh-forwarding)   ALLOW_SSH_TCP_FORWARDING=true ;;
            --allow-agent-forwarding) ALLOW_SSH_AGENT_FORWARDING=true ;;

            harden|audit|verify|status|doctor|rollback)
                CMD="$1" ;;
            -* ) err "$EX_USAGE" "Unknown option: $1" ;;
            * )  err "$EX_USAGE" "Unexpected argument: $1" ;;
        esac
        shift
    done

    # Normalize env-provided booleans.
    ALLOW_HTTP="$(normalize_bool "$ALLOW_HTTP")"
    ALLOW_HTTPS="$(normalize_bool "$ALLOW_HTTPS")"
    ALLOW_SSH_TCP_FORWARDING="$(normalize_bool "$ALLOW_SSH_TCP_FORWARDING")"
    ALLOW_SSH_AGENT_FORWARDING="$(normalize_bool "$ALLOW_SSH_AGENT_FORWARDING")"
}

# ========= Input validation for harden =========
validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || err "$EX_USAGE" "Invalid SSH port: '$p'"
    (( p >= 1 && p <= 65535 )) || err "$EX_USAGE" "SSH port out of range: $p"
}

load_ssh_key() {
    if [[ -n "$SSH_KEY_FILE" ]]; then
        [[ -r "$SSH_KEY_FILE" ]] || err "$EX_USAGE" "SSH key file not readable: $SSH_KEY_FILE"
        SSH_PUBLIC_KEY="$(head -n1 "$SSH_KEY_FILE")"
    fi
    SSH_PUBLIC_KEY="$(echo "$SSH_PUBLIC_KEY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
}

validate_public_key() {
    [[ -n "$SSH_PUBLIC_KEY" ]] || return 1
    # Must look like an OpenSSH public key line.
    [[ "$SSH_PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp[0-9]+@openssh\.com)[[:space:]]+[A-Za-z0-9+/]+=* ]] || return 1
    # If ssh-keygen is available, do an authoritative parse.
    if have ssh-keygen && ! $DRY_RUN; then
        local tmp; tmp="$(mktemp)"
        printf '%s\n' "$SSH_PUBLIC_KEY" > "$tmp"
        if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
            rm -f "$tmp"; return 1
        fi
        rm -f "$tmp"
    fi
    return 0
}

validate_username() {
    local name="$1" label="$2"
    [[ "$name" =~ ^[a-z_][a-z0-9_-]*$ ]] || err "$EX_USAGE" "Invalid $label username: '$name'"
    [[ "$name" != "root" ]] || err "$EX_USAGE" "$label username cannot be 'root'."
}

ssh_allow_users() {
    # Space-separated AllowUsers list for sshd.
    local users=("$ADMIN_USER")
    if $CREATE_DEPLOY_USER && [[ -n "$DEPLOY_USER" && "$DEPLOY_USER" != "$ADMIN_USER" ]]; then
        users+=("$DEPLOY_USER")
    fi
    printf '%s' "${users[*]}"
}

validate_harden_inputs() {
    [[ -n "$ADMIN_USER" ]] || abort_lockout "No administrator specified. Pass --admin USER (or set ADMIN_USER)."
    validate_username "$ADMIN_USER" "admin"
    [[ "$ADMIN_USER" != "root" ]] || abort_lockout "--admin must be a non-root account; refusing to rely on root while disabling root login."

    if $CREATE_DEPLOY_USER; then
        [[ -n "$DEPLOY_USER" ]] || err "$EX_USAGE" "Deploy username is empty; pass --deploy-user NAME or --no-deploy-user."
        validate_username "$DEPLOY_USER" "deploy"
    fi

    validate_port "$SSH_PORT"
    load_ssh_key
    if ! validate_public_key; then
        abort_lockout "A valid administrator SSH public key is required (--ssh-key/--ssh-key-file). Without it, disabling password auth would lock you out."
    fi
    if $CREATE_DEPLOY_USER; then
        ok "Inputs validated: admin=$ADMIN_USER deploy=$DEPLOY_USER port=$SSH_PORT key=$(printf '%.20s…' "$SSH_PUBLIC_KEY")"
    else
        ok "Inputs validated: admin=$ADMIN_USER deploy=disabled port=$SSH_PORT key=$(printf '%.20s…' "$SSH_PUBLIC_KEY")"
    fi
}

# ========= User provisioning =========
sudo_group_name() {
    if getent group sudo >/dev/null 2>&1; then
        echo "sudo"
    else
        echo "wheel"
    fi
}

ensure_linux_user() {
    local user="$1" role="$2"
    if id "$user" >/dev/null 2>&1; then
        info "$role '$user' already exists."
    else
        info "Creating $role '$user'."
        run useradd -m -s /bin/bash "$user"
    fi
}

grant_sudo() {
    local user="$1" role="$2"
    local sudo_group
    sudo_group="$(sudo_group_name)"
    run usermod -aG "$sudo_group" "$user"
    info "Added '$user' ($role) to '$sudo_group' group."
}

install_ssh_key_for() {
    local user="$1"
    local home ssh_dir auth
    home="$(getent passwd "$user" | cut -d: -f6 || true)"
    # New accounts on Debian/Ubuntu get /home/<user>; fall back if getent is empty
    # (e.g. during --dry-run before the account is materialized).
    [[ -n "$home" ]] || home="/home/$user"
    ssh_dir="$home/.ssh"
    auth="$ssh_dir/authorized_keys"

    backup_file "$auth"
    run install -d -m 0700 -o "$user" -g "$user" "$ssh_dir"

    if $DRY_RUN; then
        log "${YELLOW}[dry-run]${RESET} append key to $auth (if absent)"
    else
        touch "$auth"
        if ! grep -qxF "$SSH_PUBLIC_KEY" "$auth" 2>/dev/null; then
            printf '%s\n' "$SSH_PUBLIC_KEY" >> "$auth"
            info "Installed SSH key for $user."
        else
            info "SSH key already present for $user."
        fi
        chown "$user:$user" "$auth"
        chmod 0600 "$auth"
    fi
}

user_has_sudo() {
    local user="$1"
    id -nG "$user" | tr ' ' '\n' | grep -qxE 'sudo|wheel'
}

# Does sudoers actually grant this user anything? Authoritative, unlike group
# membership alone, which says nothing about the effective sudoers policy.
sudo_grants_exist() {
    local user="$1"
    sudo -l -U "$user" >/dev/null 2>&1
}

sudo_is_nopasswd() {
    local user="$1"
    sudo -l -U "$user" 2>/dev/null | grep -q 'NOPASSWD:'
}

# P = usable password, L = locked, NP = no password at all.
password_status() {
    local user="$1" st
    st="$(passwd -S "$user" 2>/dev/null | awk '{print $2}' || true)"
    [[ -n "$st" ]] || st="UNKNOWN"
    printf '%s' "$st"
}

# sudo authenticates with the account password, so a locked or absent password
# means sudo can never succeed unless a NOPASSWD rule applies.
sudo_can_authenticate() {
    local user="$1"
    sudo_is_nopasswd "$user" && return 0
    [[ "$(password_status "$user")" == "P" ]]
}

# Set an account password interactively so sudo has something to authenticate
# against. SSH password auth stays disabled, so this does not widen remote login.
ensure_sudo_password() {
    local user="$1" role="$2"
    if $DRY_RUN; then
        log "${YELLOW}[dry-run]${RESET} ensure a sudo-usable password exists for $user"
        return 0
    fi
    if sudo_is_nopasswd "$user"; then
        info "$role '$user' has a NOPASSWD sudo rule; no password required."
        return 0
    fi
    if [[ "$(password_status "$user")" == "P" ]]; then
        info "$role '$user' already has a usable password for sudo."
        return 0
    fi
    if [[ ! -t 0 ]]; then
        warn "$role '$user' has no usable password and there is no terminal to prompt on."
        warn "Set one later with: passwd $user"
        return 1
    fi

    info "Setting a password for '$user' so sudo can authenticate."
    info "(SSH password login stays disabled; this password is for sudo/console only.)"
    local attempt=0
    while (( attempt < 3 )); do
        if passwd "$user"; then
            ok "Password set for '$user'."
            return 0
        fi
        attempt=$((attempt + 1))
        warn "Password not set (attempt $attempt/3)."
    done
    warn "Could not set a password for '$user'."
    return 1
}

verify_sudo_for() {
    local user="$1" role="$2" lockout="${3:-false}"
    if $DRY_RUN; then
        log "${YELLOW}[dry-run]${RESET} verify working sudo for $user"
        return 0
    fi

    local problem=""
    if ! user_has_sudo "$user"; then
        problem="'$user' is not in a sudo-capable group"
    elif ! sudo_grants_exist "$user"; then
        problem="sudoers grants no privileges to '$user'"
    elif ! sudo_can_authenticate "$user"; then
        problem="'$user' has no usable password (status: $(password_status "$user")) and no NOPASSWD rule, so sudo cannot authenticate"
    fi

    if [[ -z "$problem" ]]; then
        ok "$role '$user' has working sudo (grants present, authentication possible)."
        return 0
    fi

    if [[ "$lockout" == "true" ]]; then
        abort_lockout "$role sudo check failed: $problem. Disabling root login would leave no privileged access."
    fi
    warn "$role sudo check failed: $problem."
    warn "Fix with: passwd $user   (or add a sudoers rule for '$user')"
    return 1
}

ensure_admin() {
    ensure_linux_user "$ADMIN_USER" "administrator"
    grant_sudo "$ADMIN_USER" "administrator"
    install_ssh_key_for "$ADMIN_USER"
    # Repair a missing sudo auth path before the lockout-critical check runs.
    if ! $DRY_RUN && ! sudo_can_authenticate "$ADMIN_USER"; then
        warn "Administrator '$ADMIN_USER' cannot authenticate to sudo yet."
        ensure_sudo_password "$ADMIN_USER" "Administrator" || true
    fi
    verify_sudo_for "$ADMIN_USER" "Administrator" true
}

ensure_deploy_user() {
    $CREATE_DEPLOY_USER || { info "Deploy user creation disabled."; return 0; }
    if [[ "$DEPLOY_USER" == "$ADMIN_USER" ]]; then
        info "Deploy user matches admin ('$ADMIN_USER'); skipping duplicate account setup."
        return 0
    fi
    ensure_linux_user "$DEPLOY_USER" "deploy user"
    grant_sudo "$DEPLOY_USER" "deploy user"
    install_ssh_key_for "$DEPLOY_USER"
    ensure_sudo_password "$DEPLOY_USER" "Deploy user" || true
    if verify_sudo_for "$DEPLOY_USER" "Deploy user" false; then
        ok "Deploy user '$DEPLOY_USER' is ready (normal account, SSH key, working sudo)."
    else
        warn "Deploy user '$DEPLOY_USER' exists with an SSH key, but sudo is not usable yet."
    fi
    return 0
}

# ========= SSH hardening =========
write_sshd_config() {
    backup_file "$SSHD_DROPIN"
    detect_conflicting_sshd_dropins

    local tcp_fwd="no" agent_fwd="no"
    if [[ "$ALLOW_SSH_TCP_FORWARDING" == "true" ]]; then tcp_fwd="yes"; fi
    if [[ "$ALLOW_SSH_AGENT_FORWARDING" == "true" ]]; then agent_fwd="yes"; fi

    info "Writing hardened SSH configuration to $SSHD_DROPIN"
    local content
    content="$(cat <<EOF
# Managed by Fort. Do not edit by hand; changes may be overwritten.
# This drop-in is named 00-fort.conf so its values win (sshd uses the first
# obtained value for most keywords).

Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
AuthenticationMethods publickey
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding $tcp_fwd
AllowAgentForwarding $agent_fwd
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE
AllowUsers $(ssh_allow_users)
EOF
)"

    if $DRY_RUN; then
        log "${YELLOW}[dry-run]${RESET} would write $SSHD_DROPIN:"
        echo "$content" | sed 's/^/    /' 1>&2
    else
        install -d -m 0755 "$(dirname "$SSHD_DROPIN")"
        printf '%s\n' "$content" > "$SSHD_DROPIN"
        chmod 0644 "$SSHD_DROPIN"
    fi

    ensure_sshd_include
}

# Ubuntu/Debian sshd_config normally has `Include /etc/ssh/sshd_config.d/*.conf`.
# If it is missing, our drop-in would be ignored — a silent hardening failure.
ensure_sshd_include() {
    local main="/etc/ssh/sshd_config"
    [[ -f "$main" ]] || return 0
    if grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' "$main"; then
        dbg "sshd_config already includes drop-in directory."
        return 0
    fi
    warn "sshd_config does not Include the drop-in directory; adding it."
    backup_file "$main"
    if ! $DRY_RUN; then
        # Prepend so drop-ins take precedence (first value wins).
        printf 'Include /etc/ssh/sshd_config.d/*.conf\n%s' "$(cat "$main")" > "$main.fort.tmp"
        mv "$main.fort.tmp" "$main"
    fi
}

detect_conflicting_sshd_dropins() {
    local d="/etc/ssh/sshd_config.d"
    [[ -d "$d" ]] || return 0
    local f
    for f in "$d"/*.conf; do
        [[ -e "$f" ]] || continue
        if [[ "$f" == "$SSHD_DROPIN" ]]; then continue; fi
        if grep -qiE '^\s*(PasswordAuthentication|PermitRootLogin)\s+(yes|prohibit-password)' "$f"; then
            warn "Conflicting SSH drop-in detected: $f (may re-enable password/root login)."
            warn "Fort's 00-fort.conf is ordered first, so it wins, but review this file."
        fi
    done
    return 0
}

validate_sshd() {
    if $DRY_RUN; then
        log "${YELLOW}[dry-run]${RESET} sshd -t (syntax check)"
        return 0
    fi
    if ! sshd -t 2>/tmp/fort-sshd-t.log; then
        warn "sshd configuration test failed:"
        sed 's/^/    /' /tmp/fort-sshd-t.log 1>&2 || true
        abort_lockout "SSH configuration is invalid; not reloading sshd."
    fi
    ok "SSH configuration syntax is valid."
}

# The most important lockout gate: use `sshd -T` to compute the EFFECTIVE
# configuration for the admin user and confirm they can still log in by key
# BEFORE we reload the daemon.
preflight_ssh_lockout() {
    if $DRY_RUN; then
        log "${YELLOW}[dry-run]${RESET} sshd -T effective-config lockout preflight"
        return 0
    fi
    local eff
    if ! eff="$(sshd -T -C user="$ADMIN_USER",host=localhost,addr=127.0.0.1 2>/tmp/fort-sshd-T.log)"; then
        warn "$(cat /tmp/fort-sshd-T.log 2>/dev/null)"
        abort_lockout "Could not evaluate effective SSH config for '$ADMIN_USER'."
    fi
    local get
    get() { echo "$eff" | grep -i "^$1 " | awk '{print $2}'; return 0; }

    [[ "$(get pubkeyauthentication)" == "yes" ]] || abort_lockout "Effective config disables public-key auth for $ADMIN_USER."
    if [[ "$(get permitrootlogin)" == "yes" ]]; then
        warn "Root login still permitted (unexpected)."
    fi
    [[ "$(get port)" == "$SSH_PORT" ]] || abort_lockout "Effective SSH port ($(get port)) != requested ($SSH_PORT)."

    # If AllowUsers/AllowGroups is set, the admin must be included.
    local allowusers
    allowusers="$(echo "$eff" | grep -i '^allowusers ' | cut -d' ' -f2- || true)"
    if [[ -n "$allowusers" ]] && ! grep -qw "$ADMIN_USER" <<<"$allowusers"; then
        abort_lockout "AllowUsers is set but does not include '$ADMIN_USER'."
    fi
    if $CREATE_DEPLOY_USER && [[ -n "$DEPLOY_USER" && "$DEPLOY_USER" != "$ADMIN_USER" ]] \
        && [[ -n "$allowusers" ]] && ! grep -qw "$DEPLOY_USER" <<<"$allowusers"; then
        abort_lockout "AllowUsers is set but does not include deploy user '$DEPLOY_USER'."
    fi

    # The admin must actually have an installed authorized key.
    local home auth; home="$(getent passwd "$ADMIN_USER" | cut -d: -f6 || true)"
    [[ -n "$home" ]] || home="/home/$ADMIN_USER"
    auth="$home/.ssh/authorized_keys"
    [[ -s "$auth" ]] || abort_lockout "No authorized_keys for '$ADMIN_USER'; key login impossible."

    ok "SSH lockout preflight passed (key auth on port $SSH_PORT for $ADMIN_USER)."
}

reload_sshd() {
    info "Reloading SSH daemon."
    if have systemctl; then
        run_sh "systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd"
    else
        run_sh "service ssh reload 2>/dev/null || service sshd reload 2>/dev/null || service ssh restart"
    fi
    ok "SSH daemon reloaded."
}

# ========= Firewall (nftables, SSH-safe) =========
configure_firewall() {
    backup_file "$NFT_CONF"

    # During a port change keep 22 open too, so an in-flight session survives.
    local ssh_ports="$SSH_PORT"
    if [[ "$SSH_PORT" != "22" ]]; then ssh_ports="22, $SSH_PORT"; fi

    local web_rules=""
    if [[ "$ALLOW_HTTP"  == "true" ]]; then web_rules+="        tcp dport 80 accept\n"; fi
    if [[ "$ALLOW_HTTPS" == "true" ]]; then web_rules+="        tcp dport 443 accept\n"; fi

    info "Writing deny-by-default nftables policy (SSH always permitted)."
    local content
    content="$(cat <<EOF
#!/usr/sbin/nft -f
# Managed by Fort. Deny-by-default inbound; SSH is always allowed.
flush ruleset

table inet fort {
    chain input {
        type filter hook input priority 0; policy drop;

        ct state established,related accept
        ct state invalid drop
        iif "lo" accept

        ip protocol icmp icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded } accept
        ip6 nexthdr ipv6-icmp accept

        tcp dport { $ssh_ports } accept
$(echo -e "$web_rules")
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF
)"

    if $DRY_RUN; then
        log "${YELLOW}[dry-run]${RESET} would write $NFT_CONF:"
        echo "$content" | sed 's/^/    /' 1>&2
    else
        printf '%s\n' "$content" > "$NFT_CONF"
        chmod 0755 "$NFT_CONF"
        # Validate before applying; a bad ruleset must not drop us.
        if ! nft -c -f "$NFT_CONF" 2>/tmp/fort-nft.log; then
            warn "$(cat /tmp/fort-nft.log 2>/dev/null)"
            abort_lockout "nftables ruleset failed validation; not applying."
        fi
        nft -f "$NFT_CONF"
    fi

    if ! run systemctl enable --now nftables; then
        abort_lockout "nftables could not be enabled; inspect: systemctl status nftables"
    fi
    if ! $DRY_RUN; then
        fw_has_fort_table || abort_lockout "Fort firewall table is absent after applying $NFT_CONF."
        fw_input_policy_drop || abort_lockout "Fort firewall input chain is not deny-by-default after applying $NFT_CONF."
    fi
    ok "Firewall configured (SSH ports: $ssh_ports)."
    if [[ "$SSH_PORT" != "22" ]]; then
        warn "Port 22 left open for transition. After confirming login on $SSH_PORT, re-run without transition or remove it manually."
    fi
    return 0
}

# ========= Fail2Ban =========
configure_fail2ban() {
    backup_file "$FAIL2BAN_JAIL"

    # Never ban ourselves: whitelist loopback, RFC1918, and the current client.
    local ignore="127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        local client_ip; client_ip="$(awk '{print $1}' <<<"$SSH_CONNECTION")"
        if [[ -n "$client_ip" ]]; then ignore="$ignore $client_ip"; fi
        info "Whitelisting current SSH client in Fail2Ban: $client_ip"
    fi

    local content
    content="$(cat <<EOF
# Managed by Fort.
[DEFAULT]
ignoreip = $ignore
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = $SSH_PORT
EOF
)"
    if $DRY_RUN; then
        log "${YELLOW}[dry-run]${RESET} would write $FAIL2BAN_JAIL"
        echo "$content" | sed 's/^/    /' 1>&2
    else
        install -d -m 0755 "$(dirname "$FAIL2BAN_JAIL")"
        printf '%s\n' "$content" > "$FAIL2BAN_JAIL"
    fi
    run systemctl enable fail2ban 2>/dev/null || true
    run_sh "systemctl restart fail2ban 2>/dev/null || true"
    ok "Fail2Ban configured for SSH port $SSH_PORT (operator whitelisted)."
}

# ========= Automatic security updates =========
configure_unattended_upgrades() {
    local cfg="/etc/apt/apt.conf.d/20fort-auto-upgrades"
    backup_file "$cfg"
    local content
    content="$(cat <<'EOF'
// Managed by Fort.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
)"
    if $DRY_RUN; then
        log "${YELLOW}[dry-run]${RESET} would write $cfg"
    else
        printf '%s\n' "$content" > "$cfg"
    fi
    run systemctl enable unattended-upgrades 2>/dev/null || true
    ok "Automatic security updates enabled."
}

# ========= Kernel hardening (conservative) =========
configure_sysctl() {
    backup_file "$SYSCTL_CONF"
    local content
    content="$(cat <<'EOF'
# Managed by Fort. Conservative host hardening.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
EOF
)"
    if $DRY_RUN; then
        log "${YELLOW}[dry-run]${RESET} would write $SYSCTL_CONF and run sysctl --system"
    else
        printf '%s\n' "$content" > "$SYSCTL_CONF"
        sysctl --system >/dev/null 2>&1 || warn "Some sysctl settings could not be applied (may be a container)."
    fi
    ok "Kernel hardening settings applied."
}

# ========= Auditing =========
configure_auditd() {
    local rules="/etc/audit/rules.d/fort.rules"
    backup_file "$rules"
    local content
    content="$(cat <<'EOF'
# Managed by Fort.
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /etc/ssh/ -p wa -k sshd
EOF
)"
    if $DRY_RUN; then
        log "${YELLOW}[dry-run]${RESET} would write $rules"
    else
        install -d -m 0750 "$(dirname "$rules")"
        printf '%s\n' "$content" > "$rules"
    fi
    run systemctl enable auditd 2>/dev/null || true
    run_sh "augenrules --load 2>/dev/null || systemctl restart auditd 2>/dev/null || true"
    ok "auditd configured."
}

# ========= Dependency and environment preflight =========
APT_UPDATED=false
pkg_install() {
    local packages=("$@")
    if $DRY_RUN; then
        log "${YELLOW}[dry-run]${RESET} apt-get install -y ${packages[*]}"
        return 0
    fi
    if ! $APT_UPDATED; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq \
            || err "$EX_GENERAL" "apt-get update failed; no hardening changes were made."
        APT_UPDATED=true
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}" \
        || err "$EX_GENERAL" "Failed to install required dependencies: ${packages[*]}"
}

check_firewall_conflicts() {
    if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
        err "$EX_VALIDATION" "UFW is active. Fort uses nftables directly; disable or migrate UFW before hardening."
    fi
    if have firewall-cmd && systemctl is-active --quiet firewalld; then
        err "$EX_VALIDATION" "firewalld is active. Fort cannot safely manage nftables concurrently."
    fi
    if systemctl is-active --quiet docker 2>/dev/null || systemctl is-active --quiet containerd 2>/dev/null; then
        warn "A container runtime is active. Fort's nftables rules may affect published ports and forwarding."
    fi
}

ensure_dependencies() {
    info "Checking required dependencies before hardening."
    have apt-get || err "$EX_UNSUPPORTED" "apt-get is required on supported Debian/Ubuntu systems."
    have systemctl || err "$EX_UNSUPPORTED" "systemd/systemctl is required."

    local missing_packages=()
    have sshd              || missing_packages+=(openssh-server)
    have ssh-keygen        || missing_packages+=(openssh-client)
    have sudo              || missing_packages+=(sudo)
    have nft               || missing_packages+=(nftables)
    have fail2ban-server   || missing_packages+=(fail2ban)
    have unattended-upgrade || missing_packages+=(unattended-upgrades)
    have auditctl          || missing_packages+=(auditd)
    have sysctl            || missing_packages+=(procps)
    have ss                || missing_packages+=(iproute2)

    if (( ${#missing_packages[@]} > 0 )); then
        info "Installing missing dependencies: ${missing_packages[*]}"
        pkg_install "${missing_packages[@]}"
    fi

    if ! $DRY_RUN; then
        local tool
        for tool in sshd ssh-keygen sudo nft fail2ban-server unattended-upgrade auditctl sysctl ss; do
            have "$tool" || err "$EX_GENERAL" "Required dependency '$tool' is still unavailable after installation."
        done
    fi
    check_firewall_conflicts
    ok "Dependency and firewall-conflict preflight passed."
}

# ========= Commands =========
cmd_doctor() {
    banner
    detect_os
    info "OS: $OS_ID $OS_VERSION"
    info "Root: $([[ ${EUID:-$(id -u)} -eq 0 ]] && echo yes || echo no)"
    local tool
    for tool in apt-get systemctl sshd ssh-keygen sudo nft fail2ban-server unattended-upgrade auditctl sysctl ss; do
        if have "$tool"; then ok "found: $tool"; else warn "missing: $tool (Fort can install it during harden)"; fi
    done
    if have ufw; then
        info "UFW: $(ufw status 2>/dev/null | awk -F': ' '/^Status:/ {print $2}' || echo unknown)"
    fi
    if have firewall-cmd; then
        info "firewalld: $(systemctl is-active firewalld 2>/dev/null || true)"
    fi
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        info "Running over SSH from: $(awk '{print $1}' <<<"$SSH_CONNECTION")"
        warn "Keep this session OPEN while you test a second SSH login after hardening."
    fi
    ok "doctor completed."
}

check() {
    # check DESCRIPTION COMMAND... — prints pass/fail, updates FAIL_COUNT.
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        ok "$desc"
    else
        warn "$desc — FAILED"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Root login is disabled, so at least one SSH-allowed account must be able to
# actually run sudo, otherwise the server has no reachable privileged access.
verify_sudo_reachable() {
    local eff_file="$1"
    local users u
    users="$(grep -i '^allowusers ' "$eff_file" | cut -d' ' -f2- || true)"
    [[ -n "$users" ]] || return 1
    for u in $users; do
        if user_has_sudo "$u" && sudo_grants_exist "$u" && sudo_can_authenticate "$u"; then
            return 0
        fi
    done
    return 1
}

FAIL_COUNT=0
cmd_verify() {
    banner
    detect_os
    require_root verify
    FAIL_COUNT=0
    local eff_file; eff_file="$(mktemp)"
    if have sshd && [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        sshd -T 2>/dev/null > "$eff_file" || true
    fi

    check "an SSH-allowed account has working sudo" verify_sudo_reachable "$eff_file"
    check "root SSH login disabled"            grep -qi '^permitrootlogin no' "$eff_file"
    check "password authentication disabled"   grep -qi '^passwordauthentication no' "$eff_file"
    check "public-key authentication enabled"  grep -qi '^pubkeyauthentication yes' "$eff_file"
    check "SSH configuration valid"            sshd -t
    check "firewall active (Fort nftables table)" fw_has_fort_table
    check "default inbound policy is drop"        fw_input_policy_drop
    check "Fail2Ban active"                    systemctl is-active --quiet fail2ban
    check "automatic security updates enabled" systemctl is-enabled --quiet unattended-upgrades
    check "auditd active"                      systemctl is-active --quiet auditd
    check "kernel hardening loaded"            test -f "$SYSCTL_CONF"

    rm -f "$eff_file"
    if [[ "$FAIL_COUNT" -eq 0 ]]; then
        ok "All Fort controls verified."
        exit "$EX_OK"
    fi
    warn "$FAIL_COUNT control(s) not satisfied."
    exit "$EX_GENERAL"
}

cmd_audit() {
    banner
    detect_os
    info "Read-only audit (no changes will be made)."
    echo "── SSH ──" 1>&2
    if have sshd && [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|allowusers|maxauthtries) ' | sed 's/^/  /' 1>&2 || true
    else
        warn "  Run as root to read effective sshd config."
    fi
    echo "── Firewall ──" 1>&2
    if have nft; then nft list ruleset 2>/dev/null | sed 's/^/  /' 1>&2 || warn "  no ruleset"; else warn "  nft not installed"; fi
    echo "── Listening services ──" 1>&2
    if have ss; then ss -tulnp 2>/dev/null | sed 's/^/  /' 1>&2 || true; fi
    echo "── Services ──" 1>&2
    local s
    for s in fail2ban unattended-upgrades auditd nftables; do
        printf '  %-22s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo unknown)" 1>&2
    done
    ok "audit completed."
}

cmd_status() {
    banner
    detect_os
    local ssh_state fw_state f2b_state
    ssh_state="$(systemctl is-active ssh 2>/dev/null || true)"
    [[ "$ssh_state" == "active" ]] || ssh_state="$(systemctl is-active sshd 2>/dev/null || true)"
    [[ -n "$ssh_state" ]] || ssh_state="unknown"
    if fw_has_fort_table; then fw_state="hardened"; else fw_state="default/none"; fi
    f2b_state="$(systemctl is-active fail2ban 2>/dev/null || true)"
    [[ -n "$f2b_state" ]] || f2b_state="inactive"
    log "${BOLD}Fort status${RESET}"
    log "  OS         : $OS_ID $OS_VERSION"
    log "  SSH        : $ssh_state"
    log "  Firewall   : $fw_state"
    log "  Fail2Ban   : $f2b_state"
    log "  Backups    : $([[ -f "$STATE_DIR/last-backup" ]] && cat "$STATE_DIR/last-backup" || echo none)"
}

cmd_rollback() {
    banner
    require_root rollback
    local dir="${1:-}"
    if [[ -z "$dir" ]]; then
        [[ -f "$STATE_DIR/last-backup" ]] || err "$EX_GENERAL" "No recorded backup to roll back to."
        dir="$(cat "$STATE_DIR/last-backup")"
    fi
    warn "Rolling back configuration from: $dir"
    confirm "Restore all Fort-managed files from this backup?" || err "$EX_OK" "Rollback cancelled."
    restore_from_backup "$dir"
    ok "Rollback complete. Verify SSH access in a NEW session before closing this one."
}

cmd_harden() {
    banner
    detect_os

    # 1) Validate inputs first (read-only; aborts with exit 5 if a lockout is
    #    possible, exit 2 on bad usage) so problems surface before root is needed.
    validate_harden_inputs

    # 2) State-changing work requires root.
    require_root harden

    # 3) Install and verify every dependency and reject firewall-manager
    #    conflicts before changing accounts, SSH, or firewall state.
    ensure_dependencies

    warn "IMPORTANT: keep this SSH session OPEN. After hardening, open a NEW"
    warn "session as '$ADMIN_USER' and run 'sudo whoami' BEFORE closing this one."

    # 4) Establish backup dir up-front so rollback is always possible.
    new_backup_dir
    record_backup_manifest

    # 5) Admin + deploy + key + sudo BEFORE any restriction.
    ensure_admin
    ensure_deploy_user

    # 6) Firewall first so SSH is explicitly allowed before we tighten SSH.
    configure_firewall

    # 7) Write hardened SSH config, validate syntax, then prove no lockout.
    write_sshd_config
    validate_sshd
    preflight_ssh_lockout

    # 8) Only now reload the daemon, then re-verify.
    reload_sshd
    preflight_ssh_lockout

    # 9) Defense-in-depth (non-lockout-critical).
    configure_fail2ban
    configure_unattended_upgrades
    configure_sysctl
    configure_auditd

    record_backup_manifest
    ok "Hardening complete."
    warn "VERIFY NOW in a separate terminal:"
    warn "    ssh -p $SSH_PORT $ADMIN_USER@<server-ip>"
    warn "    sudo whoami   # expect: root"
    warn "Only after that succeeds should you close this session."
    if [[ "$SSH_PORT" != "22" ]]; then
        warn "Port 22 is still open for transition; close it once the new port works."
    fi
    exit "$EX_OK"
}

# ========= Main =========
main() {
    parse_args "$@"
    case "$CMD" in
        harden)   cmd_harden ;;
        audit)    cmd_audit ;;
        verify)   cmd_verify ;;
        status)   cmd_status ;;
        doctor)   cmd_doctor ;;
        rollback) cmd_rollback ;;
        "")       usage; exit "$EX_USAGE" ;;
        *)        err "$EX_USAGE" "Unknown command: $CMD" ;;
    esac
}

trap 'err "$EX_GENERAL" "Interrupted."' INT TERM
main "$@"
