# Contributing

Contributions that improve modem compatibility, recovery safety, tests, or
documentation are welcome.

## Before opening a change

For behavior changes, describe the OpenWrt release, modem model, connection
protocol, observed ModemManager state, and relevant redacted `logread` output.
Never include APN credentials, SIM identifiers, webhook secrets, or other
private device data.

Keep the daemon compatible with POSIX shell and BusyBox `ash`. Avoid Bash-only
syntax and new runtime dependencies unless their storage and compatibility
cost is justified.

## Validation

Run these checks before submitting a pull request:

```sh
sh tests/test.sh
sh -n files/usr/sbin/modem-watchdog files/usr/lib/mm-watchdog/*.sh
shellcheck -s sh -x files/usr/sbin/modem-watchdog files/usr/lib/mm-watchdog/*.sh files/etc/init.d/mm-watchdog
```

Changes to recovery behavior must include mocked regression coverage. Changes
to UCI options or webhook fields must update the README and must explain the
compatibility impact.

Hardware testing is strongly encouraged. Include the completed relevant items
from the README's hardware acceptance checklist in the pull request.

## Style

- Use tabs for shell indentation and OpenWrt Makefile recipes.
- Quote expansions unless intentional word splitting is documented.
- Check expected command failures explicitly; do not enable global `set -e`.
- Keep network reporting best-effort and out of the recovery critical path.
- Add SPDX license identifiers to new source files.
