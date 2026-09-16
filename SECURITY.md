# Security policy

## Supported versions

Security fixes are provided for the latest released version of `mm-watchdog`.
Development snapshots may change without compatibility guarantees.

## Reporting a vulnerability

Once this project is hosted on GitHub, report vulnerabilities privately with
the repository's **Security → Report a vulnerability** feature. Do not open a
public issue for vulnerabilities involving command execution, credential
exposure, unsafe modem operations, or webhook data disclosure.

Include the affected OpenWrt and package versions, a minimal reproduction, and
the expected impact. Remove device credentials, SIM identifiers, and production
endpoint details from the report.

## Operational considerations

- The service runs as root because modem, netifd, and service recovery require
  administrative access.
- Webhooks are opt-in and should use a trusted, access-controlled HTTPS endpoint.
- Queued event files are root-only and live in volatile `/tmp` storage.
- UCI configuration files may contain endpoint secrets and should remain
  readable only by trusted administrators.
