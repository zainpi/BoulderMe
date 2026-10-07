# Privacy inventory

What BoulderMe stores, who can see it, why, and how long it is kept. This is the source for the App Store privacy "nutrition label" and the in-app privacy text. Update it in the same PR as any change to stored data.

## Principles

- Collect only what partner-finding needs. No GPS or location services, no contacts, no photos in v1, no advertising or analytics SDKs, no tracking.
- Everything a member writes about their climbing and gym access is **self-reported** and labeled that way.
- What other members can see is shown to the member during onboarding before they turn discovery on.
- Members can pause discovery, edit or remove any field, export their data, and delete their account from inside the app.

## Data held

| Data | Source | Visible to | Purpose | Retention |
|---|---|---|---|---|
| Apple user identifier (`sub`), stored only as a SHA-256 hash | Sign in with Apple | Nobody (server only) | Identify the account | Until deletion; hash kept in tombstone to block resurrection |
| Apple refresh token, encrypted | Sign in with Apple | Nobody (server only) | Revoke Apple sign-in on deletion | Deleted once revocation succeeds |
| Email (incl. private relay) | Not stored | n/a | Not needed in v1 | n/a |
| Given name from Apple | First sign-in only | Pre-fills display name, then discarded | Convenience | Not stored separately |
| Display name, grade range, styles, intro | Member | All signed-in members while discoverable; invite/chat partners | Matching | Until edited or account deleted |
| 18+ confirmation, onboarding flags | Member | Nobody else | Safety gate, onboarding resume | Until account deleted |
| Gyms + access type (membership / guest pass) | Member, self-reported | All signed-in members while discoverable; partners | Matching by gym | Until removed or account deleted |
| Weekly availability | Member | All signed-in members while discoverable; partners | Matching by time | Until removed or account deleted |
| Recent activity (`last_active_on`, a date) | Server | Others see only "active recently" (14 days), never a date | Rank discovery | Overwritten daily |
| Invitations (gym, time, short note) | Member | Sender and recipient | Arrange a session | Until either account is deleted (the deleted side is anonymized) |
| Chat messages | Member | The two chat participants | Coordinate a session | Sender's messages deleted with their account |
| Blocks | Member | The blocker only | Safety | Until unblocked or account deleted |
| Reports, including a snapshot of a reported message | Member | Operator only; the reported member never learns who reported | Moderation | 1 year after resolution, then deleted; kept through account deletion so abuse can still be reviewed |
| Gym suggestions | Member | Operator only | Grow the gym list | 1 year |
| Refresh session records, installation id (hashed for rate limits) | App | Nobody | Security, rate limiting | Expired sessions purged after 30 days |
| Request logs (request id, route template, status, latency) | Worker | Operator | Debugging | Cloudflare default retention; no bodies, tokens, query values or names logged. Error messages are logged only outside production |

## On-device

- Session tokens in Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- Cached profile, gyms, invitations and chats in an account-scoped cache, wiped on sign-out or account switch. Today (T6) this holds the last `GET /v1/me` response and the unfinished onboarding draft, in `UserDefaults` under `account.<id>.` keys.
- A random installation id (`UserDefaults`), sent only with sign-in for rate limiting. It isn't tied to the account on the device and survives sign-out; deleting the app removes it.
- Network requests use an ephemeral `URLSession`: no HTTP disk cache or cookies.
- A data export is written to the app's temporary folder (complete file protection) only when the member asks for it, so they can share it.
- Demo mode uses bundled fixtures only and never talks to the server.

## Account deletion

`DELETE /v1/me` immediately blocks sign-in and hides the member everywhere, then deletes profile, gym access, availability, blocks they made, gym requests and messages they sent; cancels open invitations; closes chats; revokes all sessions and the Apple token (retried until it succeeds). Invitations and chats the other member still holds show "Deleted climber". Reports about the member are retained as described above.

## App Store privacy label (draft)

- Data linked to the user: **User Content** (profile text, messages), **Identifiers** (user id), **Other** (self-reported climbing details and gyms). Purpose: App Functionality.
- Not collected: location, contacts, contact info, health, financial, browsing, diagnostics, usage data for tracking.
- Tracking: **No**.
