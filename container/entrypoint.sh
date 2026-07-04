#!/usr/bin/env sh

set -e

DB_FILE=$1
APP=$2
shift 2
APP_ARGS="$@"

if [ -z "$DB_FILE" ] || [ -z "$APP" ]; then
    echo "ERROR: Both DB_FILE and APP arguments are required" >&2
    exit 1
fi

DB_PATH=$(dirname ${DB_FILE})

export APP_NAME=$(basename ${APP})
export DB_FILE

PUID=${PUID:-1000}
PGID=${PGID:-1000}

check_config_files() {
	local headscale_config_path=/etc/headscale/config.yaml
	local headscale_noise_private_key_path=/app/data/noise_private.key

	local abort_config=0

	if [ -z "$HEADSCALE_SERVER_URL" ]; then
		echo "ERROR: Required environment variable 'HEADSCALE_SERVER_URL' is missing." >&2
		abort_config=1
	fi

	if [ -z "$HEADSCALE_BASE_DOMAIN" ]; then
		echo "ERROR: Required environment variable 'HEADSCALE_BASE_DOMAIN' is missing." >&2
		abort_config=1
	fi

	if [ $abort_config -eq 0 ]; then
		mkdir -p /etc/headscale

		local config_updated=0

		if grep -q '\$HEADSCALE_SERVER_URL' $headscale_config_path; then
			sed -i "s@\$HEADSCALE_SERVER_URL@$HEADSCALE_SERVER_URL@" $headscale_config_path
			config_updated=1
		fi

		if grep -q '\$HEADSCALE_BASE_DOMAIN' $headscale_config_path; then
			sed -i "s@\$HEADSCALE_BASE_DOMAIN@$HEADSCALE_BASE_DOMAIN@" $headscale_config_path
			config_updated=1
		fi

		if [ $config_updated -eq 1 ]; then
			echo "INFO: Headscale configuration file updated."
		else
			echo "INFO: Headscale configuration file already up-to-date."
		fi
	else
		return $abort_config
	fi

	if [ ! -f $headscale_noise_private_key_path ]; then
		if [ ! -z "$HEADSCALE_NOISE_PRIVATE_KEY" ]; then
			echo -n "$HEADSCALE_NOISE_PRIVATE_KEY" > $headscale_noise_private_key_path
		fi
	fi
}

check_database_directory() {
	if [ ! -d "${DB_PATH}" ]; then
		echo "INFO: Creating database directory ${DB_PATH}..."
		mkdir -p "${DB_PATH}"
	fi

	echo "INFO: Ensure correct ownership of database directory..."
	find "${DB_PATH}" \( ! -group "${PGID}" -o ! -user "${PUID}" \) -exec chown "${PUID}:${PGID}" {} +
}

check_socket_directory() {
	mkdir -p /var/run/headscale

	echo "INFO: Ensure correct ownership of socket directory..."
	find "/var/run/${APP_NAME}" \( ! -group "${PGID}" -o ! -user "${PUID}" \) -exec chown "${PUID}:${PGID}" {} +
}

setup_headscale() {
	echo "INFO: [setup] Waiting for Headscale to be ready..."
	for i in $(seq 1 30); do
		if su-exec "$PUID:$PGID" ${APP} users list >/dev/null 2>&1; then
			break
		fi
		sleep 1
	done

	echo "INFO: [setup] Ensuring users exist..."
	su-exec "$PUID:$PGID" ${APP} users create hpc-lab 2>/dev/null || true
	su-exec "$PUID:$PGID" ${APP} users create arif 2>/dev/null || true
	su-exec "$PUID:$PGID" ${APP} users create hanif 2>/dev/null || true

	for u in hpc-lab arif hanif; do
		UID_TMP=$(su-exec "$PUID:$PGID" ${APP} users list 2>/dev/null | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | awk -v name="$u" '$0 ~ name {print $1; exit}') || true
		if [ -n "$UID_TMP" ]; then
			echo "INFO: [setup] Generating pre-auth key for $u (id ${UID_TMP})..."
			su-exec "$PUID:$PGID" ${APP} preauthkeys create --user "${UID_TMP}" --reusable --expiration 720h || true
		else
			echo "WARN: [setup] Could not determine user id for $u"
		fi
	done

	echo "INFO: [setup] Approving subnet routes for headnode..."
	NODE_ID=$(su-exec "$PUID:$PGID" ${APP} nodes list 2>/dev/null | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | awk '$0 ~ /headnode/ {print $1; exit}') || true
	if [ -n "$NODE_ID" ]; then
		su-exec "$PUID:$PGID" ${APP} nodes approve-routes --identifier "${NODE_ID}" --routes 192.168.50.8/32 || true
	else
		echo "WARN: [setup] Could not find headnode node id, skipping route approval"
	fi
}

if ! check_config_files; then
	exit 1
fi

if ! check_database_directory; then
	exit 1
fi

if ! check_socket_directory; then
	exit 1
fi

echo "INFO: Attempting to restore database if missing..."
su-exec "$PUID:$PGID" litestream restore -if-db-not-exists -if-replica-exists ${DB_FILE}

setup_headscale &

if [ -z "$DISABLE_REPLICATION" ]; then
	echo "INFO: Starting application using Litestream..."
	exec su-exec "$PUID:$PGID" litestream replicate -exec "${APP} ${APP_ARGS}"
else
	echo "INFO: Replication disabled, starting application directly..."
	exec su-exec "$PUID:$PGID" ${APP} ${APP_ARGS}
fi