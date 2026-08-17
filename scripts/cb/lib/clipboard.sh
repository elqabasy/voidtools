#!/usr/bin/env bash
# cb clipboard backend abstraction — sourceable, testable module.
#
# Provides backend detection, resolution, and copy operations for cb(1).
# Expects optional globals: VERBOSE, DRY_RUN, OSC52_MAX_SIZE, BACKEND (auto|...)

# ========= Backend identifiers =========
CB_BACKEND_PBCOPY="pbcopy"
CB_BACKEND_WL_COPY="wl-copy"
CB_BACKEND_XSEL="xsel"
CB_BACKEND_XCLIP="xclip"
CB_BACKEND_OSC52="osc52"
CB_BACKEND_NONE="none"

# Resolved during detect_clipboard_backend
CB_RESOLVED_BACKEND=""
CB_RESOLVED_REASON=""

# ========= Portable helpers =========
cb_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

cb_detect_os() {
    if [[ -n "${CB_TEST_UNAME:-}" ]]; then
        case "$CB_TEST_UNAME" in
            Darwin)  echo "macos" ;;
            Linux)   echo "linux" ;;
            FreeBSD) echo "freebsd" ;;
            OpenBSD) echo "openbsd" ;;
            NetBSD)  echo "netbsd" ;;
            *)       echo "unix" ;;
        esac
        return 0
    fi

    local kernel
    kernel="$(uname -s 2>/dev/null || echo unknown)"
    case "$kernel" in
        Darwin)  echo "macos" ;;
        Linux)   echo "linux" ;;
        FreeBSD) echo "freebsd" ;;
        OpenBSD) echo "openbsd" ;;
        NetBSD)  echo "netbsd" ;;
        *)       echo "unix" ;;
    esac
}

cb_is_macos() {
    [[ "$(cb_detect_os)" == "macos" ]]
}

cb_has_x_display() {
    [[ -n "${DISPLAY:-}" ]]
}

cb_is_wayland_session() {
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        return 0
    fi
    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        return 0
    fi
    return 1
}

cb_is_ssh_session() {
    [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ]]
}

cb_is_interactive_terminal() {
    if [[ "${CB_TEST_INTERACTIVE_TTY:-}" == "1" ]]; then
        return 0
    fi
    if [[ "${CB_TEST_INTERACTIVE_TTY:-}" == "0" ]]; then
        return 1
    fi

    if [[ "${TERM:-}" == "dumb" || -z "${TERM:-}" ]]; then
        return 1
    fi
    if [[ -t 1 || -t 2 ]]; then
        return 0
    fi
    if [[ -r /dev/tty ]] 2>/dev/null; then
        return 0
    fi
    return 1
}

cb_get_tty_device() {
    if [[ -n "${CB_TEST_TTY_DEVICE:-}" ]]; then
        printf '%s' "$CB_TEST_TTY_DEVICE"
        return 0
    fi

    if [[ -r /dev/tty ]] 2>/dev/null; then
        printf '%s' /dev/tty
        return 0
    fi
    if [[ -t 2 ]]; then
        printf '%s' /dev/stderr
        return 0
    fi
    return 1
}

cb_payload_size() {
    local payload="$1"
    # wc -c counts bytes; awk strips leading whitespace portably.
    printf '%s' "$payload" | wc -c | awk '{print $1}'
}

cb_base64_encode() {
    local payload="$1"
    local encoded=""

    # GNU base64 supports -w 0; BSD/macOS base64 does not.
    if encoded="$(printf '%s' "$payload" | base64 -w 0 2>/dev/null)"; then
        :
    elif encoded="$(printf '%s' "$payload" | base64 2>/dev/null | tr -d '\n')"; then
        :
    else
        return 1
    fi

    printf '%s' "$encoded"
}

# ========= Backend availability =========
cb_backend_available() {
    local backend="$1"

    case "$backend" in
        "$CB_BACKEND_PBCOPY")
            cb_command_exists pbcopy
            ;;
        "$CB_BACKEND_WL_COPY")
            cb_command_exists wl-copy && cb_is_wayland_session
            ;;
        "$CB_BACKEND_XSEL")
            cb_command_exists xsel && cb_has_x_display
            ;;
        "$CB_BACKEND_XCLIP")
            cb_command_exists xclip && cb_has_x_display
            ;;
        "$CB_BACKEND_OSC52")
            cb_is_interactive_terminal
            ;;
        "$CB_BACKEND_NONE")
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

cb_backend_unavailable_reason() {
    local backend="$1"

    case "$backend" in
        "$CB_BACKEND_PBCOPY")
            if ! cb_command_exists pbcopy; then
                printf '%s' "pbcopy is not available."
            else
                printf '%s' "pbcopy is unavailable."
            fi
            ;;
        "$CB_BACKEND_WL_COPY")
            if ! cb_command_exists wl-copy; then
                printf '%s' "Wayland session detected, but wl-copy is unavailable. Install wl-clipboard or use --backend=osc52."
            elif ! cb_is_wayland_session; then
                printf '%s' "wl-copy is installed, but no active Wayland session was detected."
            else
                printf '%s' "wl-copy is unavailable."
            fi
            ;;
        "$CB_BACKEND_XSEL")
            if ! cb_command_exists xsel; then
                if cb_has_x_display; then
                    printf '%s' "X11 display detected, but xsel is unavailable. Install xsel or xclip, or use --backend=osc52."
                else
                    printf '%s' "xsel is unavailable and no X11 display is set."
                fi
            else
                printf '%s' "xsel is unavailable (DISPLAY may be unset or invalid)."
            fi
            ;;
        "$CB_BACKEND_XCLIP")
            if ! cb_command_exists xclip; then
                if cb_has_x_display; then
                    printf '%s' "X11 display detected, but xclip is unavailable. Install xclip or xsel, or use --backend=osc52."
                else
                    printf '%s' "xclip is unavailable and no X11 display is set."
                fi
            else
                printf '%s' "xclip is unavailable (DISPLAY may be unset or invalid)."
            fi
            ;;
        "$CB_BACKEND_OSC52")
            if [[ "${TERM:-}" == "dumb" || -z "${TERM:-}" ]]; then
                printf '%s' "OSC 52 requires a capable terminal (TERM is unset or dumb)."
            elif ! cb_get_tty_device >/dev/null; then
                printf '%s' "OSC 52 requires an interactive terminal (no controlling TTY)."
            else
                printf '%s' "OSC 52 is unavailable in this environment."
            fi
            ;;
        *)
            printf '%s' "Unknown clipboard backend: $backend"
            ;;
    esac
}

# ========= Backend auto-detection =========
cb_detect_clipboard_backend() {
    local requested="${1:-auto}"
    local os

    CB_RESOLVED_BACKEND=""
    CB_RESOLVED_REASON=""

    if [[ "$requested" != "auto" ]]; then
        if cb_backend_available "$requested"; then
            CB_RESOLVED_BACKEND="$requested"
            CB_RESOLVED_REASON="explicitly selected with --backend=$requested"
            return 0
        fi
        CB_RESOLVED_BACKEND="$CB_BACKEND_NONE"
        CB_RESOLVED_REASON="$(cb_backend_unavailable_reason "$requested")"
        return 1
    fi

    os="$(cb_detect_os)"

    if [[ "$os" == "macos" ]] && cb_backend_available "$CB_BACKEND_PBCOPY"; then
        CB_RESOLVED_BACKEND="$CB_BACKEND_PBCOPY"
        CB_RESOLVED_REASON="macOS with pbcopy available"
        return 0
    fi

    if cb_backend_available "$CB_BACKEND_WL_COPY"; then
        CB_RESOLVED_BACKEND="$CB_BACKEND_WL_COPY"
        CB_RESOLVED_REASON="active Wayland session with wl-copy available"
        return 0
    fi

    if cb_backend_available "$CB_BACKEND_XSEL"; then
        CB_RESOLVED_BACKEND="$CB_BACKEND_XSEL"
        CB_RESOLVED_REASON="X11 display available; using xsel"
        return 0
    fi

    if cb_backend_available "$CB_BACKEND_XCLIP"; then
        CB_RESOLVED_BACKEND="$CB_BACKEND_XCLIP"
        CB_RESOLVED_REASON="X11 display available; using xclip"
        return 0
    fi

    if cb_backend_available "$CB_BACKEND_OSC52"; then
        CB_RESOLVED_BACKEND="$CB_BACKEND_OSC52"
        if cb_is_ssh_session; then
            CB_RESOLVED_REASON="no graphical display detected; interactive SSH terminal available"
        else
            CB_RESOLVED_REASON="no graphical clipboard detected; interactive terminal available"
        fi
        return 0
    fi

    CB_RESOLVED_BACKEND="$CB_BACKEND_NONE"
    if cb_is_wayland_session && ! cb_command_exists wl-copy; then
        CB_RESOLVED_REASON="Wayland session detected, but wl-copy is unavailable"
    elif cb_has_x_display; then
        CB_RESOLVED_REASON="X11 display detected, but neither xsel nor xclip is available"
    elif cb_is_ssh_session; then
        CB_RESOLVED_REASON="SSH session detected, but no interactive terminal supports OSC 52"
    else
        CB_RESOLVED_REASON="no usable clipboard backend detected"
    fi
    return 1
}

cb_list_valid_backends() {
    printf '%s' "auto pbcopy wl-copy xsel xclip osc52"
}

cb_validate_backend_name() {
    local name="$1"
    case "$name" in
        auto|pbcopy|wl-copy|xsel|xclip|osc52) return 0 ;;
        *) return 1 ;;
    esac
}

# ========= Copy implementations =========
cb_copy_with_pbcopy() {
    local payload="$1"
    printf '%s' "$payload" | pbcopy
}

cb_copy_with_wl_copy() {
    local payload="$1"
    printf '%s' "$payload" | wl-copy
}

cb_copy_with_xsel() {
    local payload="$1"
    printf '%s' "$payload" | xsel --clipboard --input
}

cb_copy_with_xclip() {
    local payload="$1"
    printf '%s' "$payload" | xclip -selection clipboard
}

cb_copy_with_osc52() {
    local payload="$1"
    local limit="${OSC52_MAX_SIZE:-1048576}"
    local size encoded tty inner outer

    if ! cb_is_interactive_terminal; then
        return 1
    fi

    size="$(cb_payload_size "$payload")"
    if [[ -z "$size" ]]; then
        size=0
    fi
    if (( size > limit )); then
        CB_OSC52_ERROR="payload size ${size} bytes exceeds OSC 52 limit (${limit} bytes)"
        return 1
    fi

    encoded="$(cb_base64_encode "$payload")" || return 1

    # OSC 52: ESC ] 52 ; c ; base64 ST
    inner=$'\033]52;c;'"${encoded}"$'\033\\'

    if [[ -n "${TMUX:-}" ]]; then
        # tmux DCS passthrough wrapper
        outer=$'\033Ptmux;\033'"${inner}"$'\033\\'
    elif [[ -n "${STY:-}" ]]; then
        # GNU screen passthrough wrapper
        outer=$'\033P\033'"${inner}"$'\033\\'
    else
        outer="$inner"
    fi

    tty="$(cb_get_tty_device)" || return 1
    # shellcheck disable=SC2189
    { printf '%s' "$outer"; } >"$tty" 2>/dev/null || return 1
    return 0
}

cb_copy_to_clipboard() {
    local payload="$1"
    local backend="${2:-$CB_RESOLVED_BACKEND}"

    case "$backend" in
        "$CB_BACKEND_PBCOPY")  cb_copy_with_pbcopy "$payload" ;;
        "$CB_BACKEND_WL_COPY") cb_copy_with_wl_copy "$payload" ;;
        "$CB_BACKEND_XSEL")    cb_copy_with_xsel "$payload" ;;
        "$CB_BACKEND_XCLIP")   cb_copy_with_xclip "$payload" ;;
        "$CB_BACKEND_OSC52")   cb_copy_with_osc52 "$payload" ;;
        *)
            CB_RESOLVED_REASON="no usable clipboard backend selected"
            return 1
            ;;
    esac
}

cb_no_backend_message() {
    local os reason
    os="$(cb_detect_os)"
    reason="${CB_RESOLVED_REASON:-no usable clipboard backend detected}"

    printf '%s\n' "No usable clipboard backend detected." >&2
    printf '%s\n' "$reason" >&2

    case "$os" in
        macos)
            printf '%s\n' "On macOS, pbcopy should normally be available." >&2
            ;;
        linux)
            if cb_is_wayland_session; then
                printf '%s\n' "Install wl-clipboard (wl-copy), or use --backend=osc52 over SSH." >&2
            elif cb_has_x_display; then
                printf '%s\n' "Install xsel or xclip for X11, or use --backend=osc52 over SSH." >&2
            elif cb_is_ssh_session; then
                printf '%s\n' "Over SSH, ensure your terminal supports OSC 52 clipboard sync." >&2
                printf '%s\n' "Try: cb -v hello   or   cb --backend=osc52 hello" >&2
            else
                printf '%s\n' "No graphical session detected. Use an interactive terminal with OSC 52 support." >&2
            fi
            ;;
        freebsd|openbsd|netbsd)
            if cb_has_x_display; then
                printf '%s\n' "Install xsel or xclip for X11, or use --backend=osc52." >&2
            else
                printf '%s\n' "Use an interactive terminal with OSC 52 support, or set DISPLAY for X11." >&2
            fi
            ;;
        *)
            printf '%s\n' "Install a supported clipboard tool or use --backend=osc52 in a capable terminal." >&2
            ;;
    esac
}

cb_verbose_environment() {
    local os session="local"
    os="$(cb_detect_os)"

    if cb_is_ssh_session; then
        session="SSH"
    fi

    printf '[*] OS: %s\n' "$os"
    printf '[*] Session: %s\n' "$session"
    if cb_has_x_display; then
        printf '[*] DISPLAY: %s\n' "$DISPLAY"
    else
        printf '[*] DISPLAY: unavailable\n'
    fi
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        printf '[*] WAYLAND_DISPLAY: %s\n' "$WAYLAND_DISPLAY"
    else
        printf '[*] WAYLAND_DISPLAY: unavailable\n'
    fi
    if [[ -n "${TMUX:-}" ]]; then
        printf '[*] TMUX: %s\n' "$TMUX"
    fi
    if [[ -n "${STY:-}" ]]; then
        printf '[*] STY: %s\n' "$STY"
    fi
}
