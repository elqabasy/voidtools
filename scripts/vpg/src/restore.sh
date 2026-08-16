#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly PROGRAM="${VPG_PROGRAM:-$(basename -- "$0")}"
readonly DEFAULT_CONTAINER="infra_postgres"
readonly DEFAULT_TIMEOUT=240

BACKUP_SOURCE=""
BACKUP_DIRECTORY=""
EXTRACT_DIRECTORY=""
TARGET_CONTAINER="${DEFAULT_CONTAINER}"
TIMEOUT="${DEFAULT_TIMEOUT}"
FORCE=false
KEEP_FAILED=false
VERBOSE=false

RESTORE_CONTAINER=""
RESTORE_ENV_FILE=""
DESTRUCTIVE_PHASE_STARTED=false
TARGET_IMAGE=""
TARGET_USER=""
TARGET_SHM_SIZE=""
TARGET_ADMIN=""
PGDATA_PATH=""
CONTROL_DB=""

usage() {
  cat <<EOF
Usage:
  ${PROGRAM} <backup-directory|archive.tar.gz> [options]

Restore options:
  --container <name>       Target PostgreSQL container.
                           Default: ${DEFAULT_CONTAINER}
  --timeout <seconds>      Readiness timeout per startup phase.
                           Default: ${DEFAULT_TIMEOUT}
  --force                  Skip the interactive REPLACE confirmation.
  --keep-failed            Keep the isolated restore container after failure.
  --verbose                Enable verbose pg_restore output.
  -h, --help               Show this help.

The backup is fully verified before any destructive action. Restoration then:
  1. Stops the target container.
  2. Erases its PGDATA volume.
  3. Initializes an isolated, network-disabled replacement cluster.
  4. Restores globals and every database from the VPG bundle.
  5. Verifies the cluster before restarting the original container.

WARNING: This permanently replaces the target container's PostgreSQL cluster.

Examples:
  ${PROGRAM} ./postgres_cluster_2026-08-16_17-30-00_UTC_abcd1234
  ${PROGRAM} ./postgres_cluster_2026-08-16_17-30-00_UTC_abcd1234.tar.gz \\
    --container infra_postgres
  ${PROGRAM} ./backup.tar.gz --container infra_postgres --force
EOF
}

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

fatal() {
  printf '[%s] ERROR: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fatal "Required command not found: $1"
}

require_option_value() {
  (( $# >= 2 )) || fatal "Missing value for $1."
}

manifest_value() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { print value }' \
    "${BACKUP_DIRECTORY}/manifest.txt"
}

parse_arguments() {
  local -a positional=()
  while (( $# > 0 )); do
    case "$1" in
      --container)
        require_option_value "$@"
        TARGET_CONTAINER="$2"
        shift 2
        ;;
      --container=*)
        TARGET_CONTAINER="${1#--container=}"
        shift
        ;;
      --timeout)
        require_option_value "$@"
        TIMEOUT="$2"
        shift 2
        ;;
      --timeout=*)
        TIMEOUT="${1#--timeout=}"
        shift
        ;;
      --force)
        FORCE=true
        shift
        ;;
      --keep-failed)
        KEEP_FAILED=true
        shift
        ;;
      --verbose)
        VERBOSE=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      -*)
        fatal "Unknown option: $1"
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  [[ ${#positional[@]} -eq 1 ]] || {
    usage >&2
    exit 2
  }
  BACKUP_SOURCE="${positional[0]}"
}

validate_options() {
  [[ -n "${TARGET_CONTAINER}" && "${TARGET_CONTAINER}" != -* ]] ||
    fatal "Container name is invalid."
  [[ "${TIMEOUT}" =~ ^[1-9][0-9]*$ ]] ||
    fatal "Timeout must be a positive integer."
  (( TIMEOUT <= 3600 )) || fatal "Timeout must not exceed 3600 seconds."
}

check_dependencies() {
  local command
  for command in docker awk base64 find sha256sum sort mktemp date rm; do
    require_command "${command}"
  done
  docker info >/dev/null 2>&1 ||
    fatal "Docker daemon is unavailable or the current user cannot access it."
}

validate_archive_paths() {
  local archive="$1"
  local entry
  local root=""

  while IFS= read -r entry; do
    entry="${entry%/}"
    [[ -n "${entry}" ]] || continue
    [[ "${entry}" != /* && "${entry}" != *\\* ]] ||
      fatal "Archive contains an unsafe absolute path."
    [[ "${entry}" != ".." && "${entry}" != ../* && "${entry}" != */../* && "${entry}" != */.. ]] ||
      fatal "Archive contains path traversal."
    if [[ -z "${root}" ]]; then
      root="${entry%%/*}"
    fi
    [[ "${entry}" == "${root}" || "${entry}" == "${root}/"* ]] ||
      fatal "Archive must contain exactly one top-level backup directory."
  done < <(tar --list --gzip --file="${archive}")

  [[ -n "${root}" && "${root}" != "." ]] ||
    fatal "Archive is empty or has an invalid root directory."
  printf '%s' "${root}"
}

prepare_backup() {
  if [[ -d "${BACKUP_SOURCE}" ]]; then
    BACKUP_DIRECTORY="$(cd -- "${BACKUP_SOURCE}" && pwd -P)"
    [[ ! -L "${BACKUP_SOURCE}" ]] ||
      fatal "Backup directory must not be a symbolic link."
    return
  fi

  [[ -f "${BACKUP_SOURCE}" && -s "${BACKUP_SOURCE}" ]] ||
    fatal "Backup source does not exist or is empty: ${BACKUP_SOURCE}"
  [[ ! -L "${BACKUP_SOURCE}" ]] ||
    fatal "Backup archive must not be a symbolic link."
  require_command tar
  require_command gzip
  gzip --test -- "${BACKUP_SOURCE}" ||
    fatal "Backup archive compression validation failed."

  if [[ -f "${BACKUP_SOURCE}.sha256" ]]; then
    (
      cd -- "$(dirname -- "${BACKUP_SOURCE}")"
      sha256sum --check --strict -- "$(basename -- "${BACKUP_SOURCE}.sha256")"
    ) >/dev/null || fatal "Backup archive SHA-256 checksum verification failed."
  fi

  local root
  root="$(validate_archive_paths "${BACKUP_SOURCE}")"
  EXTRACT_DIRECTORY="$(mktemp -d)"
  tar --extract --gzip --file="${BACKUP_SOURCE}" \
    --directory="${EXTRACT_DIRECTORY}" \
    --no-same-owner --no-same-permissions
  BACKUP_DIRECTORY="${EXTRACT_DIRECTORY}/${root}"
}

verify_backup() {
  log "Verifying backup structure and checksums"
  [[ -d "${BACKUP_DIRECTORY}" && ! -L "${BACKUP_DIRECTORY}" ]] ||
    fatal "Backup directory is invalid."

  local required
  for required in manifest.txt globals.sql database-map.tsv FILES.txt SHA256SUMS BACKUP_COMPLETE; do
    [[ -f "${BACKUP_DIRECTORY}/${required}" && ! -L "${BACKUP_DIRECTORY}/${required}" ]] ||
      fatal "Required regular backup file is missing: ${required}"
  done

  [[ "$(manifest_value backup_format_version)" == "1" ]] ||
    fatal "Unsupported or missing backup format version."
  [[ "$(manifest_value status)" == "complete" ]] ||
    fatal "Backup manifest is not complete."

  local unexpected
  local actual_inventory
  local expected_inventory
  unexpected="$(
    find "${BACKUP_DIRECTORY}" -mindepth 1 -maxdepth 1 ! -type f -print -quit
  )"
  [[ -z "${unexpected}" ]] ||
    fatal "Unexpected non-regular backup entry: ${unexpected}"

  awk '
    NF == 0 || /^\// || /(^|\/)\.\.(\/|$)/ || index($0, "/") {
      print "unsafe inventory entry at line " NR > "/dev/stderr"
      exit 1
    }
  ' "${BACKUP_DIRECTORY}/FILES.txt" ||
    fatal "Backup inventory contains unsafe paths."

  actual_inventory="$(
    find "${BACKUP_DIRECTORY}" -mindepth 1 -maxdepth 1 -type f \
      ! -name FILES.txt \
      ! -name SHA256SUMS \
      ! -name BACKUP_COMPLETE \
      ! -name BACKUP_FAILED \
      -printf '%f\n' |
      LC_ALL=C sort
  )"
  expected_inventory="$(LC_ALL=C sort -- "${BACKUP_DIRECTORY}/FILES.txt")"
  [[ "${actual_inventory}" == "${expected_inventory}" ]] ||
    fatal "File inventory does not match backup contents."

  (
    cd -- "${BACKUP_DIRECTORY}"
    sha256sum --check --strict --quiet -- SHA256SUMS
  ) || fatal "Backup integrity verification failed."

  local expected_count
  local actual_count=0
  expected_count="$(manifest_value database_count)"
  [[ "${expected_count}" =~ ^[1-9][0-9]*$ ]] ||
    fatal "Invalid database count in manifest."

  while IFS=$'\t' read -r dump_file encoded_name extra; do
    [[ "${dump_file}" == "dump_file" ]] && continue
    [[ -n "${dump_file}" && -n "${encoded_name}" && -z "${extra:-}" ]] ||
      fatal "Invalid database map entry."
    [[ "${dump_file}" =~ ^database_[0-9]{4}\.dump$ ]] ||
      fatal "Unsafe database dump name: ${dump_file}"
    [[ -s "${BACKUP_DIRECTORY}/${dump_file}" && ! -L "${BACKUP_DIRECTORY}/${dump_file}" ]] ||
      fatal "Database dump is missing or empty: ${dump_file}"
    printf '%s' "${encoded_name}" | base64 --decode >/dev/null 2>&1 ||
      fatal "Invalid encoded database name for ${dump_file}."
    ((actual_count += 1))
  done < "${BACKUP_DIRECTORY}/database-map.tsv"

  [[ "${actual_count}" == "${expected_count}" ]] ||
    fatal "Database map count does not match manifest."
  log "Backup verified (${actual_count} databases)"
}

container_env_value() {
  local key="$1"
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' \
    "${TARGET_CONTAINER}" |
    awk -F= -v key="${key}" '
      $1 == key { sub(/^[^=]*=/, ""); print; exit }
    '
}

inspect_target() {
  docker inspect --type container "${TARGET_CONTAINER}" >/dev/null 2>&1 ||
    fatal "Target container does not exist: ${TARGET_CONTAINER}"

  TARGET_IMAGE="$(docker inspect --format '{{.Config.Image}}' "${TARGET_CONTAINER}")"
  TARGET_USER="$(docker inspect --format '{{.Config.User}}' "${TARGET_CONTAINER}")"
  TARGET_SHM_SIZE="$(docker inspect --format '{{.HostConfig.ShmSize}}' "${TARGET_CONTAINER}")"
  TARGET_ADMIN="$(container_env_value POSTGRES_USER)"
  TARGET_ADMIN="${TARGET_ADMIN:-postgres}"
  PGDATA_PATH="$(container_env_value PGDATA)"
  PGDATA_PATH="${PGDATA_PATH:-/var/lib/postgresql/data}"

  case "${PGDATA_PATH}" in
    ""|"/"|"/var"|"/var/lib"|"/var/lib/postgresql")
      fatal "Refusing to erase unsafe PGDATA path: ${PGDATA_PATH}"
      ;;
    /*) ;;
    *) fatal "PGDATA must be an absolute path: ${PGDATA_PATH}" ;;
  esac

  docker run --rm --entrypoint postgres "${TARGET_IMAGE}" --version >/dev/null 2>&1 ||
    fatal "Target image does not provide PostgreSQL: ${TARGET_IMAGE}"

  local backup_major
  local target_major
  backup_major="$(
    manifest_value postgres_server_version |
      awk '{ split($1, parts, "."); print parts[1] }'
  )"
  target_major="$(
    docker run --rm --entrypoint postgres "${TARGET_IMAGE}" --version |
      awk '{ split($3, parts, "."); print parts[1] }'
  )"
  [[ "${backup_major}" =~ ^[0-9]+$ && "${target_major}" =~ ^[0-9]+$ ]] ||
    fatal "Unable to determine PostgreSQL major versions."
  (( target_major >= backup_major )) ||
    fatal "Target PostgreSQL ${target_major} is older than backup PostgreSQL ${backup_major}."
}

confirm_restore() {
  printf '\n'
  printf '============================================================\n'
  printf ' DESTRUCTIVE POSTGRESQL CLUSTER REPLACEMENT\n'
  printf '============================================================\n'
  printf 'Backup ID:   %s\n' "$(manifest_value backup_id)"
  printf 'Source:      %s\n' "${BACKUP_SOURCE}"
  printf 'Container:   %s\n' "${TARGET_CONTAINER}"
  printf 'Image:       %s\n' "${TARGET_IMAGE}"
  printf 'PGDATA:      %s\n' "${PGDATA_PATH}"
  printf 'Databases:   %s\n' "$(manifest_value database_count)"
  printf '============================================================\n'
  printf 'The current PostgreSQL data directory will be permanently\n'
  printf 'deleted. The container remains stopped if restoration fails.\n\n'

  if [[ "${FORCE}" == false ]]; then
    [[ -t 0 ]] ||
      fatal "Non-interactive restore requires --force."
    local confirmation
    read -r -p 'Type REPLACE to continue: ' confirmation
    [[ "${confirmation}" == "REPLACE" ]] || fatal "Restore cancelled."
  fi
}

wait_for_postgres() {
  local container="$1"
  local elapsed=0
  while (( elapsed < TIMEOUT )); do
    if docker exec "${container}" pg_isready -U "${TARGET_ADMIN}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    ((elapsed += 2))
  done
  return 1
}

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM

  if [[ -n "${RESTORE_ENV_FILE}" && -f "${RESTORE_ENV_FILE}" ]]; then
    rm -f -- "${RESTORE_ENV_FILE}" || true
  fi
  if [[ -n "${EXTRACT_DIRECTORY}" && -d "${EXTRACT_DIRECTORY}" ]]; then
    rm -rf -- "${EXTRACT_DIRECTORY}" || true
  fi

  if [[ -n "${RESTORE_CONTAINER}" ]] &&
     docker inspect "${RESTORE_CONTAINER}" >/dev/null 2>&1; then
    if [[ "${exit_code}" -eq 0 || "${KEEP_FAILED}" == false ]]; then
      docker rm -f "${RESTORE_CONTAINER}" >/dev/null 2>&1 || true
    else
      warn "Failed restore container retained: ${RESTORE_CONTAINER}"
    fi
  fi

  if [[ "${exit_code}" -ne 0 && "${DESTRUCTIVE_PHASE_STARTED}" == true ]]; then
    docker stop "${TARGET_CONTAINER}" >/dev/null 2>&1 || true
    warn "Restore failed after destructive work began."
    warn "The original container remains stopped to prevent use of a partial cluster."
  fi
  exit "${exit_code}"
}

erase_target_cluster() {
  log "Stopping target container"
  docker stop "${TARGET_CONTAINER}" >/dev/null

  log "Erasing existing PostgreSQL data directory"
  docker run --rm \
    --user 0:0 \
    --volumes-from "${TARGET_CONTAINER}" \
    --entrypoint /bin/sh \
    --env "RESTORE_PGDATA=${PGDATA_PATH}" \
    "${TARGET_IMAGE}" \
    -ceu '
      case "$RESTORE_PGDATA" in
        ""|"/"|"/var"|"/var/lib"|"/var/lib/postgresql")
          echo "Unsafe PGDATA path: $RESTORE_PGDATA" >&2
          exit 1
          ;;
      esac
      mkdir -p "$RESTORE_PGDATA"
      find "$RESTORE_PGDATA" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    '
}

start_isolated_cluster() {
  local restore_id
  restore_id="$(date -u +'%Y%m%d%H%M%S')_$$"
  RESTORE_CONTAINER="${TARGET_CONTAINER}_vpg_restore_${restore_id}"
  CONTROL_DB="vpg_restore_control_${restore_id}"
  RESTORE_ENV_FILE="$(mktemp)"
  chmod 0600 "${RESTORE_ENV_FILE}"

  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' \
    "${TARGET_CONTAINER}" > "${RESTORE_ENV_FILE}"

  local -a run_args=(
    --detach
    --name "${RESTORE_CONTAINER}"
    --network none
    --volumes-from "${TARGET_CONTAINER}"
    --env-file "${RESTORE_ENV_FILE}"
    --env POSTGRES_DB=postgres
  )
  [[ -z "${TARGET_USER}" ]] || run_args+=(--user "${TARGET_USER}")
  if [[ -n "${TARGET_SHM_SIZE}" && "${TARGET_SHM_SIZE}" != 0 ]]; then
    run_args+=(--shm-size "${TARGET_SHM_SIZE}")
  fi

  log "Initializing isolated replacement cluster"
  docker run "${run_args[@]}" "${TARGET_IMAGE}" >/dev/null
  if ! wait_for_postgres "${RESTORE_CONTAINER}"; then
    docker logs "${RESTORE_CONTAINER}" --tail 200 >&2 || true
    fatal "Isolated restore container did not become ready."
  fi
}

create_control_database() {
  docker exec "${RESTORE_CONTAINER}" \
    psql --no-psqlrc --set=ON_ERROR_STOP=1 \
      --username="${TARGET_ADMIN}" --dbname=postgres \
      --command="CREATE DATABASE \"${CONTROL_DB}\";" >/dev/null
}

restore_globals() {
  log "Restoring cluster globals"
  local protected_role
  protected_role="$(
    docker exec "${RESTORE_CONTAINER}" \
      psql --no-psqlrc --tuples-only --no-align \
        --username="${TARGET_ADMIN}" --dbname="${CONTROL_DB}" \
        --command='SELECT quote_ident(current_user);'
  )"

  awk -v protected="${protected_role}" '
    $0 == "CREATE ROLE " protected ";" { next }
    { print }
  ' "${BACKUP_DIRECTORY}/globals.sql" |
    docker exec -i "${RESTORE_CONTAINER}" \
      psql --no-psqlrc --set=ON_ERROR_STOP=1 \
        --username="${TARGET_ADMIN}" --dbname="${CONTROL_DB}"
}

restore_databases() {
  local dump_file
  local encoded_name
  local extra
  local database
  local index=0
  local total
  total="$(manifest_value database_count)"

  while IFS=$'\t' read -r dump_file encoded_name extra; do
    [[ "${dump_file}" == "dump_file" ]] && continue
    database="$(printf '%s' "${encoded_name}" | base64 --decode)"
    ((index += 1))
    log "Restoring database ${index}/${total}: ${database}"

    local -a options=(
      pg_restore
      --exit-on-error
      --clean
      --if-exists
      --create
      --no-password
      "--username=${TARGET_ADMIN}"
      "--dbname=${CONTROL_DB}"
    )
    [[ "${VERBOSE}" == false ]] || options+=(--verbose)
    docker exec -i "${RESTORE_CONTAINER}" "${options[@]}" \
      < "${BACKUP_DIRECTORY}/${dump_file}"
  done < "${BACKUP_DIRECTORY}/database-map.tsv"
}

verify_restored_cluster() {
  log "Verifying restored cluster"
  local expected_count
  local actual_count
  expected_count="$(manifest_value database_count)"
  actual_count="$(
    docker exec "${RESTORE_CONTAINER}" \
      psql --no-psqlrc --tuples-only --no-align \
        --username="${TARGET_ADMIN}" --dbname="${CONTROL_DB}" \
        --command="
          SELECT count(*)
          FROM pg_database
          WHERE datallowconn IS TRUE
            AND datistemplate IS FALSE
            AND datname <> '${CONTROL_DB}';
        "
  )"
  [[ "${actual_count}" == "${expected_count}" ]] ||
    fatal "Restored database count is ${actual_count}; expected ${expected_count}."

  docker exec "${RESTORE_CONTAINER}" \
    psql --no-psqlrc --set=ON_ERROR_STOP=1 \
      --username="${TARGET_ADMIN}" --dbname=postgres \
      --command="DROP DATABASE \"${CONTROL_DB}\";" >/dev/null
}

activate_restored_cluster() {
  log "Stopping isolated restore container"
  docker stop "${RESTORE_CONTAINER}" >/dev/null
  docker rm "${RESTORE_CONTAINER}" >/dev/null
  RESTORE_CONTAINER=""

  log "Starting target container with restored data"
  docker start "${TARGET_CONTAINER}" >/dev/null
  if ! wait_for_postgres "${TARGET_CONTAINER}"; then
    docker logs "${TARGET_CONTAINER}" --tail 200 >&2 || true
    fatal "Target container did not become ready after restoration."
  fi
  docker exec "${TARGET_CONTAINER}" \
    psql --no-psqlrc --set=ON_ERROR_STOP=1 \
      --username="${TARGET_ADMIN}" --dbname=postgres \
      --command='SELECT 1;' >/dev/null
}

main() {
  parse_arguments "$@"
  validate_options
  check_dependencies
  prepare_backup
  verify_backup
  inspect_target
  confirm_restore

  trap cleanup EXIT INT TERM
  DESTRUCTIVE_PHASE_STARTED=true
  erase_target_cluster
  start_isolated_cluster
  create_control_database
  restore_globals
  restore_databases
  verify_restored_cluster
  activate_restored_cluster
  DESTRUCTIVE_PHASE_STARTED=false

  printf '\n'
  log "PostgreSQL cluster replacement completed successfully"
  printf 'Container:  %s\n' "${TARGET_CONTAINER}"
  printf 'Backup ID: %s\n' "$(manifest_value backup_id)"
  printf 'Databases: %s\n' "$(manifest_value database_count)"
}

main "$@"
