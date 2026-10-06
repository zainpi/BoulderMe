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
  Services/              One protocol per API area, ServiceContainer, PendingLiveServices placeholder
  Demo/                  DemoFixtures + DemoBackend (in-memory, applies the Worker's core rules)
  Features/              Welcome, Discover, Invites, Chats, Profile
  Resources/             Assets.xcassets (AppIcon from the original brief, AccentColor)
BoulderMeTests/          Wire-format and demo-backend tests (XCTest)
```

## Conventions

- **Screens depend on protocols only.** `AppModel.services` is a `ServiceContainer`; demo mode swaps in a fresh `DemoBackend` each time, so demo data never mixes with an account's cache. `PendingLiveServices` throws `AppError.notImplemented` until T6/T7 add the URLSession client.
- **Wire format.** DTO property names are the camelCase of the wire names with `Id` (not `ID`) so `.convertFromSnakeCase` round-trips. Ids use `EntityID`, which always encodes lowercase. Required-but-nullable input fields encode `null` explicitly (see `ProfileInput`).
- **Design system.** Use `Palette`, `Spacing`, `Radius` and `Typography`; no literal colors or sizes in screens. Every color has light, dark and Increase Contrast values. Type is Dynamic Type in SF Rounded. Liquid Glass (`floatingGlass(in:)`) is for floating controls only, uses `glassEffect` on iOS 26 and a material before that, and a solid surface with Reduce Transparency.
- **States.** Data screens use `LoadState` + `LoadStateView` for loading (skeletons), empty, error (from `AppError`), offline and loaded.
- **Navigation.** Each tab owns a `NavigationStack` bound to a typed path on `Router`. Paths survive tab switches; `Router.reset()` clears them on sign-out or leaving the demo.
- **Configurations.** Debug (local Worker, bundle id suffix `.debug`), Staging (`.staging`), Release (production). `API_BASE_URL` and `BM_ENVIRONMENT` flow through Info.plist into `AppConfig`. No secrets in source; per-developer settings go in the git-ignored `Config/Local.xcconfig`.
- **Demo shortcut.** Launch argument `-BMDemo YES` opens straight into demo mode (a disabled entry is in the shared scheme).

## Build and test

```
xcodebuild -project ios/BoulderMe.xcodeproj -scheme BoulderMe \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

The Design system page (Profile → Settings → Design system, non-production builds) shows every token and component; its previews cover dark mode and accessibility text sizes.
