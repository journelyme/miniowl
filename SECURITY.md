# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in miniowl, please **do not open a
public issue**. Instead, report it privately so we can fix it before it's
exploited.

**Preferred:** use [GitHub's private vulnerability reporting](https://github.com/journelyme/miniowl/security/advisories/new)
on this repository. Click "Report a vulnerability" in the Security tab.

**Alternative:** email <hello@journely.me> with subject `[security] miniowl: <short summary>`.

Please include:

- A clear description of the vulnerability and its impact
- Steps to reproduce
- The affected version (e.g., `v2.0.4` — see Releases)
- Any proof-of-concept code or screenshots, if relevant

## Response timeline

This is a solo-maintained side project, but security reports are taken
seriously. Expected response:

- **Acknowledgement:** within 72 hours
- **Initial assessment:** within 7 days
- **Fix or mitigation plan:** within 30 days for confirmed high/critical issues

If a vulnerability is confirmed, the reporter will be credited in the release
notes (unless they prefer to remain anonymous).

## Scope

In scope:

- The macOS client (Swift code in this repository)
- The release artifacts (signed/notarized DMG distributed via GitHub Releases)
- The pair / categorize flow that talks to `api.journely.me`

Out of scope:

- The backend API (separate repository, separate report channel)
- Vulnerabilities requiring physical access to an unlocked Mac
- Issues that require modifying the user's keychain manually

## Public assets

- Releases: <https://github.com/journelyme/miniowl/releases>
- Privacy policy: <https://miniowl.me/legal/privacy>
- Terms: <https://miniowl.me/legal/terms>
