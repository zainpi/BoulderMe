# Feature matrix

Status keys: **Core** (in the v1 spec), **Optional** (foundation module, off unless the owner enables it), **Implemented** (merged and tested), **Placeholder** (UI or stub exists, not wired to real services), **Requires external setup** (needs an account, key or approval the owner provides).

Update the Status column in the PR that changes it. "Implemented" means server rules are tested and the iOS flow works against the real Worker, not only against demo services.

| Feature | Scope | Status | Server | iOS | Owner thread | External setup |
|---|---|---|---|---|---|---|
| Sign in with Apple | Core | Not started | T3 | T6 | T3, T6 | Apple Developer Program, Services ID/key |
| Profile & climbing fit (grades, styles, intro) | Core | Not started | T3 | T6 | T3, T6 | none |
| Gym list (Ontario seed) + suggest a gym | Core | Not started | T2, T3 | T6 | T2, T3, T6 | none |
| Gym access (membership / guest pass, self-reported) | Core | Not started | T3 | T6 | T3, T6 | none |
| Weekly availability | Core | Not started | T3 | T6 | T3, T6 | none |
| Gym discovery with filters | Core | Not started | T3 | T7 | T3, T7 | none |
| Session invitations | Core | Not started | T4 | T7 | T4, T7 | none |
| Post-acceptance chat (polling) | Core | Not started | T4 | T7 | T4, T7 | none |
| Block | Core | Not started | T4 | T7 | T4, T7 | none |
| Report + moderation runbook | Core | Not started | T4 | T7 | T4, T7 | none |
| Pause discovery | Core | Not started | T3 | T6 | T3, T6 | none |
| Edit / remove profile, gyms, availability | Core | Not started | T3 | T6 | T3, T6 | none |
| Data export | Core | Not started | T4 | T6 | T4, T6 | none |
| Account deletion (incl. Apple revocation) | Core | Not started | T4 | T6 | T4, T6 | Apple key for revocation |
| Guided onboarding (state machine, 18+, visibility explainer) | Core | Not started | n/a | T6 | T6 | none |
| Demo mode | Core | Not started | n/a | T5 | T5 | none |
| Design system (cozy, Dynamic Type, dark mode, Liquid Glass with fallback) | Core | Not started | n/a | T5 | T5 | none |
| Database schema in PulseDeals Supabase | Core | Not started | T2 | n/a | T2 | Supabase connector (connected) |
| Worker deploy (staging, production) | Core | Not started | T8 | n/a | T8 | Cloudflare account + API token |
| CI (Worker tests, `xcodebuild` on macOS) | Core | Not started | T8 | T8 | T8 | GitHub Actions |
| TestFlight build | Core | Not started | n/a | T8 | T8 | Apple Developer Program |
| Push notifications | Optional | Off | | | | APNs key |
| Subscriptions / paywall | Optional | Off | | | | App Store Connect agreements |
| Group sessions | Optional | Off | | | | |
| Realtime chat | Optional | Off | | | | |
| Profile photos | Optional | Off | | | | Storage + moderation plan |
| Gym verification | Optional | Off | | | | Gym partnerships |
| AI features, feeds, share extension, community OAuth, commerce | Optional | Off | | | | |
