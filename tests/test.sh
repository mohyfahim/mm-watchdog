#!/bin/sh

# SPDX-License-Identifier: GPL-2.0-or-later

set -u

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
	rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT INT TERM

# The production files only define functions when sourced.
. "$ROOT_DIR/files/usr/lib/mm-watchdog/config.sh"
. "$ROOT_DIR/files/usr/lib/mm-watchdog/webhook.sh"
. "$ROOT_DIR/files/usr/lib/mm-watchdog/watchdog.sh"

fail() {
	printf '  %s\n' "$*" >&2
	return 1
}

assert_equal() {
	local expected="$1"
	local actual="$2"
	local label="${3:-value}"

	[ "$expected" = "$actual" ] || \
		fail "$label: expected '$expected', got '$actual'"
}

assert_file_contains() {
	local file="$1"
	local pattern="$2"

	grep -Fq -- "$pattern" "$file" || fail "$file does not contain: $pattern"
}

run_test() {
	local name="$1"
	local function_name="$2"

	printf '%-58s' "$name"
	if ("$function_name"); then
		PASS_COUNT=$((PASS_COUNT + 1))
		printf 'ok\n'
	else
		FAIL_COUNT=$((FAIL_COUNT + 1))
		printf 'FAIL\n'
	fi
}

config_load() {
	return 0
}

config_get() {
	local destination="$1"
	local section="$2"
	local option="$3"
	local default="${4:-}"
	local value

	: "$section"
	eval "value=\${MOCK_$option-}"
	[ -n "$value" ] || value="$default"
	eval "$destination=\$value"
}

config_get_bool() {
	config_get "$@"
}

config_list_foreach() {
	local section="$1"
	local option="$2"
	local callback="$3"
	local value

	: "$section" "$option"
	# Tests model OpenWrt's repeated UCI list callback.
	# shellcheck disable=SC2086
	for value in ${MOCK_PING_TARGETS:-}; do
		"$callback" "$value"
	done
}

uci() {
	local argument
	local key=""

	for argument in "$@"; do
		key="$argument"
	done

	case "$key" in
	network.*.proto) printf '%s\n' "${MOCK_NETWORK_PROTO:-modemmanager}" ;;
	network.*.device) printf '%s\n' "${MOCK_NETWORK_DEVICE:-/sys/devices/mock-modem}" ;;
	network.*.force_connection) printf '%s\n' "${MOCK_FORCE_CONNECTION:-1}" ;;
	system.@system\[0\].hostname) printf '%s\n' test-router ;;
	*) return 1 ;;
	esac
}

logger() {
	return 0
}

test_default_configuration() {
	unset MOCK_interface MOCK_modem MOCK_check_interval MOCK_webhook_enabled MOCK_PING_TARGETS
	load_watchdog_config
	assert_equal wwan "$NETWORK_INTERFACE" interface
	assert_equal auto "$MODEM" modem
	assert_equal /sys/devices/mock-modem "$MODEM_SELECTOR" selector
	assert_equal "1.1.1.1 8.8.8.8" "$PING_TARGETS" targets
	assert_equal 0 "$WEBHOOK_ENABLED" webhook
}

test_explicit_modem_and_targets() {
	MOCK_interface=cellular
	MOCK_modem=4
	MOCK_PING_TARGETS="9.9.9.9 2001:4860:4860::8888"
	load_watchdog_config
	assert_equal cellular "$NETWORK_INTERFACE" interface
	assert_equal 4 "$MODEM_SELECTOR" selector
	assert_equal "$MOCK_PING_TARGETS" "$PING_TARGETS" targets
}

test_invalid_numeric_configuration() {
	MOCK_check_interval=zero
	if load_watchdog_config 2>/dev/null; then
		fail "invalid interval was accepted"
	fi
}

test_invalid_webhook_url() {
	MOCK_webhook_enabled=1
	MOCK_webhook_url=ftp://example.test/events
	if load_watchdog_config 2>/dev/null; then
		fail "invalid webhook URL was accepted"
	fi
}

test_connected_bearer_selection() {
	modemmanager_get_field() {
		local data="$1"
		local field="$2"

		case "$data:$field" in
		MODEM:modem.generic.bearers.length) printf '2\n' ;;
		MODEM:modem.generic.bearers.value\\\[1\\\]) printf '/bearer/1\n' ;;
		MODEM:modem.generic.bearers.value\\\[2\\\]) printf '/bearer/2\n' ;;
		BEARER1:bearer.status.connected) printf 'no\n' ;;
		BEARER1:bearer.status.interface) printf 'wwan-old\n' ;;
		BEARER2:bearer.status.connected) printf 'yes\n' ;;
		BEARER2:bearer.status.interface) printf 'wwan-active\n' ;;
		esac
	}
	get_bearer_status() {
		case "$1" in
		/bearer/1) printf 'BEARER1\n' ;;
		/bearer/2) printf 'BEARER2\n' ;;
		esac
	}

	select_connected_bearer MODEM
	assert_equal /bearer/2 "$CURRENT_BEARER_PATH" bearer
	assert_equal wwan-active "$CURRENT_BEARER_INTERFACE" interface
}

test_ipv4_ipv6_target_fallback() {
	local calls="$TEST_TMP/ping-calls"
	: >"$calls"
	PING_TARGETS="192.0.2.1 2001:db8::1"
	PING_TIMEOUT=2
	ip() { return 0; }
	ping() { printf 'ping %s\n' "$*" >>"$calls"; return 1; }
	ping6() { printf 'ping6 %s\n' "$*" >>"$calls"; return 0; }

	internet_ok wwan0
	assert_file_contains "$calls" "ping -I wwan0"
	assert_file_contains "$calls" "ping6 -I wwan0"
}

test_recovery_ladder() {
	local actions="$TEST_TMP/actions"
	: >"$actions"
	RECOVERY_LEVEL=0
	BAD_COUNT=3
	ACTION_GRACE=1
	ensure_incident() { :; }
	sleep() { :; }
	soft_reconnect() { printf 'soft\n' >>"$actions"; }
	restart_modemmanager() { printf 'restart\n' >>"$actions"; }
	radio_cycle() { printf 'radio\n' >>"$actions"; }
	reset_modem() { printf 'reset\n' >>"$actions"; }

	recover_connection test
	recover_connection test
	recover_connection test
	recover_connection test
	assert_equal 4 "$RECOVERY_LEVEL" level
	assert_equal "soft restart radio reset" "$(tr '\n' ' ' <"$actions" | sed 's/ $//')" actions
}

test_failed_action_still_escalates() {
	RECOVERY_LEVEL=0
	BAD_COUNT=3
	ACTION_GRACE=1
	ensure_incident() { :; }
	sleep() { :; }
	soft_reconnect() { return 1; }

	if recover_connection test; then
		fail "failed action reported success"
	fi
	assert_equal 1 "$RECOVERY_LEVEL" level
	assert_equal 0 "$BAD_COUNT" bad-count
}

test_cooldown_calculation() {
	assert_equal 0 "$(cooldown_remaining 0 120 1000)" initial
	assert_equal 70 "$(cooldown_remaining 950 120 1000)" remaining
	assert_equal 0 "$(cooldown_remaining 800 120 1000)" expired
}

test_registered_failure_threshold() {
	local actions="$TEST_TMP/registered-actions"
	: >"$actions"
	CURRENT_STATE=registered
	CURRENT_REGISTRATION=home
	STATE_SINCE=0
	BAD_COUNT=0
	REGISTERED_FAIL_LIMIT=2
	watchdog_log() { :; }
	recover_connection() { printf '%s\n' "$1" >>"$actions"; BAD_COUNT=0; }

	handle_modem_state 10 MODEM
	[ ! -s "$actions" ] || fail "recovery ran before threshold"
	handle_modem_state 15 MODEM
	assert_file_contains "$actions" registered-without-data
}

test_searching_recovery_and_cooldown() {
	local actions="$TEST_TMP/search-actions"
	: >"$actions"
	CURRENT_STATE=searching
	STATE_SINCE=0
	BAD_COUNT=0
	RECOVERY_LEVEL=0
	SEARCHING_RECOVERY_AFTER=180
	SEARCHING_RECOVERY_COOLDOWN=600
	LAST_SEARCH_RECOVERY=0
	ACTION_GRACE=1
	radio_cycle() { printf '%s\n' "$1" >>"$actions"; return 0; }
	watchdog_now() { printf '1000\n'; }
	sleep() { :; }

	handle_modem_state 1000 MODEM
	handle_modem_state 1100 MODEM
	assert_equal 1 "$(wc -l <"$actions" | tr -d ' ')" action-count
	assert_equal 3 "$RECOVERY_LEVEL" level
	assert_equal 1000 "$LAST_SEARCH_RECOVERY" last-action
}

test_temporary_state_timeout() {
	local actions="$TEST_TMP/temporary-actions"
	: >"$actions"
	CURRENT_STATE=connecting
	STATE_SINCE=100
	BAD_COUNT=0
	RECOVERY_LEVEL=0
	TEMPORARY_STATE_TIMEOUT=120
	ACTION_GRACE=1
	restart_modemmanager() { printf '%s\n' "$1" >>"$actions"; }
	watchdog_now() { printf '250\n'; }
	sleep() { :; }

	handle_modem_state 250 MODEM
	assert_file_contains "$actions" state-stuck-connecting
	assert_equal 2 "$RECOVERY_LEVEL" level
}

test_disabled_enable_attempt_cooldown() {
	local actions="$TEST_TMP/enable-actions"
	: >"$actions"
	LAST_ENABLE_ATTEMPT=100
	RADIO_CYCLE_COOLDOWN=120
	MODEM_SELECTOR=0
	NETWORK_INTERFACE=wwan
	ensure_incident() { :; }
	watchdog_recovery() { printf 'event\n' >>"$actions"; }
	mmcli() { printf 'mmcli\n' >>"$actions"; }
	ifup() { printf 'ifup\n' >>"$actions"; }

	if enable_disabled_modem 150; then
		fail "enable attempt ignored its cooldown"
	else
		assert_equal 2 "$?" suppressed-status
	fi
	[ ! -s "$actions" ] || fail "suppressed enable ran commands"
	enable_disabled_modem 220
	assert_file_contains "$actions" mmcli
	assert_equal 220 "$LAST_ENABLE_ATTEMPT" last-attempt
}

test_locked_notice_is_rate_limited() {
	local notices="$TEST_TMP/locked-notices"
	: >"$notices"
	CURRENT_STATE=locked
	STATE_SINCE=0
	BAD_COUNT=0
	LAST_NOTICE_KEY=""
	watchdog_warn() { printf '%s\n' "$*" >>"$notices"; }

	handle_modem_state 10 MODEM || true
	handle_modem_state 20 MODEM || true
	assert_equal 1 "$(wc -l <"$notices" | tr -d ' ')" notice-count
}

test_sim_failure_is_safe_and_rate_limited() {
	local events="$TEST_TMP/sim-events"
	: >"$events"
	CURRENT_STATE=failed
	STATE_SINCE=0
	BAD_COUNT=0
	REPORT_ERRORS=1
	LAST_NOTICE_KEY=""
	watchdog_warn() { :; }
	modemmanager_get_field() { printf 'sim-missing\n'; }
	recover_connection() { fail "recovery must not run for a missing SIM"; }
	queue_webhook_event() { printf '%s\n' "$2" >>"$events"; }

	handle_modem_state 10 MODEM
	handle_modem_state 20 MODEM
	assert_equal 1 "$(wc -l <"$events" | tr -d ' ')" event-count
}

test_success_clears_incident() {
	local events="$TEST_TMP/recovery-events"
	: >"$events"
	CURRENT_STATE=connected
	STATE_SINCE=0
	BAD_COUNT=2
	RECOVERY_LEVEL=3
	INCIDENT_ID=incident-1
	INCIDENT_STARTED=1
	LAST_ACTION=radio-cycle
	REPORT_RECOVERY=1
	watchdog_log() { :; }
	select_connected_bearer() {
		CURRENT_BEARER_INTERFACE=wwan0
		CURRENT_BEARER_PATH=/bearer/2
		CURRENT_BEARER_CONNECTED=yes
	}
	internet_ok() { return 0; }
	queue_webhook_event() { printf '%s\n' "$2" >>"$events"; }
	flush_webhook_queue() { :; }

	handle_modem_state 10 MODEM
	assert_equal 0 "$RECOVERY_LEVEL" level
	assert_equal "" "$INCIDENT_ID" incident
	assert_equal 1 "$INTERNET_REACHABLE" reachability
	assert_file_contains "$events" internet-recovered
}

test_webhook_status_handling() {
	webhook_response_is_success 0 "" || fail "exit 0 was rejected"
	webhook_response_is_success 8 "HTTP error 201" || fail "HTTP 201 was rejected"
	webhook_response_is_success 8 "HTTP error 299 response" || fail "HTTP 299 was rejected"
	if webhook_response_is_success 8 "HTTP error 301"; then
		fail "HTTP 301 was accepted"
	fi
	if webhook_response_is_success 4 "HTTP error 200"; then
		fail "transport failure was accepted"
	fi
}

test_webhook_queue_cap() {
	WEBHOOK_QUEUE_DIR="$TEST_TMP/queue"
	WEBHOOK_QUEUE_LIMIT=2
	mkdir -p "$WEBHOOK_QUEUE_DIR"
	: >"$WEBHOOK_QUEUE_DIR/100-1-1.json"
	: >"$WEBHOOK_QUEUE_DIR/101-1-2.json"

	cap_webhook_queue
	[ ! -e "$WEBHOOK_QUEUE_DIR/100-1-1.json" ] || fail "oldest event was retained"
	[ -e "$WEBHOOK_QUEUE_DIR/101-1-2.json" ] || fail "newest event was removed"
}

test_webhook_retry_backoff() {
	local attempts="$TEST_TMP/webhook-attempts"
	: >"$attempts"
	WEBHOOK_ENABLED=1
	WEBHOOK_NEXT_RETRY=0
	WEBHOOK_RETRY_INTERVAL=60
	oldest_webhook_file() { printf '%s\n' "$TEST_TMP/event.json"; }
	send_webhook_file() { printf 'attempt\n' >>"$attempts"; return 1; }
	watchdog_now() { printf '100\n'; }

	flush_webhook_queue || true
	assert_equal 160 "$WEBHOOK_NEXT_RETRY" retry-time
	flush_webhook_queue || true
	assert_equal 1 "$(wc -l <"$attempts" | tr -d ' ')" attempts
}

test_json_values_are_passed_to_jshn() {
	local values="$TEST_TMP/json-values"
	local reason='quote " and backslash \\'
	: >"$values"
	WEBHOOK_ENABLED=1
	WEBHOOK_QUEUE_DIR="$TEST_TMP/json-queue/events"
	WEBHOOK_QUEUE_LIMIT=20
	NETWORK_INTERFACE=wwan
	MODEM_SELECTOR=0
	INCIDENT_STARTED=0
	json_init() { :; }
	json_add_int() { :; }
	json_add_object() { :; }
	json_close_object() { :; }
	json_add_boolean() { :; }
	json_add_string() { printf '%s=%s\n' "$1" "$2" >>"$values"; }
	json_dump() { printf '{}\n'; }

	queue_webhook_event warning test-event "$reason" test-action
	assert_file_contains "$values" "reason=$reason"
}

test_partial_file_cleanup() {
	WEBHOOK_TEMP_FILE="$TEST_TMP/partial-event"
	: >"$WEBHOOK_TEMP_FILE"
	cleanup_webhook_temp
	[ ! -e "$TEST_TMP/partial-event" ] || fail "partial file remains"
	assert_equal "" "$WEBHOOK_TEMP_FILE" temp-path
}

test_init_service_contract() {
	local calls="$TEST_TMP/procd-calls"
	: >"$calls"
	MOCK_enabled=1
	procd_open_instance() { printf 'instance:%s\n' "$1" >>"$calls"; }
	procd_set_param() { printf 'param:%s\n' "$*" >>"$calls"; }
	procd_close_instance() { printf 'close\n' >>"$calls"; }
	service_running() { return 0; }
	procd_send_signal() { printf 'signal:%s\n' "$*" >>"$calls"; }
	procd_kill() { printf 'kill:%s\n' "$*" >>"$calls"; }
	start() { printf 'start\n' >>"$calls"; }

	. "$ROOT_DIR/files/etc/init.d/mm-watchdog"
	start_service
	reload_service
	assert_file_contains "$calls" "param:command /usr/sbin/modem-watchdog"
	assert_file_contains "$calls" "param:respawn 3600 5 5"
	assert_file_contains "$calls" "param:reload_signal HUP"
	assert_file_contains "$calls" "signal:mm-watchdog watchdog HUP"
}

test_init_disabled_service_is_removed() {
	local calls="$TEST_TMP/procd-disabled-calls"
	: >"$calls"
	MOCK_enabled=0
	procd_open_instance() { printf 'instance\n' >>"$calls"; }
	procd_set_param() { :; }
	procd_close_instance() { :; }
	service_running() { return 0; }
	procd_send_signal() { printf 'signal\n' >>"$calls"; }
	procd_kill() { printf 'kill:%s\n' "$*" >>"$calls"; }
	start() { printf 'start\n' >>"$calls"; }

	. "$ROOT_DIR/files/etc/init.d/mm-watchdog"
	start_service
	reload_service
	if grep -Fq instance "$calls"; then
		fail "disabled service opened a procd instance"
	fi
	assert_file_contains "$calls" "kill:mm-watchdog watchdog"
}

run_test "default configuration and automatic modem selection" test_default_configuration
run_test "explicit modem and repeatable ping targets" test_explicit_modem_and_targets
run_test "invalid numeric configuration is rejected" test_invalid_numeric_configuration
run_test "invalid webhook URL is rejected" test_invalid_webhook_url
run_test "connected bearer is selected from multiple bearers" test_connected_bearer_selection
run_test "IPv4 failure falls back to an IPv6 target" test_ipv4_ipv6_target_fallback
run_test "recovery actions follow the escalation ladder" test_recovery_ladder
run_test "a failed recovery action still advances escalation" test_failed_action_still_escalates
run_test "cooldown calculations handle initial and expired values" test_cooldown_calculation
run_test "registered state honors its failure threshold" test_registered_failure_threshold
run_test "searching recovery observes its long cooldown" test_searching_recovery_and_cooldown
run_test "temporary states restart ModemManager after timeout" test_temporary_state_timeout
run_test "disabled modem enable attempts observe cooldown" test_disabled_enable_attempt_cooldown
run_test "locked modem warnings are rate limited" test_locked_notice_is_rate_limited
run_test "SIM failures suppress recovery and duplicate reports" test_sim_failure_is_safe_and_rate_limited
run_test "successful connectivity clears incident state" test_success_clears_incident
run_test "all and only HTTP 2xx webhook responses succeed" test_webhook_status_handling
run_test "webhook queue drops its oldest event at the cap" test_webhook_queue_cap
run_test "webhook delivery failures apply retry backoff" test_webhook_retry_backoff
run_test "webhook values are handed to jshn without pre-escaping" test_json_values_are_passed_to_jshn
run_test "partial webhook files are cleaned up" test_partial_file_cleanup
run_test "procd service configures respawn and real reloads" test_init_service_contract
run_test "disabling the service removes its procd instance" test_init_disabled_service_is_removed

printf '\n%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
