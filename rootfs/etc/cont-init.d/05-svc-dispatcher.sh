#!/usr/bin/with-contenv bash
# shellcheck shell=bash
set -e

# From https://github.com/docker-library/mariadb/blob/master/docker-entrypoint.sh#L21-L41
# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
  local var="$1"
  local fileVar="${var}_FILE"
  local def="${2:-}"
  if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
    echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
    exit 1
  fi
  local val="$def"
  if [ "${!var:-}" ]; then
    val="${!var}"
  elif [ "${!fileVar:-}" ]; then
    val="$(<"${!fileVar}")"
  fi
  export "$var"="$val"
  unset "$fileVar"
}

set_container_env() {
  local var="$1"
  local value="$2"

  export "$var"="$value"
  printf '%s' "$value" >"/var/run/s6/container_environment/$var"
}

env_file_has() {
  local var="$1"

  [ -f /data/.env ] && grep -q "^${var}=" /data/.env
}

set_optional_env() {
  local var="$1"
  local value="$2"
  local was_set="$3"

  if [ "$was_set" = "x" ] || ! env_file_has "$var"; then
    set_container_env "$var" "$value"
  fi
}

REDIS_SENTINEL_SERVICE_WAS_SET=${REDIS_SENTINEL_SERVICE+x}
REDIS_SCHEME_WAS_SET=${REDIS_SCHEME+x}
REDIS_PORT_WAS_SET=${REDIS_PORT+x}
REDIS_PASSWORD_WAS_SET=${REDIS_PASSWORD+x}
REDIS_PASSWORD_FILE_WAS_SET=${REDIS_PASSWORD_FILE+x}
REDIS_DB_WAS_SET=${REDIS_DB+x}

DB_PORT=${DB_PORT:-3306}
DB_DATABASE=${DB_DATABASE:-${DB_NAME:-librenms}}
DB_USERNAME=${DB_USERNAME:-${DB_USER:-librenms}}
DB_TIMEOUT=${DB_TIMEOUT:-60}
LOG_CHANNEL=${LOG_CHANNEL:-stdout}
LOG_LEVEL=${LOG_LEVEL:-warning}
STDOUT_LOG_LEVEL=${STDOUT_LOG_LEVEL:-$LOG_LEVEL}

SIDECAR_DISPATCHER=${SIDECAR_DISPATCHER:-0}

#REDIS_HOST=${REDIS_HOST:-localhost}
REDIS_SCHEME=${REDIS_SCHEME:-tcp}
REDIS_PORT=${REDIS_PORT:-6379}
#REDIS_SENTINEL=${REDIS_SENTINEL:-localhost}
REDIS_SENTINEL_SERVICE=${REDIS_SENTINEL_SERVICE:-librenms}
file_env 'REDIS_PASSWORD'
if [ "$REDIS_PASSWORD_FILE_WAS_SET" = "x" ]; then
  REDIS_PASSWORD_WAS_SET=x
fi
REDIS_DB=${REDIS_DB:-0}

# Continue only if sidecar dispatcher container
if [ "$SIDECAR_DISPATCHER" != "1" ]; then
  exit 0
fi

echo ">>"
echo ">> Sidecar dispatcher container detected"
echo ">>"

file_env 'DB_PASSWORD'
if [ -z "$DB_PASSWORD" ]; then
  echo >&2 "ERROR: Either DB_PASSWORD or DB_PASSWORD_FILE must be defined"
  exit 1
fi

dbcmd="mariadb -h ${DB_HOST} -P ${DB_PORT} -u "${DB_USERNAME}" "-p${DB_PASSWORD}""
unset DB_PASSWORD

echo "Waiting ${DB_TIMEOUT}s for database to be ready..."
counter=1
while ! ${dbcmd} -e "show databases;" >/dev/null 2>&1; do
  sleep 1
  counter=$((counter + 1))
  if [ ${counter} -gt ${DB_TIMEOUT} ]; then
    echo >&2 "ERROR: Failed to connect to database on $DB_HOST"
    exit 1
  fi
done
echo "Database ready!"
while ! ${dbcmd} -e "desc $DB_DATABASE.poller_cluster;" >/dev/null 2>&1; do
  sleep 1
  counter=$((counter + 1))
  if [ ${counter} -gt ${DB_TIMEOUT} ]; then
    echo >&2 "ERROR: Table $DB_DATABASE.poller_cluster does not exist on $DB_HOST"
    exit 1
  fi
done

echo "NODE_ID: $NODE_ID"

# Redis
if [ -z "$REDIS_HOST" ] && [ -z "$REDIS_SENTINEL" ] && ! env_file_has 'REDIS_HOST' && ! env_file_has 'REDIS_SENTINEL'; then
  echo >&2 "ERROR: REDIS_HOST or REDIS_SENTINEL must be defined"
  exit 1
elif [ -n "$REDIS_SENTINEL" ] || env_file_has 'REDIS_SENTINEL'; then
  echo "Setting Redis Sentinel"
  if [ -n "$REDIS_SENTINEL" ]; then
    set_container_env 'REDIS_SENTINEL' "$REDIS_SENTINEL"
  fi
  set_optional_env 'REDIS_SENTINEL_SERVICE' "$REDIS_SENTINEL_SERVICE" "$REDIS_SENTINEL_SERVICE_WAS_SET"
elif [ -n "$REDIS_HOST" ] || env_file_has 'REDIS_HOST'; then
  echo "Setting Redis"
  if [ -n "$REDIS_HOST" ]; then
    set_container_env 'REDIS_HOST' "$REDIS_HOST"
  fi
fi
set_optional_env 'REDIS_SCHEME' "$REDIS_SCHEME" "$REDIS_SCHEME_WAS_SET"
set_optional_env 'REDIS_PORT' "$REDIS_PORT" "$REDIS_PORT_WAS_SET"
set_optional_env 'REDIS_PASSWORD' "$REDIS_PASSWORD" "$REDIS_PASSWORD_WAS_SET"
set_optional_env 'REDIS_DB' "$REDIS_DB" "$REDIS_DB_WAS_SET"

# Create service
mkdir -p /etc/services.d/dispatcher
cat >/etc/services.d/dispatcher/run <<EOL
#!/usr/bin/execlineb -P
with-contenv
s6-setuidgid ${PUID}:${PGID}
cd /opt/librenms
./librenms-service.py ${DISPATCHER_ARGS}
EOL
chmod +x /etc/services.d/dispatcher/run
