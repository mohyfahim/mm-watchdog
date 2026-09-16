#!/bin/sh

# SPDX-License-Identifier: GPL-2.0-or-later

WEBHOOK_QUEUE_DIR="${WEBHOOK_QUEUE_DIR:-/tmp/mm-watchdog/events}"
UCLIENT_FETCH_BIN="${UCLIENT_FETCH_BIN:-/bin/uclient-fetch}"
WEBHOOK_NEXT_RETRY=0
WEBHOOK_SEQUENCE=0
WEBHOOK_TEMP_FILE=""

prepare_webhook_queue() {
	[ "$WEBHOOK_ENABLED" -eq 1 ] || return 0

	umask 077
	mkdir -p "$WEBHOOK_QUEUE_DIR" || return 1
	chmod 0700 "${WEBHOOK_QUEUE_DIR%/events}" "$WEBHOOK_QUEUE_DIR" 2>/dev/null || true
}

oldest_webhook_file() {
	local file

	for file in "$WEBHOOK_QUEUE_DIR"/*.json; do
		[ -f "$file" ] || continue
		printf '%s\n' "$file"
		return 0
	done

	return 1
}

cap_webhook_queue() {
	local count=0
	local file
	local oldest

	for file in "$WEBHOOK_QUEUE_DIR"/*.json; do
		[ -f "$file" ] || continue
		count=$((count + 1))
	done

	while [ "$count" -ge "$WEBHOOK_QUEUE_LIMIT" ]; do
		oldest="$(oldest_webhook_file)" || break
		rm -f -- "$oldest"
		count=$((count - 1))
		logger -p daemon.warning -t mm-watchdog "webhook queue full; dropped oldest event"
	done
}

queue_webhook_event() {
	local severity="$1"
	local event="$2"
	local reason="$3"
	local action="$4"
	local timestamp
	local uptime_seconds
	local incident_age=0
	local final_file
	local sequence_padded

	[ "$WEBHOOK_ENABLED" -eq 1 ] || return 0
	prepare_webhook_queue || return 1
	cap_webhook_queue

	timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	uptime_seconds="$(cut -d. -f1 /proc/uptime 2>/dev/null)"
	[ -n "$uptime_seconds" ] || uptime_seconds=0

	if [ "${INCIDENT_STARTED:-0}" -gt 0 ]; then
		incident_age=$(( $(watchdog_now) - INCIDENT_STARTED ))
	fi

	WEBHOOK_TEMP_FILE="$(mktemp "$WEBHOOK_QUEUE_DIR/.event.XXXXXX")" || return 1

	json_init
	json_add_int schema_version 1
	json_add_string service "mm-watchdog"
	json_add_string event "$event"
	json_add_string severity "$severity"

	json_add_object time
	json_add_string timestamp "$timestamp"
	json_add_int uptime_seconds "$uptime_seconds"
	json_close_object

	json_add_object device
	json_add_string hostname "$(uci -q get 'system.@system[0].hostname' || hostname)"
	json_add_string network_interface "$NETWORK_INTERFACE"
	json_add_string modem_selector "$MODEM_SELECTOR"
	json_close_object

	json_add_object incident
	json_add_string id "${INCIDENT_ID:-none}"
	json_add_int age_seconds "$incident_age"
	json_close_object

	json_add_object recovery
	json_add_string reason "$reason"
	json_add_string action "$action"
	json_add_int level "${RECOVERY_LEVEL:-0}"
	json_close_object

	json_add_object modem
	json_add_string state "${CURRENT_STATE:-unknown}"
	json_add_string registration "${CURRENT_REGISTRATION:-unknown}"
	json_add_string signal_quality "${CURRENT_SIGNAL:-unknown}"
	json_add_string access_technology "${CURRENT_ACCESS_TECH:-unknown}"
	json_add_string packet_service "${CURRENT_PACKET_SERVICE:-unknown}"
	json_close_object

	json_add_object bearer
	json_add_string path "${CURRENT_BEARER_PATH:-none}"
	json_add_string interface "${CURRENT_BEARER_INTERFACE:-none}"
	json_add_string connected "${CURRENT_BEARER_CONNECTED:-unknown}"
	json_close_object

	json_add_object connectivity
	json_add_boolean reachable "${INTERNET_REACHABLE:-0}"
	json_close_object

	if ! json_dump >"$WEBHOOK_TEMP_FILE"; then
		rm -f -- "$WEBHOOK_TEMP_FILE"
		WEBHOOK_TEMP_FILE=""
		return 1
	fi

	WEBHOOK_SEQUENCE=$((WEBHOOK_SEQUENCE + 1))
	sequence_padded="$(printf '%06d' "$WEBHOOK_SEQUENCE")"
	final_file="${WEBHOOK_QUEUE_DIR}/$(date +%s)-$$-${sequence_padded}.json"
	if ! mv "$WEBHOOK_TEMP_FILE" "$final_file"; then
		rm -f -- "$WEBHOOK_TEMP_FILE"
		WEBHOOK_TEMP_FILE=""
		return 1
	fi

	WEBHOOK_TEMP_FILE=""
	return 0
}

webhook_response_is_success() {
	local return_code="$1"
	local output="$2"

	[ "$return_code" -eq 0 ] && return 0
	[ "$return_code" -eq 8 ] || return 1
	printf '%s\n' "$output" | grep -Eq 'HTTP error 2[0-9][0-9]([^0-9]|$)'
}

send_webhook_file() {
	local json_file="$1"
	local output
	local return_code

	output="$(
		"$UCLIENT_FETCH_BIN" \
			--no-proxy \
			-O /dev/null \
			--timeout="$WEBHOOK_TIMEOUT" \
			--header='Content-Type: application/json' \
			--post-file="$json_file" \
			"$WEBHOOK_URL" \
			2>&1
	)"
	return_code=$?

	webhook_response_is_success "$return_code" "$output" && return 0

	output="$(printf '%s' "$output" | tr '\r\n' '  ' | head -c 256)"
	logger -p daemon.warning -t mm-watchdog \
		"webhook delivery failed rc=$return_code response='$output'"
	return 1
}

flush_webhook_queue() {
	local current
	local event_file

	[ "$WEBHOOK_ENABLED" -eq 1 ] || return 0
	current="$(watchdog_now)"
	[ "$current" -ge "$WEBHOOK_NEXT_RETRY" ] || return 0

	event_file="$(oldest_webhook_file)" || return 0
	if send_webhook_file "$event_file"; then
		rm -f -- "$event_file"
		WEBHOOK_NEXT_RETRY=0
		return 0
	fi

	WEBHOOK_NEXT_RETRY=$((current + WEBHOOK_RETRY_INTERVAL))
	return 1
}

cleanup_webhook_temp() {
	[ -n "$WEBHOOK_TEMP_FILE" ] && rm -f -- "$WEBHOOK_TEMP_FILE"
	WEBHOOK_TEMP_FILE=""
}
