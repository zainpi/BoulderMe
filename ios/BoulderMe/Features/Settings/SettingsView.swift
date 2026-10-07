import SwiftUI

/// Discovery, your data, sign out, account deletion, links and app info.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var discoverable: Bool?
    @State private var discoveryError: AppError?
    @State private var updatingDiscovery = false
    @State private var exportFile: URL?
    @State private var exporting = false
    @State private var exportError: AppError?
    @State private var confirmSignOut = false
    @State private var signingOut = false

    var body: some View {
        List {
            if app.isDemo {
                Section {
                    Button("Leave the demo", role: .destructive) { app.leaveDemo() }
                } footer: {
                    Text("Demo data is made up and stays on this device. Leaving resets it.")
                }
            }
            discoverySection
            Section("Safety") {
                NavigationLink("Blocked climbers", value: ProfileRoute.blockedClimbers)
                Button("Safety tips") { app.router.sheet = .safetyTips }
            }
            dataSection
            if !app.isDemo {
                Section {
                    Button(signingOut ? "Signing out…" : "Sign out") { confirmSignOut = true }
                        .disabled(signingOut)
                    NavigationLink(value: ProfileRoute.deleteAccount) {
                        Text("Delete account").foregroundStyle(Palette.danger)
                    }
                }
            }
            Section("About") {
                Link("Privacy policy", destination: app.config.privacyURL)
                Link("Terms of use", destination: app.config.termsURL)
                Link("Contact support", destination: app.config.supportURL)
                LabeledContent("Version", value: "\(app.config.version) (\(app.config.build))")
                if app.config.environment != .production {
                    LabeledContent("Environment", value: app.config.environment.rawValue)
                    NavigationLink("Design system", value: ProfileRoute.designSystem)
                }
            }
        }
        .font(Typography.body)
        .cozyNavigation(title: "Settings")
        .confirmationDialog("Sign out of BoulderMe?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task {
                    signingOut = true
                    await app.signOut()
                    signingOut = false
                }
            }
        } message: {
            Text("Your profile stays as it is. Data saved on this iPhone is cleared.")
        }
        .task { await loadDiscovery() }
    }

    private var discoverySection: some View {
        Section {
            if let discoverable {
                Toggle("Show me in discovery", isOn: Binding(
                    get: { discoverable },
                    set: { value in Task { await setDiscoverable(value) } }))
                    .tint(Palette.accent)
                    .disabled(updatingDiscovery)
            } else {
                HStack {
                    Text("Show me in discovery")
                    Spacer()
                    ProgressView()
                }
            }
            if let discoveryError {
                Text(discoveryError.userMessage).font(Typography.caption).foregroundStyle(Palette.danger)
            }
        } header: {
            Text("Privacy & visibility")
        } footer: {
            Text("When paused, you disappear from discovery and can't get new invites. Open chats stay open.")
        }
    }

    private var dataSection: some View {
        Section {
            if let exportFile {
                ShareLink(item: exportFile) {
                    Label("Share export file", systemImage: "square.and.arrow.up")
                }
            } else {
                Button(exporting ? "Preparing export…" : "Export my data") { Task { await export() } }
                    .disabled(exporting)
            }
            if let exportError {
                Text(exportError.userMessage).font(Typography.caption).foregroundStyle(Palette.danger)
            }
        } header: {
            Text("Your data")
        } footer: {
            Text("A JSON file with your profile, gyms, availability, invitations, chats, blocks and reports.")
        }
    }

    private func loadDiscovery() async {
        do {
            discoverable = try await app.services.account.me().profile?.discoverable ?? false
            discoveryError = nil
        } catch {
            discoveryError = error.asAppError
        }
    }

    private func setDiscoverable(_ value: Bool) async {
        updatingDiscovery = true
        defer { updatingDiscovery = false }
        do {
            discoverable = try await app.services.profiles.setDiscoverable(value).discoverable
            discoveryError = nil
        } catch {
            discoveryError = error.asAppError
        }
    }

    private func export() async {
        exporting = true
        defer { exporting = false }
        do {
            let data = try await app.services.account.exportData()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("BoulderMe-export.json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            exportFile = url
            exportError = nil
        } catch {
            exportError = error.asAppError
        }
    }
}

/// Explains what deletion removes and keeps, then asks for DELETE to be typed.
struct DeleteAccountView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmation = ""
    @State private var deleting = false
    @State private var error: AppError?

    private var confirmed: Bool { confirmation.trimmingCharacters(in: .whitespaces) == "DELETE" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CozyCard {
                    Label("Deleted right away", systemImage: "trash.fill")
                        .font(Typography.headline).foregroundStyle(Palette.danger)
                    bullet("Your profile disappears from discovery and profiles.")
                    bullet("Your gyms, availability, blocks and gym suggestions.")
                    bullet("Messages you sent. Open invitations are cancelled and chats close.")
                    bullet("Every sign-in on every device, and the link to your Apple ID.")
                }
                CozyCard {
                    Label("Kept", systemImage: "archivebox.fill")
                        .font(Typography.headline).foregroundStyle(Palette.ink)
                    bullet("Reports about your account, so safety reviews can finish. They're removed a year after they're resolved.")
                    bullet("Other climbers keep their side of past invitations, shown as \"Deleted climber\".")
                }
                Text("This can't be undone. If you might come back, you can pause discovery in Settings instead, or export your data first.")
                    .font(Typography.body).foregroundStyle(Palette.inkSecondary)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Type DELETE to confirm").font(Typography.headline).foregroundStyle(Palette.ink)
                    TextField("DELETE", text: $confirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .cozyField()
                }
                if let error {
                    Text(error.userMessage).font(Typography.callout).foregroundStyle(Palette.danger)
                }
                Button(deleting ? "Deleting…" : "Delete my account") { Task { await delete() } }
                    .buttonStyle(.cozyDestructive)
                    .disabled(!confirmed || deleting || app.isDemo)
                    .opacity(!confirmed || app.isDemo ? 0.5 : 1)
                if app.isDemo {
                    Text(AppError.requiresAccount.userMessage).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                }
            }
            .padding(Spacing.m)
        }
        .scrollDismissesKeyboard(.interactively)
        .cozyNavigation(title: "Delete account")
    }

    private func bullet(_ text: String) -> some View {
        Label {
            Text(text).font(Typography.body).foregroundStyle(Palette.ink)
        } icon: {
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(Palette.inkSecondary)
        }
    }

    private func delete() async {
        deleting = true
        defer { deleting = false }
        do {
            try await app.deleteAccount()
        } catch {
            self.error = error.asAppError
        }
    }
}
