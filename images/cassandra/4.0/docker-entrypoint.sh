#!/bin/bash
set -e

# first arg is `-f` or `--some-option`
# or there are no args
if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
	set -- cassandra -f "$@"
fi

# allow the container to be started with `--user`
if [ "$1" = 'cassandra' -a "$(id -u)" = '0' ]; then
	find "$CASSANDRA_CONF" /var/lib/cassandra /var/log/cassandra \
		\! -user cassandra -exec chown cassandra '{}' +
	exec gosu cassandra "$BASH_SOURCE" "$@"
fi

_ip_address() {
	# scrape the first non-localhost IP address of the container
	# in Swarm Mode, we often get two IPs -- the container IP, and the (shared) VIP, and the container IP should always be first
	ip address | awk '
		$1 != "inet" { next } # only lines with ip addresses
		$NF == "lo" { next } # skip loopback devices
		$2 ~ /^127[.]/ { next } # skip loopback addresses
		$2 ~ /^169[.]254[.]/ { next } # skip link-local addresses
		{
			gsub(/\/.+$/, "", $2)
			print $2
			exit
		}
	'
}

# "sed -i", but without "mv" (which doesn't work on a bind-mounted file, for example)
_sed-in-place() {
	local filename="$1"; shift
	local tempFile
	tempFile="$(mktemp)"
	sed "$@" "$filename" > "$tempFile"
	cat "$tempFile" > "$filename"
	rm "$tempFile"
}

if [ "$1" = 'cassandra' ]; then
	: ${CASSANDRA_RPC_ADDRESS='0.0.0.0'}
   
	: ${CASSANDRA_HINTED_HANDOFF_THROTTLE_IN_KB='10240'}
	: ${CASSANDRA_COMPACTION_THROUGHPUT_MB_PER_SEC='0'}
	: ${CASSANDRA_STREAM_THROUGHPUT_OUTBOUND_MEGABITS_PER_SEC='1000'}
	: ${CASSANDRA_INTER_DC_STREAM_THROUGHPUT_OUTBOUND_MEGABITS_PER_SEC:=$CASSANDRA_STREAM_THROUGHPUT_OUTBOUND_MEGABITS_PER_SEC}
	: ${CASSANDRA_BATCH_SIZE_WARN_THRESHOLD_IN_KB='5000'}
	: ${CASSANDRA_BATCH_SIZE_FAIL_THRESHOLD_IN_KB='50000'}

	: ${CASSANDRA_MAX_HEAP_SIZE:='4G'}
	: ${CASSANDRA_HEAP_NEWSIZE:='800M'}

	: ${CASSANDRA_LISTEN_ADDRESS='auto'}
	if [ "$CASSANDRA_LISTEN_ADDRESS" = 'auto' ]; then
		CASSANDRA_LISTEN_ADDRESS="$(_ip_address)"
	fi

	: ${CASSANDRA_BROADCAST_ADDRESS="$CASSANDRA_LISTEN_ADDRESS"}

	if [ "$CASSANDRA_BROADCAST_ADDRESS" = 'auto' ]; then
		CASSANDRA_BROADCAST_ADDRESS="$(_ip_address)"
	fi
	: ${CASSANDRA_BROADCAST_RPC_ADDRESS:=$CASSANDRA_BROADCAST_ADDRESS}

	if [ -n "${CASSANDRA_NAME:+1}" ]; then
		: ${CASSANDRA_SEEDS:="cassandra"}
	fi
	: ${CASSANDRA_SEEDS:="$CASSANDRA_BROADCAST_ADDRESS"}

	# change seeds configuration
	_sed-in-place "$CASSANDRA_CONF/cassandra.yaml" \
		-r 's/(- seeds:).*/\1 "'"$CASSANDRA_SEEDS"'"/'

    # change jvm configuration
	# update jvm memory size
	# change default jvm type, from CMS to G1
	_sed-in-place "$CASSANDRA_CONF/jvm.options" \
		-r 's/^(#)?(-Xms).*/\2'"$CASSANDRA_MAX_HEAP_SIZE"'/'
	_sed-in-place "$CASSANDRA_CONF/jvm.options" \
		-r 's/^(#)?(-Xmx).*/\2'"$CASSANDRA_MAX_HEAP_SIZE"'/'
	_sed-in-place "$CASSANDRA_CONF/jvm.options" \
		-r '/#?-XX:.*(\+UseParNewGC|SurvivorRatio=|MaxTenuringThreshold=|\+UseConcMarkSweepGC|CMS).*/ s/^/#/'
	_sed-in-place "$CASSANDRA_CONF/jvm.options" \
		-r '/#?-XX:.*(\+UseG1GC|G1RSetUpdatingPauseTimePercent=|MaxGCPauseMillis=).*/ s/^#//'

	for yaml in \
		cluster_name \
		listen_address \
		rpc_address \
		broadcast_rpc_address \
		hinted_handoff_throttle_in_kb \
		compaction_throughput_mb_per_sec \
		stream_throughput_outbound_megabits_per_sec \
		inter_dc_stream_throughput_outbound_megabits_per_sec \
		batch_size_warn_threshold_in_kb \
		batch_size_fail_threshold_in_kb \
	; do
		var="CASSANDRA_${yaml^^}"
		val="${!var}"
		if [ "$val" ]; then
			_sed-in-place "$CASSANDRA_CONF/cassandra.yaml" \
				-r 's/^(# )?('"$yaml"':).*/\2 '"$val"'/'
		fi
	done

	for env in \
		MAX_HEAP_SIZE \
		HEAP_NEWSIZE \
	; do
		var="CASSANDRA_${env^^}"
		val="${!var}"
		if [ "$val" ]; then
			_sed-in-place "$CASSANDRA_CONF/cassandra-env.sh" \
				-r 's/^(#)?('"$env"'=).*/\2"'"$val"'"/'
		fi
	done
fi

exec "$@"