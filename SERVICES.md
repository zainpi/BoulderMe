# Services

Every external service BoulderMe uses. Prices and free limits are as understood on 2026-10-06; check the linked pricing pages before relying on them.

| Service | What it does here | Required? | Owner | Cost | Free limits that matter | Credentials (names only) | Stored in | Connection test |
|---|---|---|---|---|---|---|---|---|
| GitHub | Hosts `zainpi/BoulderMe`, runs CI | Required | owlz | Free (private repo) | Actions minutes: macOS minutes count 10× against the free allowance | `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` (as Actions secrets) | GitHub encrypted secrets | `contracts` workflow green |
| Supabase (PulseDeals project) | Postgres for schema `boulderme` | Required | owlz (org "runsIT") | $0 on the current free plan | 500 MB database shared with PulseDeals; pooler connection caps; project pauses after a week of inactivity; no PITR | `DATABASE_URL` (role `boulderme_api`) | Worker secret | `GET /v1/health` returns `database: ok` |
| Cloudflare Workers | Runs the API | Required | owlz | $0 free plan; $5/month paid plan if needed | 100,000 requests/day; CPU time per request limits | `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | GitHub secrets; local `wrangler login` | `wrangler whoami`, then `wrangler deploy --dry-run` |
| Apple Developer Program | Sign in with Apple, TestFlight, App Store | Required for real sign-in and release (not for demo mode) | owlz | $99 USD/year | n/a | `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`, `APPLE_BUNDLE_ID` | Worker secrets; Xcode signing on the owner's Mac | A real sign-in on a device creates an account |
| Xcode (owner's Mac) | Builds and runs the iOS app | Required | owlz | Free | Needs a Mac with a current Xcode | none | n/a | `xcodebuild -version` |

Worker-only secrets that are generated, not provided by a service: `ACCESS_TOKEN_SIGNING_KEY`, `APPLE_TOKEN_ENCRYPTION_KEY`, `RATE_LIMIT_SALT`. Generate each with `openssl rand -base64 32` and set with `wrangler secret put <NAME>`.

## Expected monthly cost

Assumption: 0 to 500 monthly active members in Ontario.

- **Running cost: $0 to $25 USD/month.** Most likely $0 while both PulseDeals and BoulderMe fit Supabase's free plan and the Worker stays under 100k requests/day.
- **One-time / yearly:** Apple Developer Program $99 USD/year.
- **What raises cost:** PulseDeals + BoulderMe together outgrowing the free database (Supabase Pro is about $25/month per org), chat polling pushing past 100k Worker requests/day (Workers Paid is about $5/month), or adding push notifications, photos or realtime later.

## Not used

Supabase Auth, Supabase Storage, PostgREST access to `boulderme`, analytics or ad SDKs, push notifications, payments.
