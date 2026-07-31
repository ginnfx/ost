# Security Policy

## Reporting a vulnerability

If you discover a security vulnerability in Lume, please report it **privately** —
do not open a public issue, pull request, or discussion, as that may put users at
risk before a fix is available.

Use one of the following:

- **GitHub private advisory** (preferred): open a report at
  <https://github.com/bilipp/Lume/security/advisories/new>
- **Email**: p.bischoff@innoloft.com

Please include, as far as you can:

- A description of the issue and its impact
- Steps to reproduce, or a proof of concept
- The affected platform(s) and app/OS version
- Any suggested remediation

You can expect an initial acknowledgement within **5 business days**. We will keep
you informed of progress toward a fix and will credit you in the release notes once
the issue is resolved, unless you prefer to remain anonymous.

## Scope

Lume is a **client-side player** — it ships with no servers, no bundled streams,
and no backend of its own. Relevant areas include:

- Handling of user-supplied Xtream Codes credentials and M3U playlist URLs
- Secure storage of credentials and OAuth tokens (Keychain)
- The local SwiftData catalog and the CloudKit user-data mirror
- Build tooling and the secret-injection script (`Scripts/inject-env.sh`)

Out of scope: the security of third-party IPTV providers, playlists, or streams that
a user chooses to connect to. See [`ANTI_PIRACY.md`](ANTI_PIRACY.md) for content policy.

## Supported versions

Lume is actively developed and security fixes target the **latest released version**.
Please make sure you are on the most recent build before reporting.
