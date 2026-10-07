# Screen map

SwiftUI, iOS 17+. A `TabView` with four tabs, each with its own `NavigationStack` and typed `Route` enum. Focused tasks are sheets that return to where they were opened. Tab selection, navigation paths, scroll position and Discover filters are preserved when switching tabs.

```
App launch
├─ Onboarding (fullScreenCover, until complete)
│   Welcome → [Explore demo] or [Sign in with Apple]
│   → Profile basics → Grades & styles → Gyms & access → Availability
│   → Who can see you (explainer + 18+) → Discovery on/off → Done
└─ Main TabView
    ├─ Discover    : GymPicker · Filters · Results · ProfileDetail → InviteSheet
    ├─ Invites     : Incoming / Outgoing · InvitationDetail
    ├─ Chats       : ChatList · ChatThread
    └─ Profile     : MyProfile · EditProfile · MyGyms · Availability · Settings
                     Settings → Privacy & visibility · Blocked climbers · Export · Delete account · About
Global sheets: ReportSheet, BlockConfirm, SuggestGymSheet, SafetyTips
```

Every data screen implements five states: **loading** (skeleton cards, not spinners on cozy surfaces), **empty** (friendly illustration + one action), **error** (message from error code + Retry), **offline** (cached data with a "last updated" note, writes disabled with a reason), **success**.

Data source is the protocol service named; in demo mode the same protocol is backed by fixtures.

## Onboarding

| Screen | Entry points | Primary action | Data source | Requires | Notes on states |
|---|---|---|---|---|---|
| Welcome | First launch, after sign-out, after deletion | Sign in with Apple | none | none | Secondary "Explore demo" enters demo mode. Shows a playful preview card stack |
| Sign in (system sheet) | Welcome, any gated action in demo | Continue with Apple | `AuthService` | Network | Cancel returns quietly; failure shows inline retry and keeps the draft |
| Profile basics | Onboarding step 1 | Next | local draft → `ProfileService` | Signed in | Display name prefilled from Apple's given name when supplied |
| Grades & styles | Step 2 | Next | local draft | Signed in | V0 to V17 range slider; style chips (max 6) |
| Gyms & access | Step 3 | Next | `GymService.list/search` | Signed in | Each gym: Membership / Guest pass segmented choice, "self-reported" caption. Empty search → Suggest a gym. Max 10 |
| Availability | Step 4 | Next (Skip allowed) | local draft | Signed in | Weekday × morning/afternoon/evening grid, optional precise times |
| Who can see you | Step 5 | I'm 18+ and understand | none | Signed in | Shows exactly the ProfileCard others will see |
| Discovery on/off | Step 6 | Turn on discovery | `ProfileService.setDiscovery` | Profile complete, ≥1 gym | "Not now" keeps it paused; can change in Settings |

Onboarding is a state machine (`OnboardingStep` enum) persisted per account; it resumes from the server `onboarding` checklist in `GET /v1/me`.

## Discover tab

| Screen | Entry points | Primary action | Data source | Requires | Notes on states |
|---|---|---|---|---|---|
| Discover home | Tab | Pick a gym | `DiscoveryService` | Signed in or demo | Defaults to the member's first gym. Empty: "No one's here yet. Invite a friend or try another gym." Paused banner when own discovery is off |
| Filters (sheet) | Discover toolbar | Apply | local | none | Grade range, access type, weekday, time of day. Persisted per account |
| Profile detail | Discover result, invitation, chat header | Invite to climb | `ProfileService.get` | Signed in | Toolbar menu: Report, Block. Hidden/blocked → "This climber isn't available" |
| Invite sheet | Profile detail | Send invite | `InvitationService.create` | Shared gym, complete profile | Gym picker limited to shared gyms, date/time picker (1h to 60d ahead), optional note. `invitation_already_open` → link to existing invite |

## Invites tab

| Screen | Entry points | Primary action | Data source | Requires | Notes on states |
|---|---|---|---|---|---|
| Invites list | Tab (badge = pending incoming) | Open an invite | `InvitationService.list` | Signed in | Segmented Incoming / Outgoing; sections Pending, Upcoming, Past |
| Invitation detail | Invites list, chat header | Accept (incoming) / Cancel (outgoing) | `InvitationService.get` | Signed in | Decline, Report, Block secondary. Accept → navigates to the chat |

## Chats tab

| Screen | Entry points | Primary action | Data source | Requires | Notes on states |
|---|---|---|---|---|---|
| Chat list | Tab (badge = unread) | Open a chat | `ChatService.list` | Signed in | Empty: "Chats open once an invite is accepted." |
| Chat thread | Chat list, accepted invitation | Send message | `ChatService.messages/send` | Chat `open` | Polls every 5s while visible. Upcoming session pinned at top. Closed chat: read-only with explanation. Long-press message → Report. Safety tips link |

## Profile tab

| Screen | Entry points | Primary action | Data source | Requires | Notes on states |
|---|---|---|---|---|---|
| My profile | Tab | Edit profile | `ProfileService.me` | Signed in | Preview of own ProfileCard; discovery status pill |
| Edit profile | My profile | Save | `ProfileService.upsert` | Signed in | `revision_conflict` → choose keep mine / use server |
| My gyms | My profile | Add gym | `GymService` | Signed in | Swipe to remove (with undo) |
| Availability | My profile | Add time | `AvailabilityService` | Signed in | Grid editor |
| Settings | My profile | n/a | various | Signed in | Discovery toggle, Blocked climbers, Export my data, Sign out, Delete account, Privacy, Terms, Support, version |
| Blocked climbers | Settings | Unblock | `SafetyService.blocks` | Signed in | Empty: "You haven't blocked anyone." |
| Delete account | Settings | Delete account | `AccountService.delete` | Signed in | Explains what is deleted and kept; type DELETE to confirm; then returns to Welcome |

## Global sheets

| Sheet | Opened from | Primary action | Data source | Notes |
|---|---|---|---|---|
| Report | Profile detail, invitation, message | Send report | `SafetyService.report` | Reason list, optional details; offers "Also block" toggle |
| Block confirm | Profile detail, invitation, chat | Block | `SafetyService.block` | Explains it's silent and closes the chat |
| Suggest a gym | Gym search empty state | Send | `GymService.request` | Name, city, province prefilled to Ontario |
| Safety tips | Chat thread, invite sheet | Got it | static | Meet at the gym, tell a friend, report concerns |

## Demo mode

Entered from Welcome. A persistent "Demo" label in the navigation bar; fixtures include a handful of synthetic climbers at two fictional gyms. The demo climbers play their side: invites you send are accepted after a few seconds and your messages get a reply, so the whole invite → accept → chat → block flow works without an account. Any action needing a real account opens Sign in and returns to the action afterwards. Demo data never mixes with an account's cache.
