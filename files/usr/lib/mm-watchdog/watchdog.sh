#!/bin/sh

# SPDX-License-Identifier: GPL-2.0-or-later

WATCHDOG_TAG="mm-watchdog"
RUNNING=1
RELOAD_REQUESTED=0

watchdog_now() {
	date +%s
}

watchdog_log() {
	logger -p daemon.info -t "$WATCHDOG_TAG" "$*"
}

watchdog_warn() {
	logger -p daemon.warning -t "$WATCHDOG_TAG" "$*"
}

watchdog_error() {
	local message="$*"

	logger -p daemon.err -t "$WATCHDOG_TAG" "$message"
	[ "${REPORT_ERRORS:-0}" -eq 1 ] && \
		queue_webhook_event error watchdog-error "$message" none
}

watchdog_recovery() {
	local event="$1"
	local reason="$2"
	local action="$3"

	LAST_ACTION="$action"
	watchdog_warn "event=$event action=$action reason=$reason level=$RECOVERY_LEVEL incident=${INCIDENT_ID:-none}"
	[ "$REPORT_RECOVERY" -eq 1 ] && \
		queue_webhook_event warning "$event" "$reason" "$action"
}

initialize_runtime_state() {
	BAD_COUNT=0
	MM_FAILURE_COUNT=0
	RECOVERY_LEVEL=0
	LAST_STATE=""
	STATE_SINCE="$(watchdog_now)"
	LAST_MM_RESTART=0
	LAST_RADIO_CYCLE=0
	LAST_MODEM_RESET=0
	LAST_SEARCH_RECOVERY=0
	LAST_ENABLE_ATTEMPT=0
	LAST_NOTICE_KEY=""
	LAST_ACTION="none"
	INCIDENT_ID=""
	INCIDENT_STARTED=0
	CURRENT_STATE="unknown"
	CURRENT_REGISTRATION="unknown"
	CURRENT_SIGNAL="unknown"
	CURRENT_ACCESS_TECH="unknown"
	CURRENT_PACKET_SERVICE="unknown"
	CURRENT_BEARER_PATH=""
	CURRENT_BEARER_INTERFACE=""
	CURRENT_BEARER_CONNECTED="unknown"
	INTERNET_REACHABLE=0
}

ensure_incident() {
	[ -n "$INCIDENT_ID" ] && return 0
	INCIDENT_STARTED="$(watchdog_now)"
	INCIDENT_ID="${INCIDENT_STARTED}-$$"
	watchdog_log "incident started id=$INCIDENT_ID"
}

clear_incident() {
	INCIDENT_ID=""
	INCIDENT_STARTED=0
}

set_recovery_level_minimum() {
	local minimum="$1"

	[ "$RECOVERY_LEVEL" -ge "$minimum" ] || RECOVERY_LEVEL="$minimum"
}

notice_once() {
	local key="$1"
	shift

	[ "$LAST_NOTICE_KEY" = "$key" ] && return 1
	LAST_NOTICE_KEY="$key"
	watchdog_warn "$*"
	return 0
}

get_modem_status() {
	mmcli --timeout 10 --modem "$MODEM_SELECTOR" --output-keyvalue 2>/dev/null
}

modemmanager_available() {
	mmcli --timeout 5 --list-modems >/dev/null 2>&1
}

get_bearer_status() {
	local bearer_path="$1"

	[ -n "$bearer_path" ] || return 1
	mmcli --timeout 10 --bearer "$bearer_path" --output-keyvalue 2>/dev/null
}

select_connected_bearer() {
	local modem_status="$1"
	local count
	local index=1
	local bearer_path
	local bearer_status
	local connected
	local interface

	CURRENT_BEARER_PATH=""
	CURRENT_BEARER_INTERFACE=""
	CURRENT_BEARER_CONNECTED="unknown"

	count="$(modemmanager_get_field "$modem_status" 'modem.generic.bearers.length')"
	case "$count" in
	'' | *[!0-9]*) return 1 ;;
	esac

	while [ "$index" -le "$count" ]; do
		bearer_path="$(modemmanager_get_field "$modem_status" "modem.generic.bearers.value\\[$index\\]")"
		bearer_status="$(get_bearer_status "$bearer_path")"
		connected="$(modemmanager_get_field "$bearer_status" bearer.status.connected)"
		interface="$(modemmanager_get_field "$bearer_status" bearer.status.interface)"

		case "$connected" in
		yes | true)
			CURRENT_BEARER_PATH="$bearer_path"
			CURRENT_BEARER_INTERFACE="$interface"
			CURRENT_BEARER_CONNECTED="$connected"
			[ -n "$interface" ] && return 0
			;;
		esac

		index=$((index + 1))
	done

	return 1
}

internet_ok() {
	local interface="$1"
	local target

	[ -n "$interface" ] || return 1
	ip link show dev "$interface" >/dev/null 2>&1 || return 1

	# Targets are stored as a validated, whitespace-separated UCI list.
	# shellcheck disable=SC2086
	for target in $PING_TARGETS; do
		case "$target" in
		*:*)
			command -v ping6 >/dev/null 2>&1 || continue
			ping6 -I "$interface" -c 1 -W "$PING_TIMEOUT" "$target" >/dev/null 2>&1 && return 0
			;;
		*)
			ping -I "$interface" -c 1 -W "$PING_TIMEOUT" "$target" >/dev/null 2>&1 && return 0
			;;
		esac
	done

	return 1
}

update_modem_observation() {
	local modem_status="$1"

	CURRENT_STATE="$(modemmanager_get_field "$modem_status" modem.generic.state)"
	CURRENT_REGISTRATION="$(modemmanager_get_field "$modem_status" modem.3gpp.registration-state)"
	CURRENT_SIGNAL="$(modemmanager_get_field "$modem_status" modem.generic.signal-quality.value)"
	CURRENT_ACCESS_TECH="$(modemmanager_get_multivalue_field "$modem_status" modem.generic.access-technologies)"
	CURRENT_PACKET_SERVICE="$(modemmanager_get_field "$modem_status" modem.3gpp.packet-service-state)"

	[ -n "$CURRENT_STATE" ] || CURRENT_STATE=unknown
	[ -n "$CURRENT_REGISTRATION" ] || CURRENT_REGISTRATION=unknown
	[ -n "$CURRENT_SIGNAL" ] || CURRENT_SIGNAL=unknown
	[ -n "$CURRENT_ACCESS_TECH" ] || CURRENT_ACCESS_TECH=unknown
	[ -n "$CURRENT_PACKET_SERVICE" ] || CURRENT_PACKET_SERVICE=unknown
	CURRENT_BEARER_PATH=""
	CURRENT_BEARER_INTERFACE=""
	CURRENT_BEARER_CONNECTED=unknown
	INTERNET_REACHABLE=0
}

wait_for_selected_modem() {
	local count=0

	while [ "$count" -lt 40 ] && [ "$RUNNING" -eq 1 ]; do
		get_modem_status >/dev/null 2>&1 && return 0
		count=$((count + 1))
		sleep 1
	done

	return 1
}

cooldown_remaining() {
	local last="$1"
	local cooldown="$2"
	local current="$3"

	if [ "$last" -eq 0 ] || [ $((current - last)) -ge "$cooldown" ]; then
		printf '%s\n' 0
	else
		printf '%s\n' $((cooldown - (current - last)))
	fi
}

soft_reconnect() {
	local reason="$1"

	ensure_incident
	watchdog_recovery "$reason" "$reason" soft-reconnect
	ifdown "$NETWORK_INTERFACE" >/dev/null 2>&1
	sleep 2

	if ! ifup "$NETWORK_INTERFACE" >/dev/null 2>&1; then
		watchdog_error "ifup failed during soft reconnect reason=$reason"
		return 1
	fi
}

restart_modemmanager() {
	local reason="$1"
	local current
	local remaining

	current="$(watchdog_now)"
	remaining="$(cooldown_remaining "$LAST_MM_RESTART" "$MM_RESTART_COOLDOWN" "$current")"
	if [ "$remaining" -gt 0 ]; then
		watchdog_warn "ModemManager restart suppressed reason=$reason remaining=${remaining}s"
		return 2
	fi

	LAST_MM_RESTART="$current"
	ensure_incident
	watchdog_recovery "$reason" "$reason" restart-modemmanager
	ifdown "$NETWORK_INTERFACE" >/dev/null 2>&1

	if ! /etc/init.d/modemmanager restart >/dev/null 2>&1; then
		watchdog_error "failed to restart ModemManager reason=$reason"
		return 1
	fi

	if ! wait_for_selected_modem; then
		watchdog_error "selected modem unavailable after ModemManager restart reason=$reason"
		return 1
	fi

	if ! ifup "$NETWORK_INTERFACE" >/dev/null 2>&1; then
		watchdog_error "ifup failed after ModemManager restart reason=$reason"
		return 1
	fi
}

radio_cycle() {
	local reason="$1"
	local current
	local remaining

	current="$(watchdog_now)"
	remaining="$(cooldown_remaining "$LAST_RADIO_CYCLE" "$RADIO_CYCLE_COOLDOWN" "$current")"
	if [ "$remaining" -gt 0 ]; then
		watchdog_warn "radio cycle suppressed reason=$reason remaining=${remaining}s"
		return 2
	fi

	LAST_RADIO_CYCLE="$current"
	ensure_incident
	watchdog_recovery "$reason" "$reason" radio-cycle
	ifdown "$NETWORK_INTERFACE" >/dev/null 2>&1
	mmcli --timeout 20 --modem "$MODEM_SELECTOR" --simple-disconnect >/dev/null 2>&1 || true

	if ! mmcli --timeout 30 --modem "$MODEM_SELECTOR" --disable >/dev/null 2>&1; then
		watchdog_warn "modem disable failed during radio cycle reason=$reason"
	fi

	sleep 3
	if ! mmcli --timeout 60 --modem "$MODEM_SELECTOR" --enable >/dev/null 2>&1; then
		watchdog_error "failed to enable modem after radio cycle reason=$reason"
		return 1
	fi

	sleep 3
	if ! ifup "$NETWORK_INTERFACE" >/dev/null 2>&1; then
		watchdog_error "ifup failed after radio cycle reason=$reason"
		return 1
	fi
}

reset_modem() {
	local reason="$1"
	local current
	local remaining

	current="$(watchdog_now)"
	remaining="$(cooldown_remaining "$LAST_MODEM_RESET" "$MODEM_RESET_COOLDOWN" "$current")"
	if [ "$remaining" -gt 0 ]; then
		watchdog_warn "modem reset suppressed reason=$reason remaining=${remaining}s"
		return 2
	fi

	LAST_MODEM_RESET="$current"
	ensure_incident
	watchdog_recovery "$reason" "$reason" modem-reset
	ifdown "$NETWORK_INTERFACE" >/dev/null 2>&1

	if ! mmcli --timeout 30 --modem "$MODEM_SELECTOR" --reset >/dev/null 2>&1; then
		watchdog_error "mmcli modem reset failed reason=$reason"
		return 1
	fi

	sleep 10
	if ! wait_for_selected_modem; then
		watchdog_error "selected modem did not reappear after reset"
		if ! /etc/init.d/modemmanager restart >/dev/null 2>&1 || ! wait_for_selected_modem; then
			watchdog_error "selected modem unavailable after reset fallback"
			return 1
		fi
	fi

	if ! ifup "$NETWORK_INTERFACE" >/dev/null 2>&1; then
		watchdog_error "ifup failed after modem reset reason=$reason"
		return 1
	fi
}

recover_connection() {
	local reason="$1"
	local result=0

	ensure_incident
	case "$RECOVERY_LEVEL" in
	0)
		soft_reconnect "$reason" || result=$?
		RECOVERY_LEVEL=1
		;;
	1)
		restart_modemmanager "$reason" || result=$?
		RECOVERY_LEVEL=2
		;;
	2)
		radio_cycle "$reason" || result=$?
		RECOVERY_LEVEL=3
		;;
	*)
		reset_modem "$reason" || result=$?
		RECOVERY_LEVEL=4
		;;
	esac

	BAD_COUNT=0
	[ "$result" -eq 2 ] || sleep "$ACTION_GRACE"
	return "$result"
}

enable_disabled_modem() {
	local current="$1"
	local remaining

	remaining="$(cooldown_remaining "$LAST_ENABLE_ATTEMPT" "$RADIO_CYCLE_COOLDOWN" "$current")"
	[ "$remaining" -eq 0 ] || return 2
	LAST_ENABLE_ATTEMPT="$current"
	ensure_incident
	watchdog_recovery modem-disabled modem-unexpectedly-disabled enable-modem

	if ! mmcli --timeout 60 --modem "$MODEM_SELECTOR" --enable >/dev/null 2>&1; then
		watchdog_error "failed to enable unexpectedly disabled modem"
		return 1
	fi

	if ! ifup "$NETWORK_INTERFACE" >/dev/null 2>&1; then
		watchdog_error "ifup failed after enabling modem"
		return 1
	fi
}

handle_modem_state() {
	local current="$1"
	local modem_status="$2"
	local state_age
	local reason
	local result

	state_age=$((current - STATE_SINCE))

	case "$CURRENT_STATE" in
	connected)
		select_connected_bearer "$modem_status" || true
		if internet_ok "$CURRENT_BEARER_INTERFACE"; then
			INTERNET_REACHABLE=1
			if [ "$BAD_COUNT" -gt 0 ] || [ "$RECOVERY_LEVEL" -gt 0 ] || [ -n "$INCIDENT_ID" ]; then
				watchdog_log "internet recovered interface=${CURRENT_BEARER_INTERFACE:-none} incident=${INCIDENT_ID:-none} level=$RECOVERY_LEVEL"
				[ "$REPORT_RECOVERY" -eq 0 ] || \
					queue_webhook_event info internet-recovered connectivity-restored "$LAST_ACTION"
			fi
			BAD_COUNT=0
			RECOVERY_LEVEL=0
			LAST_ACTION=none
			clear_incident
			flush_webhook_queue || true
		else
			BAD_COUNT=$((BAD_COUNT + 1))
			watchdog_log "connected without internet count=$BAD_COUNT interface=${CURRENT_BEARER_INTERFACE:-none}"
			[ "$BAD_COUNT" -lt "$CONNECTED_FAIL_LIMIT" ] || recover_connection connected-no-internet || true
		fi
		;;
	registered)
		BAD_COUNT=$((BAD_COUNT + 1))
		watchdog_log "registered without data count=$BAD_COUNT registration=$CURRENT_REGISTRATION"
		[ "$BAD_COUNT" -lt "$REGISTERED_FAIL_LIMIT" ] || recover_connection registered-without-data || true
		;;
	searching)
		BAD_COUNT=0
		if [ "$state_age" -ge "$SEARCHING_RECOVERY_AFTER" ] && \
			[ $((current - LAST_SEARCH_RECOVERY)) -ge "$SEARCHING_RECOVERY_COOLDOWN" ]; then
			radio_cycle searching-too-long
			result=$?
			if [ "$result" -ne 2 ]; then
				LAST_SEARCH_RECOVERY="$current"
				set_recovery_level_minimum 3
				sleep "$ACTION_GRACE"
			fi
			STATE_SINCE="$(watchdog_now)"
		fi
		;;
	enabled)
		BAD_COUNT=0
		if [ "$state_age" -ge "$ENABLED_STATE_TIMEOUT" ]; then
			radio_cycle enabled-but-not-registering || true
			set_recovery_level_minimum 3
			STATE_SINCE="$(watchdog_now)"
			sleep "$ACTION_GRACE"
		fi
		;;
	disabled)
		BAD_COUNT=0
		enable_disabled_modem "$current" || true
		STATE_SINCE="$(watchdog_now)"
		sleep "$ACTION_GRACE"
		;;
	connecting | enabling | initializing | disconnecting | disabling)
		BAD_COUNT=0
		if [ "$state_age" -ge "$TEMPORARY_STATE_TIMEOUT" ]; then
			restart_modemmanager "state-stuck-$CURRENT_STATE" || true
			set_recovery_level_minimum 2
			STATE_SINCE="$(watchdog_now)"
			sleep "$ACTION_GRACE"
		fi
		;;
	locked)
		BAD_COUNT=0
		notice_once locked "modem locked; automatic recovery suppressed"
		;;
	failed)
		reason="$(modemmanager_get_field "$modem_status" modem.generic.state-failed-reason)"
		[ -n "$reason" ] || reason=unknown
		case "$reason" in
		sim-missing | sim-error | sim-wrong)
			BAD_COUNT=0
			if notice_once "failed:$reason" "modem failed reason=$reason; automatic reset suppressed"; then
				[ "$REPORT_ERRORS" -eq 0 ] || \
					queue_webhook_event error modem-failed "$reason" automatic-reset-suppressed
			fi
			;;
		*) recover_connection "modem-failed-$reason" || true ;;
		esac
		;;
	*)
		BAD_COUNT=0
		notice_once "unknown:$CURRENT_STATE" "unhandled modem state='$CURRENT_STATE'"
		;;
	esac
}

check_openwrt_config() {
	local force_connection

	force_connection="$(uci -q get "network.${NETWORK_INTERFACE}.force_connection")"
	[ "$force_connection" = 1 ] || \
		watchdog_warn "network.$NETWORK_INTERFACE.force_connection is not 1"
}

handle_stop_signal() {
	RUNNING=0
	cleanup_webhook_temp
	exit 0
}

handle_reload_signal() {
	RELOAD_REQUESTED=1
}

watchdog_main() {
	local current
	local modem_status
	local unavailable_reason

	trap handle_stop_signal INT TERM
	trap handle_reload_signal HUP
	load_watchdog_config || exit 2
	[ "$ENABLED" -eq 1 ] || exit 0

	initialize_runtime_state
	prepare_webhook_queue || watchdog_warn "unable to prepare webhook queue"
	check_openwrt_config
	watchdog_log "started interface=$NETWORK_INTERFACE modem=$MODEM_SELECTOR webhook=$WEBHOOK_ENABLED"
	[ "$REPORT_STARTUP" -eq 0 ] || queue_webhook_event info watchdog-started service-started none

	while [ "$RUNNING" -eq 1 ]; do
		if [ "$RELOAD_REQUESTED" -eq 1 ]; then
			RELOAD_REQUESTED=0
			if ! load_watchdog_config; then
				watchdog_error "configuration reload failed; stopping"
				break
			fi
			[ "$ENABLED" -eq 1 ] || break
			initialize_runtime_state
			prepare_webhook_queue || watchdog_warn "unable to prepare webhook queue"
			check_openwrt_config
			watchdog_log "configuration reloaded interface=$NETWORK_INTERFACE modem=$MODEM_SELECTOR"
		fi

		current="$(watchdog_now)"
		modem_status="$(get_modem_status)"

		if [ -z "$modem_status" ]; then
			MM_FAILURE_COUNT=$((MM_FAILURE_COUNT + 1))
			if modemmanager_available; then
				unavailable_reason=selected-modem-unavailable
			else
				unavailable_reason=modemmanager-unresponsive
			fi
			watchdog_log "$unavailable_reason count=$MM_FAILURE_COUNT"

			if [ "$MM_FAILURE_COUNT" -ge "$MODEMMANAGER_FAIL_LIMIT" ]; then
				restart_modemmanager "$unavailable_reason" || true
				set_recovery_level_minimum 2
				MM_FAILURE_COUNT=0
				sleep "$ACTION_GRACE"
			fi

			sleep "$CHECK_INTERVAL"
			continue
		fi

		MM_FAILURE_COUNT=0
		update_modem_observation "$modem_status"
		if [ "$CURRENT_STATE" != "$LAST_STATE" ]; then
			watchdog_log "state ${LAST_STATE:-none} -> $CURRENT_STATE registration=$CURRENT_REGISTRATION signal=$CURRENT_SIGNAL level=$RECOVERY_LEVEL"
			LAST_STATE="$CURRENT_STATE"
			LAST_NOTICE_KEY=""
			STATE_SINCE="$current"
			BAD_COUNT=0
		fi

		handle_modem_state "$current" "$modem_status"
		sleep "$CHECK_INTERVAL"
	done

	cleanup_webhook_temp
	watchdog_log "stopped"
}
