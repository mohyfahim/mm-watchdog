# mm-watchdog

`mm-watchdog` is an OpenWrt service that keeps a ModemManager-backed cellular
connection usable when coverage changes frequently. It is intended for moving
routers in trains, buses, vehicles, and other installations where registration
and data sessions may repeatedly disappear and return.

The watchdog verifies real Internet reachability through the active modem
bearer. When a failure persists, it escalates through increasingly disruptive
recovery actions while applying cooldowns to protect the modem:

1. Recreate the netifd connection with `ifdown` and `ifup`.
2. Restart ModemManager.
3. Disconnect and cycle the modem radio.
4. Reset the modem.

SIM lock and permanent SIM error states are never reset automatically.

## Requirements

- OpenWrt 24.10 or 25.12
- One modem managed by ModemManager
- A netifd interface using `proto 'modemmanager'`
- The modem-specific OpenWrt kernel modules and ModemManager plugin

The package installs ModemManager, `jshn`, `uclient-fetch`, and the system CA
bundle as direct dependencies. ModemManager must be built with netifd support.

Only one modem and one logical network interface are managed by each watchdog
instance. Multi-modem routing and mwan coordination are outside this project's
scope.

## Build and install

Place this repository in an OpenWrt source tree or SDK as
`package/mm-watchdog`. Ensure the packages feed is available so that
ModemManager can be selected, then run:

```sh
./scripts/feeds update packages
./scripts/feeds install modemmanager
make menuconfig
make package/mm-watchdog/compile V=s
```

Select **Network → mm-watchdog** in `menuconfig`. Install the resulting package
with the package manager used by the target OpenWrt release, or include it in a
firmware image.

After installation:

```sh
uci set mm-watchdog.main.interface='wwan'
uci commit mm-watchdog
/etc/init.d/mm-watchdog enable
/etc/init.d/mm-watchdog start
```

## ModemManager network interface

The logical interface named by `mm-watchdog.main.interface` must exist in
`/etc/config/network`. A typical configuration is:

```uci
config interface 'wwan'
	option proto 'modemmanager'
	option device '/sys/devices/platform/.../usb1/1-1'
	option apn 'your-apn'
	option iptype 'ipv4v6'
	option force_connection '1'
```

When `modem` is `auto`, the watchdog uses this interface's `device` value as
the `mmcli --modem` selector. This keeps recovery attached to the correct modem
instead of whichever device ModemManager happens to return first. An mmcli
index, object path, device path, or unique identifier may be configured
explicitly when automatic selection is unsuitable.

## Configuration

The defaults in `/etc/config/mm-watchdog` are conservative and suitable as a
starting point.

| Option | Default | Description |
| --- | ---: | --- |
| `enabled` | `1` | Run the watchdog. |
| `interface` | `wwan` | Logical netifd ModemManager interface. |
| `modem` | `auto` | Modem selector, or `auto` to use the interface device. |
| `check_interval` | `5` | Seconds between health checks. |
| `ping_timeout` | `2` | Timeout for each ICMP probe. |
| `ping_target` | `1.1.1.1`, `8.8.8.8` | Repeatable IPv4, IPv6, or hostname target. |
| `modemmanager_fail_limit` | `3` | Failed modem queries before recovery. |
| `connected_fail_limit` | `3` | Failed probes while connected before recovery. |
| `registered_fail_limit` | `3` | Registered-without-data checks before recovery. |
| `searching_recovery_after` | `180` | Seconds of continuous searching before a radio cycle. |
| `searching_recovery_cooldown` | `600` | Minimum seconds between searching recoveries. |
| `temporary_state_timeout` | `120` | Maximum time in a transitional modem state. |
| `enabled_state_timeout` | `60` | Maximum enabled-but-not-registering time. |
| `action_grace` | `20` | Settling time after a recovery action. |
| `mm_restart_cooldown` | `120` | Minimum seconds between ModemManager restarts. |
| `radio_cycle_cooldown` | `120` | Minimum seconds between radio cycles or enable attempts. |
| `modem_reset_cooldown` | `600` | Minimum seconds between modem resets. |
| `webhook_enabled` | `0` | Queue and deliver event webhooks. |
| `webhook_url` | empty | HTTP or HTTPS event endpoint. |
| `webhook_timeout` | `5` | Maximum webhook request time. |
| `webhook_retry_interval` | `60` | Backoff after a delivery failure. |
| `webhook_queue_limit` | `20` | Maximum volatile queued events. |
| `report_startup` | `1` | Queue service startup events. |
| `report_recovery` | `1` | Queue recovery and recovered events. |
| `report_errors` | `1` | Queue watchdog error events. |

Every numeric value is validated at startup. Intervals, timeouts, limits, and
queue size must be positive; cooldowns may be zero. Invalid configuration makes
the daemon exit with an error instead of running an unsafe recovery loop.

Connectivity succeeds when any target answers through the bearer interface.
IPv6 literals are sent through `ping6`; all other values use `ping`.

Apply configuration changes with:

```sh
uci commit mm-watchdog
/etc/init.d/mm-watchdog reload
```

## Webhook events

Webhooks are disabled by default. Events are written to a mode-0700 queue in
`/tmp/mm-watchdog/events`, so they do not write to flash and do not delay an
offline recovery action. At most one queued event is sent during each healthy
loop. The queue is intentionally lost on reboot, and the oldest event is
dropped when the configured limit is reached.

The version 1 payload has this shape:

```json
{
  "schema_version": 1,
  "service": "mm-watchdog",
  "event": "internet-recovered",
  "severity": "info",
  "time": {
    "timestamp": "2026-09-16T12:00:00Z",
    "uptime_seconds": 3600
  },
  "device": {
    "hostname": "vehicle-router",
    "network_interface": "wwan",
    "modem_selector": "/sys/devices/platform/..."
  },
  "incident": {
    "id": "1758024000-1234",
    "age_seconds": 45
  },
  "recovery": {
    "reason": "connectivity-restored",
    "action": "radio-cycle",
    "level": 3
  },
  "modem": {
    "state": "connected",
    "registration": "home",
    "signal_quality": "67",
    "access_technology": "lte",
    "packet_service": "attached"
  },
  "bearer": {
    "path": "/org/freedesktop/ModemManager1/Bearer/2",
    "interface": "wwan0",
    "connected": "yes"
  },
  "connectivity": {
    "reachable": true
  }
}
```

The payload deliberately excludes APNs, credentials, SIM identifiers, raw
system logs, and kernel logs. Treat the remaining device and network metadata
as potentially sensitive and use a trusted, access-controlled HTTPS endpoint.

`uclient-fetch` reports some valid statuses such as HTTP 201 as an error. The
watchdog recognizes every HTTP 2xx response as successful and keeps other
failures queued for retry.

## Operations and troubleshooting

Useful commands:

```sh
/etc/init.d/mm-watchdog status
/etc/init.d/mm-watchdog restart
logread -e mm-watchdog
mmcli --list-modems
mmcli --modem "$(uci -q get network.wwan.device)" --output-keyvalue
```

If the service will not remain running, check `logread` for configuration
validation errors. Also verify that the logical interface uses the
`modemmanager` protocol, has a `device`, and has `force_connection '1'`.

Frequent hard recovery usually means the failure thresholds are too small for
the route's expected coverage gaps. Increase the searching and reset cooldowns
before reducing them.

## Upgrade from the private configuration

This first public configuration is intentionally not backward compatible:

- `api_enabled`, `api_url`, and `api_timeout` became `webhook_enabled`,
  `webhook_url`, and `webhook_timeout`.
- `api_name`, `api_type`, raw diagnostic limits, and log collection options
  were removed.
- `ping_targets` became repeatable `list ping_target` entries.
- `modem` and `radio_cycle_cooldown` are new.
- The webhook JSON is the documented version 1 schema above.

Review and replace the UCI file when upgrading instead of retaining the old
conffile unchanged.

## Hardware acceptance checklist

Before deployment, verify on the target modem and firmware:

- normal boot, service reload, disable, and re-enable;
- loss and restoration of IP reachability while the bearer stays connected;
- bearer disconnection and netifd reconnection;
- extended searching with the configured cooldown;
- ModemManager restart and modem object reappearance;
- radio disable/enable and modem reset recovery;
- a locked, missing, or faulty SIM does not trigger destructive recovery;
- queued webhooks flush after connectivity returns;
- TERM stops the daemon without leaving partial queue files.

## Development

Run the local checks with:

```sh
sh tests/test.sh
sh -n files/usr/sbin/modem-watchdog files/usr/lib/mm-watchdog/*.sh
shellcheck -s sh -x files/usr/sbin/modem-watchdog files/usr/lib/mm-watchdog/*.sh files/etc/init.d/mm-watchdog
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for development expectations and
[SECURITY.md](SECURITY.md) for vulnerability reporting.

## License

Copyright holders license this project under
[GPL-2.0-or-later](LICENSE).
