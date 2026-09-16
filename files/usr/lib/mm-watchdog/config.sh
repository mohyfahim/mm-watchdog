#!/bin/sh

# SPDX-License-Identifier: GPL-2.0-or-later

append_ping_target() {
	local target="$1"

	[ -n "$target" ] || return 0
	case "$target" in
	*[[:space:]]*) PING_TARGET_INVALID=1 ;;
	esac
	PING_TARGETS="${PING_TARGETS}${PING_TARGETS:+ }${target}"
}

config_error() {
	printf '%s\n' "mm-watchdog: invalid configuration: $*" >&2
}

validate_integer() {
	local name="$1"
	local value="$2"
	local minimum="$3"

	case "$value" in
	'' | *[!0-9]*)
		config_error "$name must be an integer"
		return 1
		;;
	esac

	if [ "$value" -lt "$minimum" ]; then
		config_error "$name must be at least $minimum"
		return 1
	fi
}

validate_boolean() {
	local name="$1"
	local value="$2"

	case "$value" in
	0 | 1) return 0 ;;
	*)
		config_error "$name must be 0 or 1"
		return 1
		;;
	esac
}

resolve_modem_selector() {
	local network_device

	if [ "$MODEM" != "auto" ]; then
		MODEM_SELECTOR="$MODEM"
		return 0
	fi

	network_device="$(uci -q get "network.${NETWORK_INTERFACE}.device")"
	if [ -z "$network_device" ]; then
		config_error "network.${NETWORK_INTERFACE}.device is required when modem is auto"
		return 1
	fi

	MODEM_SELECTOR="$network_device"
}

validate_watchdog_config() {
	local name
	local value
	local network_proto

	case "$NETWORK_INTERFACE" in
	'' | *[!A-Za-z0-9_]*)
		config_error "interface must be a valid UCI section name"
		return 1
		;;
	esac

	network_proto="$(uci -q get "network.${NETWORK_INTERFACE}.proto")"
	if [ "$network_proto" != "modemmanager" ]; then
		config_error "network.${NETWORK_INTERFACE}.proto must be modemmanager"
		return 1
	fi

	case "$MODEM" in
	'' | -* | *[![:print:]]* | *[[:space:]]*)
		config_error "modem must be auto or a single mmcli modem selector"
		return 1
		;;
	esac

	resolve_modem_selector || return 1

	[ -n "$PING_TARGETS" ] || {
		config_error "at least one ping_target is required"
		return 1
	}
	[ "$PING_TARGET_INVALID" -eq 0 ] || {
		config_error "each ping_target must be one value without whitespace"
		return 1
	}
	# UCI list items are intentionally expanded one target at a time.
	# shellcheck disable=SC2086
	for value in $PING_TARGETS; do
		case "$value" in
		-*)
			config_error "ping_target must not begin with a dash"
			return 1
			;;
		esac
	done

	for name in \
		CHECK_INTERVAL PING_TIMEOUT MODEMMANAGER_FAIL_LIMIT \
		CONNECTED_FAIL_LIMIT REGISTERED_FAIL_LIMIT \
		SEARCHING_RECOVERY_AFTER TEMPORARY_STATE_TIMEOUT \
		ENABLED_STATE_TIMEOUT ACTION_GRACE WEBHOOK_TIMEOUT \
		WEBHOOK_RETRY_INTERVAL WEBHOOK_QUEUE_LIMIT; do
		eval "value=\${$name}"
		validate_integer "$(printf '%s' "$name" | tr 'A-Z_' 'a-z-')" "$value" 1 || return 1
	done

	for name in \
		SEARCHING_RECOVERY_COOLDOWN MM_RESTART_COOLDOWN \
		RADIO_CYCLE_COOLDOWN MODEM_RESET_COOLDOWN; do
		eval "value=\${$name}"
		validate_integer "$(printf '%s' "$name" | tr 'A-Z_' 'a-z-')" "$value" 0 || return 1
	done

	for name in ENABLED WEBHOOK_ENABLED REPORT_STARTUP REPORT_RECOVERY REPORT_ERRORS; do
		eval "value=\${$name}"
		validate_boolean "$(printf '%s' "$name" | tr 'A-Z_' 'a-z-')" "$value" || return 1
	done

	if [ "$WEBHOOK_ENABLED" -eq 1 ]; then
		case "$WEBHOOK_URL" in
		*[![:print:]]* | *[[:space:]]*)
			config_error "webhook_url must not contain whitespace or control characters"
			return 1
			;;
		esac
		case "$WEBHOOK_URL" in
		http://* | https://*) ;;
		*)
			config_error "webhook_url must use http:// or https:// when webhooks are enabled"
			return 1
			;;
		esac
	fi

	return 0
}

load_watchdog_config() {
	config_load mm-watchdog

	config_get_bool ENABLED main enabled 1
	config_get NETWORK_INTERFACE main interface "wwan"
	config_get MODEM main modem "auto"

	config_get CHECK_INTERVAL main check_interval 5
	config_get PING_TIMEOUT main ping_timeout 2
	config_get MODEMMANAGER_FAIL_LIMIT main modemmanager_fail_limit 3
	config_get CONNECTED_FAIL_LIMIT main connected_fail_limit 3
	config_get REGISTERED_FAIL_LIMIT main registered_fail_limit 3

	config_get SEARCHING_RECOVERY_AFTER main searching_recovery_after 180
	config_get SEARCHING_RECOVERY_COOLDOWN main searching_recovery_cooldown 600
	config_get TEMPORARY_STATE_TIMEOUT main temporary_state_timeout 120
	config_get ENABLED_STATE_TIMEOUT main enabled_state_timeout 60
	config_get ACTION_GRACE main action_grace 20
	config_get MM_RESTART_COOLDOWN main mm_restart_cooldown 120
	config_get RADIO_CYCLE_COOLDOWN main radio_cycle_cooldown 120
	config_get MODEM_RESET_COOLDOWN main modem_reset_cooldown 600

	PING_TARGETS=""
	PING_TARGET_INVALID=0
	config_list_foreach main ping_target append_ping_target
	[ -n "$PING_TARGETS" ] || PING_TARGETS="1.1.1.1 8.8.8.8"

	config_get_bool WEBHOOK_ENABLED main webhook_enabled 0
	config_get WEBHOOK_URL main webhook_url ""
	config_get WEBHOOK_TIMEOUT main webhook_timeout 5
	config_get WEBHOOK_RETRY_INTERVAL main webhook_retry_interval 60
	config_get WEBHOOK_QUEUE_LIMIT main webhook_queue_limit 20
	config_get_bool REPORT_STARTUP main report_startup 1
	config_get_bool REPORT_RECOVERY main report_recovery 1
	config_get_bool REPORT_ERRORS main report_errors 1

	validate_watchdog_config
}
