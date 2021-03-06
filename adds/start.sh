#!/usr/bin/env bash

OPTION="${1}"

if [ ! -z "${ROOTPATH}" ]; then
	echo ":: We have changed the semantic and doesn't need the ROOTPATH"
	echo ":: variable anymore"
fi

generate_turn_key() {
	local turnkey="${1}"
	local filepath="${2}"

	echo "lt-cred-mech" > "${filepath}"
	echo "use-auth-secret" >> "${filepath}"
	echo "static-auth-secret=${turnkey}" >> "${filepath}"
	echo "realm=turn.${SERVER_NAME}" >> "${filepath}"
	echo "cert=/data/${SERVER_NAME}.tls.crt" >> "${filepath}"
	echo "pkey=/data/${SERVER_NAME}.tls.key" >> "${filepath}"
	echo "dh-file=/data/${SERVER_NAME}.tls.dh" >> "${filepath}"
	echo "cipher-list=\"HIGH\"" >> "${filepath}"
}

generate_synapse_file() {
	local filepath="${1}"

	python -m synapse.app.homeserver \
	       --config-path "${filepath}" \
	       --generate-config \
	       --report-stats ${REPORT_STATS} \
	       --server-name ${SERVER_NAME}
}

configure_homeserver_yaml() {
	local turnkey="${1}"
	local filepath="${2}"

	local ymltemp="$(mktemp)"

	awk -v TURNURIES="turn_uris: [\"turn:${SERVER_NAME}:3478?transport=udp\", \"turn:${SERVER_NAME}:3478?transport=tcp\"]" \
	    -v TURNSHAREDSECRET="turn_shared_secret: \"${turnkey}\"" \
	    -v PIDFILE="pid_file: /data/homeserver.pid" \
	    -v DATABASE="database: \"/data/homeserver.db\"" \
	    -v LOGFILE="log_file: \"/data/homeserver.log\"" \
	    -v MEDIASTORE="media_store_path: \"/data/media_store\"" \
	    '{
		sub(/turn_shared_secret: "YOUR_SHARED_SECRET"/, TURNSHAREDSECRET);
		sub(/turn_uris: \[\]/, TURNURIES);
		sub(/pid_file: \/homeserver.pid/, PIDFILE);
		sub(/database: "\/homeserver.db"/, DATABASE);
		sub(/log_file: "\/homeserver.log"/, LOGFILE);
		sub(/media_store_path: "\/media_store"/, MEDIASTORE);
		print;
	    }' "${filepath}" > "${ymltemp}"

	mv ${ymltemp} "${filepath}"
}

# ${SERVER_NAME}.log.config is autogenerated via --generate-config
configure_log_config() {
	sed -i "s|.*filename:\s/homeserver.log|    filename: /data/homeserver.log|g" "/data/${SERVER_NAME}.log.config"
}

case $OPTION in
	"start")
		if [ -f /data/turnserver.conf ]; then
			echo "-=> start turn"
			if [ -f /conf/supervisord-turnserver.conf.deactivated ]; then
				mv -f /conf/supervisord-turnserver.conf.deactivated /conf/supervisord-turnserver.conf
			fi
		else
			if [ -f /conf/supervisord-turnserver.conf ]; then
				mv -f /conf/supervisord-turnserver.conf /conf/supervisord-turnserver.conf.deactivated
			fi
		fi

		echo "-=> start riot.im client"
		(
			if [ -f /data/vector.im.conf ] || [ -f /data/riot.im.conf ] ; then
				echo "The riot web client is now handled via silvio/matrix-riot-docker"
			fi
		)

		echo "-=> start matrix"
		groupadd -r -g $MATRIX_GID matrix
		useradd -r -d /data -M -u $MATRIX_UID -g matrix matrix
		chown -R $MATRIX_UID:$MATRIX_GID /data
		chown -R $MATRIX_UID:$MATRIX_GID /uploads
		chmod a+rwx /run
		exec supervisord -c /supervisord.conf
		;;

	"stop")
		echo "-=> stop matrix"
		echo "-=> via docker stop ..."
		;;

	"version")
		echo "-=> Matrix Version"
		cat /synapse.version
		;;

	"diff")
		echo "-=> Diff between local configfile and a fresh generated config file"
		echo "-=>      some values are different in technical point of view, like"
		echo "-=>      autogenerated secret keys etc..."

		DIFFPARAMS="${DIFFPARAMS:-Naur}"
		SERVER_NAME="${SERVER_NAME:-demo_server_name}"
		REPORT_STATS="${REPORT_STATS:-no_or_yes}"
		export SERVER_NAME REPORT_STATS

		generate_synapse_file /tmp/homeserver.synapse.yaml
		diff -${DIFFPARAMS} /tmp/homeserver.synapse.yaml /data/homeserver.yaml
		;;

	"generate")
		breakup="0"
		[[ -z "${SERVER_NAME}" ]] && echo "STOP! environment variable SERVER_NAME must be set" && breakup="1"
		[[ -z "${REPORT_STATS}" ]] && echo "STOP! environment variable REPORT_STATS must be set to 'no' or 'yes'" && breakup="1"
		[[ "${REPORT_STATS}" != "yes" ]] && [[ "${REPORT_STATS}" != "no" ]] && \
			echo "STOP! REPORT_STATS needs to be 'no' or 'yes'" && breakup="1"

		[[ "${breakup}" == "1" ]] && exit 1

		echo "-=> generate turn config"
		turnkey=$(pwgen -s 64 1)
		generate_turn_key $turnkey /data/turnserver.conf

		echo "-=> generate synapse config"
		generate_synapse_file /data/homeserver.tmp
		echo "-=> configure some settings in homeserver.yaml"
		configure_homeserver_yaml $turnkey /data/homeserver.tmp

		mv /data/homeserver.tmp /data/homeserver.yaml

		echo "-=> configure some settings in ${SERVER_NAME}.log.config"
		configure_log_config

		echo ""
		echo "-=> you have to review the generated configuration file homeserver.yaml"
		;;

	*)
		echo "-=> unknown \'$OPTION\'"
		;;
esac

