# ios/

SwiftUI app, iOS 17+, Xcode 16+. Built in T5 (shell, design system, demo mode), T6 (onboarding, profile, gyms, settings) and T7 (discovery, invitations, chat, safety).

## Layout

```
BoulderMe.xcodeproj      Folder-synced project: new files under BoulderMe/ or BoulderMeTests/ are picked up automatically
Config/                  Base/Debug/Staging/Release .xcconfig, Info.plist keys, Local.xcconfig.example
BoulderMe/
  App/                   Composition root (BoulderMeApp), AppModel, AppConfig
  Navigation/            AppTab, typed Route enums per tab, Router, RootView + MainTabView
  DesignSystem/          Palette, Tokens (spacing, radius, type, motion), Components/, DesignSystemGallery
  Models/                DTOs mirroring docs/api/openapi.yaml, APICoding (snake_case, RFC 3339), AppError
  Services/              One protocol per API area, ServiceContainer, PendingLiveServices (T7 areas)
    Live/                APIClient (single-flight refresh), LiveServices, KeychainSessionStore,
                         AccountCache (per-account, wiped on sign-out), Sign in with Apple
  Demo/                  DemoFixtures + DemoBackend (in-memory, applies the Worker's core rules)
  Features/              Welcome, Onboarding, Discover, Invites, Chats, Profile, Gyms, Availability, Settings
  Resources/             Assets.xcassets (AppIcon from the original brief, AccentColor)
BoulderMeTests/          Wire-format and demo-backend tests (XCTest)
```

## Conventions

- **Screens depend on protocols only.** `AppModel.services` is a `ServiceContainer`; demo mode swaps in a fresh `DemoBackend` each time, so demo data never mixes with an account's cache. Signed in, `LiveServices` covers every area. `PendingLiveServices` (every call throws `AppError.notImplemented`) is only for previews.
- **Demo climbers play the other side.** In demo mode an invite you send is accepted after `DemoBackend.partnerDelay` seconds and your messages get a reply, so one person can walk through invite → accept → chat → block. Blocks, `not_found` hiding and closed chats follow the Worker's rules.
- **Safety.** Report (`ReportSheet`) and block (`blockConfirmation`) are reachable from a profile, an invitation and a chat (long-press a message to report it). Both are silent. After a block the screen pops and `AppModel.didBlock()` bumps `blockRevision`, which Discover, Invites and Chats key their loads on. Settings → Blocked climbers unblocks.
- **Chat polling.** `ChatThreadModel` polls `after` the newest message every 5 seconds while the thread is on screen and the app is active, re-reads the chat every 6 polls (or when something new arrives) to catch a close, and pages back with `cursor`. Sends and invites reuse their `Idempotency-Key` when retried after a network failure.
- **Sessions.** `APIClient` (an actor) adds the bearer token and refreshes it single-flight: concurrent requests with a stale token share one `POST /v1/auth/refresh`. A rejected refresh or `account_deleted` clears the Keychain and `AppModel` returns to Welcome with a note. Offline never signs anyone out.
- **App modes.** `launching → welcome | onboarding | account`, plus `demo`. Onboarding resumes from `GET /v1/me`'s `onboarding` checklist (`OnboardingPlan`), plus two device-only choices (skipped availability, "Not now" on discovery).
- **Sign in with Apple** is entitled in Staging and Release (`Config/BoulderMe.entitlements`). Debug leaves it off so free teams can build; add `CODE_SIGN_ENTITLEMENTS = Config/BoulderMe.entitlements` to `Local.xcconfig` to try it.
- **Wire format.** DTO property names are the camelCase of the wire names with `Id` (not `ID`) so `.convertFromSnakeCase` round-trips. Ids use `EntityID`, which always encodes lowercase. Required-but-nullable input fields encode `null` explicitly (see `ProfileInput`).
- **Design system.** Use `Palette`, `Spacing`, `Radius` and `Typography`; no literal colors or sizes in screens. Every color has light, dark and Increase Contrast values. Type is Dynamic Type in SF Rounded. Liquid Glass (`floatingGlass(in:)`) is for floating controls only, uses `glassEffect` on iOS 26 and a material before that, and a solid surface with Reduce Transparency.
- **States.** Data screens use `LoadState` + `LoadStateView` for loading (skeletons), empty, error (from `AppError`), offline and loaded.
- **Navigation.** Each tab owns a `NavigationStack` bound to a typed path on `Router`. Paths survive tab switches; `Router.reset()` clears them on sign-out or leaving the demo. `Router.openChat` and `Router.openInvitation` jump across tabs. Discover's gym and filters are kept per account in `AccountCache`.
- **Configurations.** Debug (local Worker, bundle id suffix `.debug`), Staging (`.staging`), Release (production). `API_BASE_URL` and `BM_ENVIRONMENT` flow through Info.plist into `AppConfig`. No secrets in source; per-developer settings go in the git-ignored `Config/Local.xcconfig`.
- **Demo shortcut.** Launch argument `-BMDemo YES` opens straight into demo mode (a disabled entry is in the shared scheme).

## Build and test

```
xcodebuild -project ios/BoulderMe.xcodeproj -scheme BoulderMe \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The Design system page (Profile → Settings → Design system, non-production builds) shows every token and component; its previews cover dark mode and accessibility text sizes.
