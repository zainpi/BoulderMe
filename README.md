# BoulderMe

A cozy, playful iPhone app for boulderers to find similarly skilled partners at the gyms they climb at. Set your grade range, styles, availability and gyms (membership or guest pass, self-reported), discover climbers who've opted in, send a one-to-one session invite, and chat once it's accepted. Block, report, pause discovery or delete your account any time. No GPS, no verification, no feeds.

Launch region: Ontario, Canada.

## Repository layout

| Path | What's there |
|---|---|
| `ios/` | SwiftUI app (iOS 17+) |
| `api/` | Cloudflare Worker, TypeScript REST API under `/v1` |
| `db/` | Postgres migrations for schema `boulderme` in the PulseDeals Supabase project |
| `docs/api/openapi.yaml` | **The API contract.** Server and client both follow it |
| `docs/adr/` | Architecture decisions ([0001](docs/adr/0001-architecture.md)) |
| `docs/domain-model.md` | Server records, invitation state machine, visibility rules |
| `docs/screen-map.md` | Every screen, its entry points, primary action and states |
| `docs/feature-matrix.md` | What's core, optional, implemented or waiting on setup |
| `docs/privacy-inventory.md` | What data is stored, who sees it, how long |
| `docs/threat-model.md` | Security and people-safety risks and mitigations |
| `SETUP.md` | How to get a local and staging environment running |
| `SERVICES.md` | Every external service, cost, and where its credentials live |
| `OPERATIONS.md` | Backups, moderation, health checks, deletion, rollback |
| [`FOLLOW_UP_PROMPTS.md`](FOLLOW_UP_PROMPTS.md) | Ready-to-copy prompts for the next steps |

## Status

Contracts and docs are in place. Backend (`api/`, `db/`) and iOS (`ios/`) are being built next; see `docs/feature-matrix.md` for live status.

## Quick checks

```sh
# Lint the API contract
npx -y @redocly/cli@2 lint docs/api/openapi.yaml
```
