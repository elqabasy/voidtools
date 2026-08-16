#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
shopt -s extglob

readonly SCRIPT_NAME="${VPG_PROGRAM:-$(basename -- "$0")}"

readonly DEFAULT_POSTGRES_CONTAINER="infra_postgres"
readonly DEFAULT_ENV_FILE=".env"
readonly DEFAULT_POSTGRES_USER="postgres"
readonly DEFAULT_POSTGRES_HOST="127.0.0.1"
readonly DEFAULT_POSTGRES_PORT="5432"
readonly DEFAULT_POSTGRES_DB="postgres"
readonly DEFAULT_COMPRESSION="6"
readonly READ_ONLY_PGOPTIONS="-c default_transaction_read_only=on"

POSTGRES_CONTAINER="${DEFAULT_POSTGRES_CONTAINER}"
OUTPUT_ROOT=""

ENV_FILE="${DEFAULT_ENV_FILE}"
ENV_FILE_EXPLICIT=false

POSTGRES_USERNAME=""
POSTGRES_PASSWORD_VALUE=""
POSTGRES_HOST_VALUE=""
POSTGRES_PORT_VALUE=""
POSTGRES_DATABASE=""

COMPRESSION_LEVEL=""
CREATE_ARCHIVE=false
INCLUDE_ROLE_PASSWORDS=false
INCLUDE_TABLESPACES=false
VERBOSE=false
ALLOW_INSECURE_PERMISSIONS=false

PASSWORD_SOURCE="none"
PASSWORD_FILE=""
READ_PASSWORD_FROM_STDIN=false
CLI_PASSWORD_MODE=""

TIMESTAMP=""
BACKUP_ID=""
BACKUP_DIR=""
FINAL_BACKUP_DIR=""
ARCHIVE_FILE=""
TEMP_ARCHIVE_FILE=""

DIRECTORY_COMPLETE=false

declare -A DOTENV_VALUES=()

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} <output_directory> [options]
  ${SCRIPT_NAME} <postgres_container_name> <output_directory> [options]

Positional arguments:
  output_directory
      Secure directory where backups will be stored.

  postgres_container_name
      Optional legacy positional container name or ID.
      Default container: ${DEFAULT_POSTGRES_CONTAINER}

Configuration precedence:
  1. CLI options
  2. Current process environment
  3. .env file
  4. Built-in defaults

Credential options:
  --env-file <path>
      Load configuration from a dotenv file.
      Default: ./.env when it exists.

  --username <username>
      Override POSTGRES_USER.

  --password <password>
      Override POSTGRES_PASSWORD.

      Warning:
      This may expose the password through shell history or process arguments.
      Prefer --password-file or --password-stdin.

  --password-file <path>
      Read the PostgreSQL password from a protected file.

  --password-stdin
      Read the PostgreSQL password from standard input.

Connection options:
  --container <name>
      Running PostgreSQL Docker container name or ID.
      Default: ${DEFAULT_POSTGRES_CONTAINER}

  --host <host>
      Override POSTGRES_HOST.
      Default: ${DEFAULT_POSTGRES_HOST}

  --port <port>
      Override POSTGRES_PORT.
      Default: ${DEFAULT_POSTGRES_PORT}

  --maintenance-db <database>
      Override POSTGRES_DB.
      Default: ${DEFAULT_POSTGRES_DB}

Backup options:
  --compression <0-9>
      PostgreSQL custom-format compression level.
      Default: ${DEFAULT_COMPRESSION}

  --archive
      Also create a .tar.gz archive.
      The backup directory remains available.

  --no-archive
      Disable archive creation.

  --include-role-passwords
      Include PostgreSQL role password hashes in globals.sql.
      Disabled by default.

  --include-tablespaces
      Include PostgreSQL tablespace definitions.
      Disabled by default.

  --verbose
      Enable verbose PostgreSQL backup output.

  --allow-insecure-permissions
      Allow group/other-readable env files and group/other-writable
      output directories. Prefer fixing permissions instead.

  -h, --help
      Show this help.

Supported .env variables:
  POSTGRES_USER
  POSTGRES_PASSWORD
  POSTGRES_HOST
  POSTGRES_PORT
  POSTGRES_DB
  BACKUP_COMPRESSION
  BACKUP_CREATE_ARCHIVE
  BACKUP_INCLUDE_ROLE_PASSWORDS
  BACKUP_INCLUDE_TABLESPACES

Examples:
  ${SCRIPT_NAME} ./postgres/backups

  ${SCRIPT_NAME} --container reporting_postgres ./postgres/backups

  ${SCRIPT_NAME} infra_postgres /srv/backups/postgres \\
    --env-file /srv/secrets/postgres-backup.env \\
    --archive

  ${SCRIPT_NAME} infra_postgres /srv/backups/postgres \\
    --username backup_user \\
    --password-file /run/secrets/postgres_backup_password \\
    --archive

  printf '%s\n' "\${POSTGRES_BACKUP_PASSWORD}" | \\
    ${SCRIPT_NAME} infra_postgres /srv/backups/postgres \\
      --username backup_user \\
      --password-stdin
EOF
}

log() {
  printf '[%s] %s\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    "$*"
}

fatal() {
  printf '[%s] ERROR: %s\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    "$*" >&2

  exit 1
}

on_error() {
  local exit_code=$?
  local line_number="${1:-unknown}"

  printf '\nBackup operation failed at line %s with exit code %s.\n' \
    "${line_number}" \
    "${exit_code}" >&2

  if [[ "${DIRECTORY_COMPLETE}" == false ]] &&
     [[ -n "${BACKUP_DIR}" ]] &&
     [[ -d "${BACKUP_DIR}" ]]; then

    {
      printf 'status=failed\n'
      printf 'failed_at=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
      printf 'exit_code=%s\n' "${exit_code}"
      printf 'line=%s\n' "${line_number}"
    } > "${BACKUP_DIR}/BACKUP_FAILED" 2>/dev/null || true

    chmod 0600 "${BACKUP_DIR}/BACKUP_FAILED" 2>/dev/null || true

    printf 'Incomplete backup preserved at:\n%s\n' \
      "${BACKUP_DIR}" >&2
  elif [[ "${DIRECTORY_COMPLETE}" == true ]]; then
    printf 'The backup directory completed successfully.\n' >&2

    if [[ -n "${FINAL_BACKUP_DIR}" ]]; then
      printf 'Completed backup directory:\n%s\n' \
        "${FINAL_BACKUP_DIR}" >&2
    fi

    if [[ -n "${TEMP_ARCHIVE_FILE}" ]] &&
       [[ -e "${TEMP_ARCHIVE_FILE}" ]]; then
      printf 'Incomplete archive preserved at:\n%s\n' \
        "${TEMP_ARCHIVE_FILE}" >&2
    fi
  fi

  POSTGRES_PASSWORD_VALUE=""
  exit "${exit_code}"
}

on_signal() {
  local signal_name="$1"

  printf '\nReceived signal: %s\n' "${signal_name}" >&2
  exit 130
}

trap 'on_error "$LINENO"' ERR
trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

trim_whitespace() {
  local value="$1"

  value="${value##+([[:space:]])}"
  value="${value%%+([[:space:]])}"

  printf '%s' "${value}"
}

require_command() {
  local command_name="$1"

  command -v "${command_name}" >/dev/null 2>&1 ||
    fatal "Required command not found: ${command_name}"
}

require_option_value() {
  local option_name="$1"
  local argument_count="$2"

  (( argument_count >= 2 )) ||
    fatal "Missing value for ${option_name}."
}

parse_boolean() {
  local value="${1,,}"

  case "${value}" in
    1|true|yes|on)
      printf 'true'
      ;;

    0|false|no|off|'')
      printf 'false'
      ;;

    *)
      fatal "Invalid boolean value: ${1}"
      ;;
  esac
}

parse_dotenv_value() {
  local value
  value="$(trim_whitespace "$1")"

  if [[ "${value}" == \"* ]]; then
    [[ "${value}" == *\" ]] ||
      fatal "Unterminated double-quoted value in environment file."

    value="${value:1:${#value}-2}"

  elif [[ "${value}" == \'* ]]; then
    [[ "${value}" == *\' ]] ||
      fatal "Unterminated single-quoted value in environment file."

    value="${value:1:${#value}-2}"

  else
    value="$(trim_whitespace "${value}")"
  fi

  printf '%s' "${value}"
}

load_dotenv() {
  local file="$1"

  [[ -f "${file}" ]] ||
    fatal "Environment file is not a regular file: ${file}"

  [[ ! -L "${file}" ]] ||
    fatal "Environment file must not be a symbolic link: ${file}"

  local owner_uid
  local current_uid
  local mode
  local mode_decimal

  owner_uid="$(stat -c '%u' -- "${file}")"
  current_uid="$(id -u)"
  mode="$(stat -c '%a' -- "${file}")"
  mode_decimal=$((8#${mode}))

  if [[ "${ALLOW_INSECURE_PERMISSIONS}" == false ]]; then
    [[ "${owner_uid}" == "${current_uid}" ]] ||
      fatal \
        "Environment file must be owned by UID ${current_uid}; current owner is UID ${owner_uid}."

    if (( mode_decimal & 0077 )); then
      fatal \
        "Environment file must not be accessible by group or others: ${file} (mode ${mode})"
    fi
  fi

  local line
  local line_number=0
  local key
  local raw_value
  local parsed_value

  while IFS= read -r line || [[ -n "${line}" ]]; do
    ((line_number += 1))

    line="${line%$'\r'}"
    line="$(trim_whitespace "${line}")"

    [[ -n "${line}" ]] || continue
    [[ "${line}" != \#* ]] || continue

    if [[ "${line}" == export[[:space:]]* ]]; then
      line="${line#export}"
      line="$(trim_whitespace "${line}")"
    fi

    [[ "${line}" == *=* ]] ||
      fatal \
        "Invalid dotenv entry at ${file}:${line_number}; expected KEY=VALUE."

    key="${line%%=*}"
    raw_value="${line#*=}"

    key="$(trim_whitespace "${key}")"

    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
      fatal \
        "Invalid dotenv variable name at ${file}:${line_number}: ${key}"

    parsed_value="$(parse_dotenv_value "${raw_value}")"

    case "${key}" in
      POSTGRES_USER|\
      POSTGRES_PASSWORD|\
      POSTGRES_HOST|\
      POSTGRES_PORT|\
      POSTGRES_DB|\
      BACKUP_COMPRESSION|\
      BACKUP_CREATE_ARCHIVE|\
      BACKUP_INCLUDE_ROLE_PASSWORDS|\
      BACKUP_INCLUDE_TABLESPACES)
        DOTENV_VALUES["${key}"]="${parsed_value}"
        ;;

      *)
        # Unrelated variables are intentionally ignored.
        ;;
    esac
  done < "${file}"
}

get_config_value() {
  local environment_name="$1"
  local dotenv_name="$2"
  local default_value="$3"

  if [[ -n "${!environment_name+x}" ]]; then
    printf '%s' "${!environment_name}"

  elif [[ -n "${DOTENV_VALUES[${dotenv_name}]+x}" ]]; then
    printf '%s' "${DOTENV_VALUES[${dotenv_name}]}"

  else
    printf '%s' "${default_value}"
  fi
}

discover_env_file() {
  local -a arguments=("$@")
  local index=0

  while (( index < ${#arguments[@]} )); do
    case "${arguments[index]}" in
      --env-file)
        (( index + 1 < ${#arguments[@]} )) ||
          fatal "Missing value for --env-file."

        ENV_FILE="${arguments[index + 1]}"
        ENV_FILE_EXPLICIT=true
        ((index += 2))
        ;;

      --env-file=*)
        ENV_FILE="${arguments[index]#--env-file=}"
        ENV_FILE_EXPLICIT=true
        ((index += 1))
        ;;

      *)
        ((index += 1))
        ;;
    esac
  done
}

initialize_configuration() {
  if [[ "${ENV_FILE_EXPLICIT}" == true ]]; then
    load_dotenv "${ENV_FILE}"

  elif [[ -f "${ENV_FILE}" ]]; then
    load_dotenv "${ENV_FILE}"
  fi

  POSTGRES_USERNAME="$(
    get_config_value \
      POSTGRES_USER \
      POSTGRES_USER \
      "${DEFAULT_POSTGRES_USER}"
  )"

  POSTGRES_PASSWORD_VALUE="$(
    get_config_value \
      POSTGRES_PASSWORD \
      POSTGRES_PASSWORD \
      ""
  )"

  POSTGRES_HOST_VALUE="$(
    get_config_value \
      POSTGRES_HOST \
      POSTGRES_HOST \
      "${DEFAULT_POSTGRES_HOST}"
  )"

  POSTGRES_PORT_VALUE="$(
    get_config_value \
      POSTGRES_PORT \
      POSTGRES_PORT \
      "${DEFAULT_POSTGRES_PORT}"
  )"

  POSTGRES_DATABASE="$(
    get_config_value \
      POSTGRES_DB \
      POSTGRES_DB \
      "${DEFAULT_POSTGRES_DB}"
  )"

  COMPRESSION_LEVEL="$(
    get_config_value \
      BACKUP_COMPRESSION \
      BACKUP_COMPRESSION \
      "${DEFAULT_COMPRESSION}"
  )"

  CREATE_ARCHIVE="$(
    parse_boolean "$(
      get_config_value \
        BACKUP_CREATE_ARCHIVE \
        BACKUP_CREATE_ARCHIVE \
        "false"
    )"
  )"

  INCLUDE_ROLE_PASSWORDS="$(
    parse_boolean "$(
      get_config_value \
        BACKUP_INCLUDE_ROLE_PASSWORDS \
        BACKUP_INCLUDE_ROLE_PASSWORDS \
        "false"
    )"
  )"

  INCLUDE_TABLESPACES="$(
    parse_boolean "$(
      get_config_value \
        BACKUP_INCLUDE_TABLESPACES \
        BACKUP_INCLUDE_TABLESPACES \
        "false"
    )"
  )"

  if [[ -n "${POSTGRES_PASSWORD_VALUE}" ]]; then
    if [[ -n "${POSTGRES_PASSWORD+x}" ]]; then
      PASSWORD_SOURCE="process-environment"
    else
      PASSWORD_SOURCE="dotenv"
    fi
  fi
}

set_cli_password_mode() {
  local requested_mode="$1"

  if [[ -n "${CLI_PASSWORD_MODE}" ]] &&
     [[ "${CLI_PASSWORD_MODE}" != "${requested_mode}" ]]; then
    fatal \
      "Only one of --password, --password-file, or --password-stdin may be used."
  fi

  CLI_PASSWORD_MODE="${requested_mode}"
}

parse_arguments() {
  if (( $# < 1 )); then
    usage >&2
    exit 2
  fi

  discover_env_file "$@"
  initialize_configuration

  local -a positional_args=()

  while (( $# > 0 )); do
    case "$1" in
      --container)
        require_option_value "$1" "$#"
        POSTGRES_CONTAINER="$2"
        shift 2
        ;;

      --container=*)
        POSTGRES_CONTAINER="${1#--container=}"
        shift
        ;;

      --env-file)
        require_option_value "$1" "$#"
        shift 2
        ;;

      --env-file=*)
        shift
        ;;

      --username)
        require_option_value "$1" "$#"
        POSTGRES_USERNAME="$2"
        shift 2
        ;;

      --username=*)
        POSTGRES_USERNAME="${1#--username=}"
        shift
        ;;

      --password)
        require_option_value "$1" "$#"
        set_cli_password_mode "command-line"

        POSTGRES_PASSWORD_VALUE="$2"
        PASSWORD_SOURCE="command-line"
        shift 2
        ;;

      --password=*)
        set_cli_password_mode "command-line"

        POSTGRES_PASSWORD_VALUE="${1#--password=}"
        PASSWORD_SOURCE="command-line"
        shift
        ;;

      --password-file)
        require_option_value "$1" "$#"
        set_cli_password_mode "password-file"

        PASSWORD_FILE="$2"
        PASSWORD_SOURCE="password-file"
        shift 2
        ;;

      --password-file=*)
        set_cli_password_mode "password-file"

        PASSWORD_FILE="${1#--password-file=}"
        PASSWORD_SOURCE="password-file"
        shift
        ;;

      --password-stdin)
        set_cli_password_mode "password-stdin"

        READ_PASSWORD_FROM_STDIN=true
        PASSWORD_SOURCE="password-stdin"
        shift
        ;;

      --host)
        require_option_value "$1" "$#"
        POSTGRES_HOST_VALUE="$2"
        shift 2
        ;;

      --host=*)
        POSTGRES_HOST_VALUE="${1#--host=}"
        shift
        ;;

      --port)
        require_option_value "$1" "$#"
        POSTGRES_PORT_VALUE="$2"
        shift 2
        ;;

      --port=*)
        POSTGRES_PORT_VALUE="${1#--port=}"
        shift
        ;;

      --maintenance-db)
        require_option_value "$1" "$#"
        POSTGRES_DATABASE="$2"
        shift 2
        ;;

      --maintenance-db=*)
        POSTGRES_DATABASE="${1#--maintenance-db=}"
        shift
        ;;

      --compression)
        require_option_value "$1" "$#"
        COMPRESSION_LEVEL="$2"
        shift 2
        ;;

      --compression=*)
        COMPRESSION_LEVEL="${1#--compression=}"
        shift
        ;;

      --archive)
        CREATE_ARCHIVE=true
        shift
        ;;

      --no-archive)
        CREATE_ARCHIVE=false
        shift
        ;;

      --include-role-passwords)
        INCLUDE_ROLE_PASSWORDS=true
        shift
        ;;

      --include-tablespaces)
        INCLUDE_TABLESPACES=true
        shift
        ;;

      --verbose)
        VERBOSE=true
        shift
        ;;

      --allow-insecure-permissions)
        ALLOW_INSECURE_PERMISSIONS=true
        shift
        ;;

      -h|--help)
        usage
        exit 0
        ;;

      --)
        shift
        while (( $# > 0 )); do
          positional_args+=("$1")
          shift
        done
        ;;

      -*)
        fatal "Unknown option: $1"
        ;;

      *)
        positional_args+=("$1")
        shift
        ;;
    esac
  done

  case "${#positional_args[@]}" in
    1)
      OUTPUT_ROOT="${positional_args[0]}"
      ;;

    2)
      POSTGRES_CONTAINER="${positional_args[0]}"
      OUTPUT_ROOT="${positional_args[1]}"
      ;;

    *)
      usage >&2
      fatal \
        "Expected <output_directory> or <postgres_container_name> <output_directory>."
      ;;
  esac
}

read_password_file() {
  local file="$1"

  [[ -f "${file}" ]] ||
    fatal "Password file is not a regular file: ${file}"

  [[ ! -L "${file}" ]] ||
    fatal "Password file must not be a symbolic link: ${file}"

  local owner_uid
  local current_uid
  local mode
  local mode_decimal

  owner_uid="$(stat -c '%u' -- "${file}")"
  current_uid="$(id -u)"
  mode="$(stat -c '%a' -- "${file}")"
  mode_decimal=$((8#${mode}))

  [[ "${owner_uid}" == "${current_uid}" ]] ||
    fatal \
      "Password file must be owned by UID ${current_uid}; current owner is UID ${owner_uid}."

  if (( mode_decimal & 0077 )); then
    fatal \
      "Password file must not be accessible by group or others: ${file} (mode ${mode})"
  fi

  IFS= read -r POSTGRES_PASSWORD_VALUE < "${file}" || true
  POSTGRES_PASSWORD_VALUE="${POSTGRES_PASSWORD_VALUE%$'\r'}"

  [[ -n "${POSTGRES_PASSWORD_VALUE}" ]] ||
    fatal "Password file is empty: ${file}"
}

resolve_password() {
  case "${CLI_PASSWORD_MODE}" in
    password-file)
      read_password_file "${PASSWORD_FILE}"
      ;;

    password-stdin)
      IFS= read -r POSTGRES_PASSWORD_VALUE || true
      POSTGRES_PASSWORD_VALUE="${POSTGRES_PASSWORD_VALUE%$'\r'}"

      [[ -n "${POSTGRES_PASSWORD_VALUE}" ]] ||
        fatal "No password was received from standard input."
      ;;

    command-line|'')
      ;;
  esac

  if [[ "${POSTGRES_PASSWORD_VALUE}" == *$'\n'* ]] ||
     [[ "${POSTGRES_PASSWORD_VALUE}" == *$'\r'* ]]; then
    fatal "PostgreSQL password must not contain newline characters."
  fi
}

validate_configuration() {
  [[ -n "${POSTGRES_CONTAINER}" ]] ||
    fatal "Container name cannot be empty."

  [[ "${POSTGRES_CONTAINER}" != -* ]] ||
    fatal "Container name cannot start with '-'."

  [[ -n "${OUTPUT_ROOT}" ]] ||
    fatal "Output directory cannot be empty."

  [[ -n "${POSTGRES_USERNAME}" ]] ||
    fatal "PostgreSQL username cannot be empty."

  [[ -n "${POSTGRES_HOST_VALUE}" ]] ||
    fatal "PostgreSQL host cannot be empty."

  [[ "${POSTGRES_PORT_VALUE}" =~ ^[0-9]+$ ]] ||
    fatal "PostgreSQL port must be numeric."

  (( POSTGRES_PORT_VALUE >= 1 && POSTGRES_PORT_VALUE <= 65535 )) ||
    fatal "PostgreSQL port must be between 1 and 65535."

  [[ -n "${POSTGRES_DATABASE}" ]] ||
    fatal "Maintenance database cannot be empty."

  [[ "${COMPRESSION_LEVEL}" =~ ^[0-9]$ ]] ||
    fatal "Compression must be an integer between 0 and 9."

  local value

  for value in \
    "${POSTGRES_CONTAINER}" \
    "${OUTPUT_ROOT}" \
    "${POSTGRES_USERNAME}" \
    "${POSTGRES_HOST_VALUE}" \
    "${POSTGRES_DATABASE}"
  do
    if [[ "${value}" =~ [[:cntrl:]] ]]; then
      fatal "Configuration contains prohibited control characters."
    fi
  done
}

check_dependencies() {
  require_command docker
  require_command install
  require_command realpath
  require_command stat
  require_command sha256sum
  require_command base64
  require_command mktemp
  require_command find
  require_command sort
  require_command awk
  require_command date
  require_command hostname
  require_command mv
  require_command chmod

  docker info >/dev/null 2>&1 ||
    fatal "Docker daemon is unavailable or the current user cannot access it."

  if [[ "${CREATE_ARCHIVE}" == true ]]; then
    require_command tar
    require_command gzip
  fi
}

prepare_output_root() {
  if [[ -L "${OUTPUT_ROOT}" ]]; then
    fatal "Output directory must not be a symbolic link: ${OUTPUT_ROOT}"
  fi

  if [[ -e "${OUTPUT_ROOT}" ]] &&
     [[ ! -d "${OUTPUT_ROOT}" ]]; then
    fatal "Output path exists but is not a directory: ${OUTPUT_ROOT}"
  fi

  if [[ ! -e "${OUTPUT_ROOT}" ]]; then
    install -d -m 0700 -- "${OUTPUT_ROOT}"
  fi

  OUTPUT_ROOT="$(realpath -e -- "${OUTPUT_ROOT}")"

  [[ -d "${OUTPUT_ROOT}" ]] ||
    fatal "Output path is not a directory: ${OUTPUT_ROOT}"

  [[ ! -L "${OUTPUT_ROOT}" ]] ||
    fatal "Resolved output directory must not be a symbolic link."

  [[ -w "${OUTPUT_ROOT}" ]] ||
    fatal "Output directory is not writable: ${OUTPUT_ROOT}"

  [[ -x "${OUTPUT_ROOT}" ]] ||
    fatal "Output directory is not searchable: ${OUTPUT_ROOT}"

  local owner_uid
  local current_uid
  local permissions
  local permissions_decimal

  owner_uid="$(stat -c '%u' -- "${OUTPUT_ROOT}")"
  current_uid="$(id -u)"
  permissions="$(stat -c '%a' -- "${OUTPUT_ROOT}")"
  permissions_decimal=$((8#${permissions}))

  [[ "${owner_uid}" == "${current_uid}" ]] ||
    fatal \
      "Output directory must be owned by UID ${current_uid}; current owner is UID ${owner_uid}."

  if [[ "${ALLOW_INSECURE_PERMISSIONS}" == false ]]; then
    if (( permissions_decimal & 0022 )); then
      fatal \
        "Output directory must not be writable by group or others: ${OUTPUT_ROOT} (mode ${permissions})"
    fi
  fi
}

docker_pg_exec() {
  if [[ -n "${POSTGRES_PASSWORD_VALUE}" ]]; then
    PGPASSWORD="${POSTGRES_PASSWORD_VALUE}" \
    PGOPTIONS="${READ_ONLY_PGOPTIONS}" \
      docker exec \
        --env PGPASSWORD \
        --env PGOPTIONS \
        "${POSTGRES_CONTAINER}" \
        "$@"
  else
    PGOPTIONS="${READ_ONLY_PGOPTIONS}" \
      docker exec \
        --env PGOPTIONS \
        "${POSTGRES_CONTAINER}" \
        "$@"
  fi
}

check_container() {
  docker inspect \
    --type container \
    "${POSTGRES_CONTAINER}" >/dev/null 2>&1 ||
    fatal "Container not found: ${POSTGRES_CONTAINER}"

  local running
  local paused

  running="$(
    docker inspect \
      --format '{{.State.Running}}' \
      "${POSTGRES_CONTAINER}"
  )"

  paused="$(
    docker inspect \
      --format '{{.State.Paused}}' \
      "${POSTGRES_CONTAINER}"
  )"

  [[ "${running}" == "true" ]] ||
    fatal "Container is not running: ${POSTGRES_CONTAINER}"

  [[ "${paused}" == "false" ]] ||
    fatal "Container is paused: ${POSTGRES_CONTAINER}"

  docker exec "${POSTGRES_CONTAINER}" \
    pg_isready --version >/dev/null 2>&1 ||
    fatal "pg_isready is not available in the container."

  docker exec "${POSTGRES_CONTAINER}" \
    psql --version >/dev/null 2>&1 ||
    fatal "psql is not available in the container."

  docker exec "${POSTGRES_CONTAINER}" \
    pg_dump --version >/dev/null 2>&1 ||
    fatal "pg_dump is not available in the container."

  docker exec "${POSTGRES_CONTAINER}" \
    pg_dumpall --version >/dev/null 2>&1 ||
    fatal "pg_dumpall is not available in the container."

  docker exec "${POSTGRES_CONTAINER}" \
    pg_restore --version >/dev/null 2>&1 ||
    fatal "pg_restore is not available in the container."

  docker exec "${POSTGRES_CONTAINER}" \
    postgres --version >/dev/null 2>&1 ||
    fatal "postgres is not available in the container."
}

check_postgresql() {
  log "Checking PostgreSQL availability"

  docker_pg_exec \
    pg_isready \
      --host="${POSTGRES_HOST_VALUE}" \
      --port="${POSTGRES_PORT_VALUE}" \
      --username="${POSTGRES_USERNAME}" \
      --dbname="${POSTGRES_DATABASE}" \
      --timeout=10 >/dev/null

  log "Verifying read-only PostgreSQL connection"

  local connection_result

  connection_result="$(
    docker_pg_exec \
      psql \
        --host="${POSTGRES_HOST_VALUE}" \
        --port="${POSTGRES_PORT_VALUE}" \
        --username="${POSTGRES_USERNAME}" \
        --dbname="${POSTGRES_DATABASE}" \
        --no-password \
        --no-psqlrc \
        --set=ON_ERROR_STOP=1 \
        --tuples-only \
        --no-align \
        --command="
          SELECT
            current_setting('default_transaction_read_only'),
            1;
        "
  )"

  [[ "${connection_result}" == "on|1" ]] ||
    fatal \
      "PostgreSQL read-only session validation failed. Received: ${connection_result}"
}

create_backup_directory() {
  TIMESTAMP="$(date -u +'%Y-%m-%d_%H-%M-%S_UTC')"

  BACKUP_DIR="$(
    mktemp \
      --directory \
      --tmpdir="${OUTPUT_ROOT}" \
      --suffix=".incomplete" \
      ".postgres_cluster_${TIMESTAMP}_XXXXXXXX"
  )"

  chmod 0700 -- "${BACKUP_DIR}"

  local temporary_name
  temporary_name="$(basename -- "${BACKUP_DIR}")"

  BACKUP_ID="${temporary_name#.}"
  BACKUP_ID="${BACKUP_ID%.incomplete}"

  FINAL_BACKUP_DIR="${OUTPUT_ROOT}/${BACKUP_ID}"

  [[ ! -e "${FINAL_BACKUP_DIR}" ]] ||
    fatal "Final backup directory already exists: ${FINAL_BACKUP_DIR}"
}

get_server_value() {
  local query="$1"

  docker_pg_exec \
    psql \
      --host="${POSTGRES_HOST_VALUE}" \
      --port="${POSTGRES_PORT_VALUE}" \
      --username="${POSTGRES_USERNAME}" \
      --dbname="${POSTGRES_DATABASE}" \
      --no-password \
      --no-psqlrc \
      --set=ON_ERROR_STOP=1 \
      --tuples-only \
      --no-align \
      --command="${query}"
}

write_initial_manifest() {
  local container_image
  local container_id
  local postgres_binary_version
  local postgres_server_version
  local system_identifier
  local host_name
  local password_supplied=false

  container_image="$(
    docker inspect \
      --format '{{.Config.Image}}' \
      "${POSTGRES_CONTAINER}"
  )"

  container_id="$(
    docker inspect \
      --format '{{.Id}}' \
      "${POSTGRES_CONTAINER}"
  )"

  postgres_binary_version="$(
    docker exec "${POSTGRES_CONTAINER}" postgres --version
  )"

  postgres_server_version="$(
    get_server_value "SHOW server_version;"
  )"

  system_identifier="$(
    get_server_value \
      "SELECT system_identifier FROM pg_control_system();"
  )"

  host_name="$(hostname --fqdn 2>/dev/null || hostname)"

  if [[ -n "${POSTGRES_PASSWORD_VALUE}" ]]; then
    password_supplied=true
  fi

  {
    printf 'backup_format_version=1\n'
    printf 'status=incomplete\n'
    printf 'backup_type=logical-postgresql-cluster\n'
    printf 'backup_id=%s\n' "${BACKUP_ID}"
    printf 'started_at=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf 'backup_host=%s\n' "${host_name}"
    printf 'container_name=%s\n' "${POSTGRES_CONTAINER}"
    printf 'container_id=%s\n' "${container_id}"
    printf 'container_image=%s\n' "${container_image}"
    printf 'postgres_binary_version=%s\n' "${postgres_binary_version}"
    printf 'postgres_server_version=%s\n' "${postgres_server_version}"
    printf 'postgres_system_identifier=%s\n' "${system_identifier}"
    printf 'connection_host=%s\n' "${POSTGRES_HOST_VALUE}"
    printf 'connection_port=%s\n' "${POSTGRES_PORT_VALUE}"
    printf 'backup_username=%s\n' "${POSTGRES_USERNAME}"
    printf 'maintenance_database=%s\n' "${POSTGRES_DATABASE}"
    printf 'compression_level=%s\n' "${COMPRESSION_LEVEL}"
    printf 'credential_source=%s\n' "${PASSWORD_SOURCE}"
    printf 'password_authentication_supplied=%s\n' "${password_supplied}"
    printf 'role_passwords_included=%s\n' "${INCLUDE_ROLE_PASSWORDS}"
    printf 'tablespaces_included=%s\n' "${INCLUDE_TABLESPACES}"
    printf 'read_only_session_enforced=true\n'
    printf 'database_filename_strategy=ordinal\n'
    printf 'database_name_encoding=base64\n'
    printf 'existing_files_overwritten=false\n'
    printf 'database_restore_performed=false\n'
    printf 'database_mutation_performed=false\n'
  } > "${BACKUP_DIR}/manifest.txt"

  chmod 0600 -- "${BACKUP_DIR}/manifest.txt"
}

dump_globals() {
  log "Backing up cluster globals"

  local -a global_options=(
    pg_dumpall
    "--host=${POSTGRES_HOST_VALUE}"
    "--port=${POSTGRES_PORT_VALUE}"
    "--username=${POSTGRES_USERNAME}"
    --no-password
    --globals-only
  )

  if [[ "${INCLUDE_ROLE_PASSWORDS}" == false ]]; then
    global_options+=(--no-role-passwords)
  fi

  if [[ "${INCLUDE_TABLESPACES}" == false ]]; then
    global_options+=(--no-tablespaces)
  fi

  if [[ "${VERBOSE}" == true ]]; then
    global_options+=(--verbose)
  fi

  docker_pg_exec "${global_options[@]}" \
    > "${BACKUP_DIR}/globals.sql"

  [[ -s "${BACKUP_DIR}/globals.sql" ]] ||
    fatal "Cluster globals backup is empty."

  chmod 0600 -- "${BACKUP_DIR}/globals.sql"
}

read_database_list() {
  log "Reading connectable database list"

  local list_file="${BACKUP_DIR}/database-names.base64"

  docker_pg_exec \
    psql \
      --host="${POSTGRES_HOST_VALUE}" \
      --port="${POSTGRES_PORT_VALUE}" \
      --username="${POSTGRES_USERNAME}" \
      --dbname="${POSTGRES_DATABASE}" \
      --no-password \
      --no-psqlrc \
      --set=ON_ERROR_STOP=1 \
      --tuples-only \
      --no-align \
      --command="
        SELECT replace(
          encode(convert_to(datname, 'UTF8'), 'base64'),
          E'\n',
          ''
        )
        FROM pg_database
        WHERE datallowconn IS TRUE
          AND datistemplate IS FALSE
        ORDER BY datname;
      " > "${list_file}"

  chmod 0600 -- "${list_file}"

  [[ -s "${list_file}" ]] ||
    fatal "No connectable non-template databases were found."

  local invalid_line

  invalid_line="$(
    awk '
      NF == 0 || $0 !~ /^[A-Za-z0-9+\/=]+$/ {
        print NR
        exit
      }
    ' "${list_file}"
  )"

  [[ -z "${invalid_line}" ]] ||
    fatal "Invalid encoded database name at line ${invalid_line}."
}

dump_databases() {
  local list_file="${BACKUP_DIR}/database-names.base64"
  local map_file="${BACKUP_DIR}/database-map.tsv"

  printf 'dump_file\tdatabase_name_base64\n' > "${map_file}"
  chmod 0600 -- "${map_file}"

  local encoded_database
  local database
  local dump_file
  local database_index=0

  while IFS= read -r encoded_database; do
    [[ -n "${encoded_database}" ]] || continue

    if ! database="$(
      printf '%s' "${encoded_database}" |
        base64 --decode
    )"; then
      fatal "Unable to decode a database name."
    fi

    [[ -n "${database}" ]] ||
      fatal "Decoded database name is empty."

    ((database_index += 1))

    printf -v dump_file \
      'database_%04d.dump' \
      "${database_index}"

    printf '%s\t%s\n' \
      "${dump_file}" \
      "${encoded_database}" \
      >> "${map_file}"

    log "Backing up database #${database_index}"

    local -a dump_options=(
      pg_dump
      "--host=${POSTGRES_HOST_VALUE}"
      "--port=${POSTGRES_PORT_VALUE}"
      "--username=${POSTGRES_USERNAME}"
      "--dbname=${database}"
      --no-password
      --format=custom
      "--compress=${COMPRESSION_LEVEL}"
    )

    if [[ "${VERBOSE}" == true ]]; then
      dump_options+=(--verbose)
    fi

    docker_pg_exec "${dump_options[@]}" \
      > "${BACKUP_DIR}/${dump_file}"

    [[ -s "${BACKUP_DIR}/${dump_file}" ]] ||
      fatal "Database dump is empty: ${dump_file}"

    chmod 0600 -- "${BACKUP_DIR}/${dump_file}"

    log "Validating database archive #${database_index}"

    docker exec -i "${POSTGRES_CONTAINER}" \
      pg_restore \
        --list \
      < "${BACKUP_DIR}/${dump_file}" \
      > /dev/null

  done < "${list_file}"

  (( database_index > 0 )) ||
    fatal "No databases were backed up."

  printf 'database_count=%d\n' "${database_index}" \
    >> "${BACKUP_DIR}/manifest.txt"
}

validate_backup_structure() {
  log "Validating backup filesystem structure"

  local unexpected_entry

  unexpected_entry="$(
    find "${BACKUP_DIR}" \
      -mindepth 1 \
      -maxdepth 1 \
      ! -type f \
      -print \
      -quit
  )"

  [[ -z "${unexpected_entry}" ]] ||
    fatal "Unexpected non-regular backup entry: ${unexpected_entry}"

  local empty_dump

  empty_dump="$(
    find "${BACKUP_DIR}" \
      -mindepth 1 \
      -maxdepth 1 \
      -type f \
      -name 'database_*.dump' \
      -size 0 \
      -print \
      -quit
  )"

  [[ -z "${empty_dump}" ]] ||
    fatal "Empty dump file found: ${empty_dump}"

  [[ -s "${BACKUP_DIR}/globals.sql" ]] ||
    fatal "globals.sql is missing or empty."

  [[ -s "${BACKUP_DIR}/database-map.tsv" ]] ||
    fatal "database-map.tsv is missing or empty."

  [[ -s "${BACKUP_DIR}/manifest.txt" ]] ||
    fatal "manifest.txt is missing or empty."
}

finalize_manifest() {
  {
    printf 'completed_at=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf 'status=complete\n'
  } >> "${BACKUP_DIR}/manifest.txt"
}

write_file_inventory() {
  log "Generating backup file inventory"

  (
    cd -- "${BACKUP_DIR}"

    find . \
      -mindepth 1 \
      -maxdepth 1 \
      -type f \
      ! -name 'FILES.txt' \
      ! -name 'SHA256SUMS' \
      ! -name 'BACKUP_COMPLETE' \
      ! -name 'BACKUP_FAILED' \
      -printf '%f\n' |
      LC_ALL=C sort \
      > FILES.txt
  )

  chmod 0600 -- "${BACKUP_DIR}/FILES.txt"
}

generate_checksums() {
  log "Generating SHA-256 checksums"

  (
    cd -- "${BACKUP_DIR}"

    : > SHA256SUMS

    while IFS= read -r file; do
      [[ -f "${file}" ]] ||
        fatal "Inventory entry is not a regular file: ${file}"

      sha256sum -- "${file}" >> SHA256SUMS
    done < FILES.txt

    sha256sum -- FILES.txt >> SHA256SUMS
  )

  chmod 0600 -- "${BACKUP_DIR}/SHA256SUMS"
}

validate_checksums() {
  log "Validating SHA-256 checksums"

  (
    cd -- "${BACKUP_DIR}"
    sha256sum --check --strict -- SHA256SUMS
  )
}

write_completion_marker() {
  {
    printf 'backup_id=%s\n' "${BACKUP_ID}"
    printf 'completed_at=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf 'status=complete\n'
    printf 'checksum_file=SHA256SUMS\n'
  } > "${BACKUP_DIR}/BACKUP_COMPLETE"

  chmod 0600 -- "${BACKUP_DIR}/BACKUP_COMPLETE"
}

complete_backup_directory() {
  log "Completing backup directory"

  [[ ! -e "${FINAL_BACKUP_DIR}" ]] ||
    fatal "Final backup path already exists: ${FINAL_BACKUP_DIR}"

  mv -- "${BACKUP_DIR}" "${FINAL_BACKUP_DIR}"

  BACKUP_DIR="${FINAL_BACKUP_DIR}"
  DIRECTORY_COMPLETE=true
}

create_archive() {
  [[ "${CREATE_ARCHIVE}" == true ]] || return 0

  ARCHIVE_FILE="${FINAL_BACKUP_DIR}.tar.gz"

  [[ ! -e "${ARCHIVE_FILE}" ]] ||
    fatal "Archive already exists: ${ARCHIVE_FILE}"

  TEMP_ARCHIVE_FILE="$(
    mktemp \
      --tmpdir="${OUTPUT_ROOT}" \
      --suffix=".tar.gz.incomplete" \
      ".${BACKUP_ID}_archive_XXXXXXXX"
  )"

  chmod 0600 -- "${TEMP_ARCHIVE_FILE}"

  log "Creating compressed archive"

  tar \
    --create \
    --gzip \
    --file="${TEMP_ARCHIVE_FILE}" \
    --directory="${OUTPUT_ROOT}" \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --mode='u+rwX,go-rwx' \
    -- \
    "$(basename -- "${FINAL_BACKUP_DIR}")"

  log "Validating compressed archive"

  gzip --test -- "${TEMP_ARCHIVE_FILE}"

  tar \
    --list \
    --gzip \
    --file="${TEMP_ARCHIVE_FILE}" \
    > /dev/null

  mv -- "${TEMP_ARCHIVE_FILE}" "${ARCHIVE_FILE}"
  TEMP_ARCHIVE_FILE=""

  chmod 0600 -- "${ARCHIVE_FILE}"

  sha256sum -- "${ARCHIVE_FILE}" \
    > "${ARCHIVE_FILE}.sha256"

  chmod 0600 -- "${ARCHIVE_FILE}.sha256"

  (
    cd -- "${OUTPUT_ROOT}"

    sha256sum \
      --check \
      --strict \
      -- "$(basename -- "${ARCHIVE_FILE}.sha256")"
  )
}

main() {
  parse_arguments "$@"
  resolve_password
  validate_configuration

  check_dependencies
  prepare_output_root
  check_container
  check_postgresql

  create_backup_directory
  write_initial_manifest

  dump_globals
  read_database_list
  dump_databases

  validate_backup_structure
  finalize_manifest
  write_file_inventory
  generate_checksums
  validate_checksums
  write_completion_marker
  complete_backup_directory
  create_archive

  POSTGRES_PASSWORD_VALUE=""

  trap - ERR HUP INT TERM

  printf '\n'
  log "Backup completed successfully"

  printf 'Backup directory: %s\n' "${FINAL_BACKUP_DIR}"

  if [[ "${CREATE_ARCHIVE}" == true ]]; then
    printf 'Archive:          %s\n' "${ARCHIVE_FILE}"
    printf 'Archive checksum: %s\n' "${ARCHIVE_FILE}.sha256"
  fi
}

main "$@"
