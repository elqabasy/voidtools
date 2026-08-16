#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

readonly SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PREFIX="${PREFIX:-/usr/local}"
DESTDIR="${DESTDIR:-}"
ACTION="install"

usage() {
  cat <<EOF
Usage: ./install.sh [--prefix <path>] [--uninstall]

Options:
  --prefix <path>  Installation prefix (default: /usr/local).
  --uninstall      Remove VPG from the selected prefix.
  -h, --help       Show this help.

DESTDIR and PREFIX environment variables are supported for packaging.
EOF
}

fatal() {
  printf 'install.sh: error: %s\n' "$*" >&2
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --prefix)
      (( $# >= 2 )) || fatal "missing value for --prefix"
      PREFIX="$2"
      shift 2
      ;;
    --prefix=*)
      PREFIX="${1#--prefix=}"
      shift
      ;;
    --uninstall)
      ACTION="uninstall"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fatal "unknown option: $1"
      ;;
  esac
done

[[ "${PREFIX}" == /* ]] || fatal "prefix must be an absolute path"
readonly INSTALL_ROOT="${DESTDIR}${PREFIX}/lib/vpg"
readonly BIN_DIR="${DESTDIR}${PREFIX}/bin"

if [[ "${ACTION}" == "uninstall" ]]; then
  rm -f -- "${BIN_DIR}/vpg"
  rm -rf -- "${INSTALL_ROOT}"
  printf 'VPG removed from %s\n' "${DESTDIR}${PREFIX}"
  exit 0
fi

for file in vpg src/backup.sh src/restore.sh; do
  [[ -f "${SOURCE_DIR}/${file}" ]] ||
    fatal "required source file is missing: ${file}"
done

install -d -m 0755 -- "${INSTALL_ROOT}/src" "${BIN_DIR}"
install -m 0755 -- "${SOURCE_DIR}/vpg" "${INSTALL_ROOT}/vpg"
install -m 0755 -- "${SOURCE_DIR}/src/backup.sh" "${INSTALL_ROOT}/src/backup.sh"
install -m 0755 -- "${SOURCE_DIR}/src/restore.sh" "${INSTALL_ROOT}/src/restore.sh"
ln -sfn -- "${PREFIX}/lib/vpg/vpg" "${BIN_DIR}/vpg"

printf 'VPG installed successfully.\n'
printf 'Executable: %s/vpg\n' "${PREFIX}/bin"
printf 'Try: vpg --help\n'
