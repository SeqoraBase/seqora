# Security Policy

## Reporting a Vulnerability

**Do NOT open a public issue for security vulnerabilities.**

Report vulnerabilities through one of these channels:

- **Email:** security@seqorabase.com
- **GitHub Security Advisories:** [Create a new advisory](https://github.com/SeqoraBase/seqora/security/advisories/new)

Include as much detail as possible: affected contract(s), reproduction steps, potential impact, and any suggested fix.

## Scope

**In scope:**

- Smart contracts in `contracts/src/`
- Deployment scripts in `contracts/script/`
- Frontend application in `frontend/`

**Out of scope:**

- Third-party dependencies (report upstream)
- Test files in `contracts/test/`
- Documentation and configuration files

## Response Timeline

| Stage | Target |
|---|---|
| Acknowledgement | Within 48 hours |
| Triage and severity assessment | Within 7 days |
| Fix deployed (critical/high) | Within 30 days |

We will keep reporters informed of progress throughout the process.

## Bug Bounty

A formal bug bounty program is planned for post-mainnet launch. In the meantime, we recognize and credit all valid reporters in release notes and the project's security hall of fame.

## Supported Versions

| Version | Supported |
|---|---|
| `main` branch (latest) | Yes |
| Older tags / releases | No |

Only the latest code on `main` is actively maintained. If you discover a vulnerability in an older version, please verify it still exists on `main` before reporting.

## Safe Harbor

We consider security research conducted in good faith to be authorized and will not pursue legal action against researchers who:

- Make a good faith effort to avoid privacy violations, data destruction, and service disruption.
- Only interact with accounts they own or with explicit permission of the account holder.
- Report vulnerabilities through the channels listed above.
- Allow reasonable time for remediation before public disclosure.

We will work with researchers to understand and resolve issues quickly, and we will not take legal action against individuals who discover and report vulnerabilities in accordance with this policy.
