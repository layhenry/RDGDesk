# Security Policy

## Supported versions

Security fixes are applied to the latest version on the default branch.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature for this repository. Do not open a public issue for a suspected vulnerability.

Include only the minimum information needed to reproduce the problem. Remove passwords, usernames, server addresses, `.rdg` contents, certificate pins, Keychain data, and connection logs that identify real infrastructure.

## Security model

- RDCMan DPAPI password blobs are not decrypted on macOS and are removed from persisted library snapshots.
- Passwords are stored as macOS Keychain generic-password items; configuration files contain only metadata and binding identifiers.
- Certificates require explicit trust on first use or fingerprint change.
- Clipboard upload is explicit, text-only, and limited to 1 MB.
- Real-server and real-Keychain integration tests are opt-in through environment variables.

Ad-hoc packaged builds are not notarized. Public binary releases should use Apple Developer ID signing, hardened runtime, notarization, and an auditable release process.
