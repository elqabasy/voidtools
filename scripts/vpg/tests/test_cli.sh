#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly VPG="${TEST_ROOT}/vpg"
TEMP_DIRECTORY="$(mktemp -d)"
trap 'rm -rf -- "${TEMP_DIRECTORY}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    fail "command unexpectedly succeeded: $*"
  fi
}

bash "${VPG}" --help >/dev/null
[[ "$(bash "${VPG}" version)" == "vpg 1.0.0" ]] ||
  fail "version output is incorrect"
bash "${VPG}" help backup >/dev/null
bash "${VPG}" help restore >/dev/null
assert_fails bash "${VPG}" unknown-command

BACKUP="${TEMP_DIRECTORY}/postgres_cluster_test"
mkdir -m 0700 "${BACKUP}"
cat > "${BACKUP}/manifest.txt" <<'EOF'
backup_format_version=1
status=incomplete
backup_id=postgres_cluster_test
database_count=1
completed_at=2026-08-16T00:00:00Z
status=complete
EOF
printf '%s\n' '-- PostgreSQL globals' > "${BACKUP}/globals.sql"
printf 'dump_file\tdatabase_name_base64\n' > "${BACKUP}/database-map.tsv"
printf 'database_0001.dump\tcG9zdGdyZXM=\n' >> "${BACKUP}/database-map.tsv"
printf '%s\n' 'not-a-real-pg-dump' > "${BACKUP}/database_0001.dump"
printf '%s\n' \
  database-map.tsv \
  database_0001.dump \
  globals.sql \
  manifest.txt > "${BACKUP}/FILES.txt"
(
  cd -- "${BACKUP}"
  sha256sum -- database-map.tsv database_0001.dump globals.sql manifest.txt FILES.txt \
    > SHA256SUMS
)
printf '%s\n' 'status=complete' > "${BACKUP}/BACKUP_COMPLETE"

bash "${VPG}" verify "${BACKUP}" >/dev/null
bash "${VPG}" list "${TEMP_DIRECTORY}" | grep -q postgres_cluster_test ||
  fail "list did not include the valid backup"

tar --create --gzip --file="${BACKUP}.tar.gz" \
  --directory="${TEMP_DIRECTORY}" "$(basename -- "${BACKUP}")"
sha256sum -- "${BACKUP}.tar.gz" > "${BACKUP}.tar.gz.sha256"
bash "${VPG}" verify "${BACKUP}.tar.gz" >/dev/null

printf '%s\n' 'tampered' >> "${BACKUP}/globals.sql"
assert_fails bash "${VPG}" verify "${BACKUP}"

printf 'All VPG CLI tests passed.\n'
