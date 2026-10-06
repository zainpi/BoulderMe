# ios/

SwiftUI app, iOS 17+. Built in T5 (shell, design system, demo mode), T6 (onboarding, profile, gyms, settings) and T7 (discovery, invitations, chat, safety).

- `BoulderMe/Resources/AppIcon-1024.png` is the 1024×1024 app icon from the original brief; T5 wires it into the asset catalog.
- Screens follow `docs/screen-map.md`; network DTOs follow `docs/api/openapi.yaml`.
- Configurations: Debug (local Worker), Staging, Production via `.xcconfig`. No secrets in source.
