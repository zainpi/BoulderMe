import Observation
import SwiftUI

/// Onboarding steps after Sign in with Apple, in order (docs/screen-map.md).
enum OnboardingStep: Int, CaseIterable, Codable, Comparable, Sendable {
    case basics, climbing, gyms, availability, visibility, discovery

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .basics: "Say hi"
        case .climbing: "How you climb"
        case .gyms: "Your gyms"
        case .availability: "When you climb"
        case .visibility: "Who can see you"
        case .discovery: "Ready to be found?"
        }
    }

    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
}

/// Choices that only live on the device (the server can't tell "skipped" from "not reached yet").
struct OnboardingProgress: Codable, Equatable, Sendable {
    var skippedAvailability = false
    var discoveryDecided = false
}

/// Where to resume, from the server's `onboarding` checklist plus local choices.
enum OnboardingPlan {
    /// The first step still to do, or `nil` when onboarding is complete.
    static func resumeStep(me: Me, progress: OnboardingProgress) -> OnboardingStep? {
        let checklist = me.onboarding
        if !checklist.hasProfile || me.profile == nil { return .basics }
        if !checklist.hasGym { return .gyms }
        if !checklist.hasAvailability && !progress.skippedAvailability { return .availability }
        if !checklist.adultConfirmed || !checklist.discoveryExplained { return .visibility }
        if me.profile?.discoverable != true && !progress.discoveryDecided { return .discovery }
        return nil
    }
}

/// Profile fields being filled in, saved on the device so a half-finished
/// step survives quitting the app.
struct ProfileDraft: Codable, Equatable, Sendable {
    var displayName = ""
    var intro = ""
    var gradeMin: Grade = 2
    var gradeMax: Grade = 4
    var styles: [ClimbingStyle] = []
    var adultConfirmed = false

    init() {}

    init(profile: OwnProfile) {
        displayName = profile.displayName
        intro = profile.intro ?? ""
        gradeMin = profile.gradeMin
        gradeMax = profile.gradeMax
        styles = profile.styles
        adultConfirmed = profile.adultConfirmed
    }

    static let nameLimit = 40
    static let introLimit = 280

    var trimmedName: String { displayName.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedIntro: String? {
        let value = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var nameIsValid: Bool { !trimmedName.isEmpty && trimmedName.count <= Self.nameLimit }
    var introIsValid: Bool { intro.count <= Self.introLimit }
    var gradesAreValid: Bool { Grades.range.contains(gradeMin) && Grades.range.contains(gradeMax) && gradeMin <= gradeMax }
    var isValid: Bool { nameIsValid && introIsValid && gradesAreValid && styles.count <= ClimbingStyle.maxSelected }

    func input(revision: Int, discoveryExplained: Bool) -> ProfileInput {
        ProfileInput(revision: revision, displayName: trimmedName, gradeMin: gradeMin, gradeMax: gradeMax,
                     styles: styles, intro: trimmedIntro, adultConfirmed: adultConfirmed,
                     discoveryExplained: discoveryExplained)
    }

    mutating func toggle(_ style: ClimbingStyle) {
        if let index = styles.firstIndex(of: style) {
            styles.remove(at: index)
        } else if styles.count < ClimbingStyle.maxSelected {
            styles.append(style)
        }
    }
}

/// Drives the onboarding screens. Each step's primary action saves what it
/// owns, then moves on; Back revisits earlier steps without losing anything.
@MainActor
@Observable
final class OnboardingModel {
    private(set) var step: OnboardingStep
    private(set) var profile: OwnProfile?
    private(set) var gyms: [GymAccess]
    var draft: ProfileDraft {
        didSet { cache.set(draft, for: "onboarding.draft") }
    }
    private(set) var isWorking = false
    var error: AppError?

    let services: ServiceContainer
    private let cache: AccountCache
    private var progress: OnboardingProgress {
        didSet { cache.set(progress, for: "onboarding.progress") }
    }

    init(me: Me, start: OnboardingStep, services: ServiceContainer, cache: AccountCache, givenName: String?) {
        self.step = start
        self.profile = me.profile
        self.gyms = me.gyms
        self.services = services
        self.cache = cache
        self.progress = cache.value("onboarding.progress") ?? OnboardingProgress()
        if let saved: ProfileDraft = cache.value("onboarding.draft") {
            self.draft = saved
        } else if let profile = me.profile {
            self.draft = ProfileDraft(profile: profile)
        } else {
            var fresh = ProfileDraft()
            fresh.displayName = String((givenName ?? "").prefix(ProfileDraft.nameLimit))
            self.draft = fresh
        }
    }

    var stepNumber: Int { step.rawValue + 1 }
    var stepCount: Int { OnboardingStep.allCases.count }
    var canGoBack: Bool { step.previous != nil && !isWorking }

    /// Whether the primary button is enabled on the current step.
    var canContinue: Bool {
        guard !isWorking else { return false }
        switch step {
        case .basics: return draft.nameIsValid && draft.introIsValid && draft.adultConfirmed
        case .climbing: return draft.isValid
        case .gyms: return !gyms.isEmpty
        case .availability, .visibility, .discovery: return true
        }
    }

    /// The card other members will see, built from what's been entered so far.
    func previewCard(slots: [AvailabilitySlot]) -> ProfileCard {
        ProfileCard(
            accountId: profile?.accountId ?? EntityID(), displayName: draft.trimmedName.isEmpty ? "You" : draft.trimmedName,
            gradeMin: draft.gradeMin, gradeMax: draft.gradeMax, styles: draft.styles,
            accessType: gyms.first?.accessType ?? .membership,
            availabilitySummary: slots.map { AvailabilitySummaryItem(weekday: $0.weekday, timeOfDay: $0.timeOfDay) },
            activeRecently: true)
    }

    func back() {
        guard let previous = step.previous else { return }
        error = nil
        step = previous
    }

    func gymsChanged(_ gyms: [GymAccess]) {
        self.gyms = gyms
    }

    /// Runs the current step's action. Returns `true` when onboarding is complete.
    @discardableResult
    func advance() async -> Bool {
        guard canContinue else { return false }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            switch step {
            case .basics, .gyms:
                break
            case .availability:
                progress.skippedAvailability = false
            case .climbing:
                try await saveProfile(discoveryExplained: profile?.discoveryExplained ?? false)
            case .visibility:
                try await saveProfile(discoveryExplained: true)
            case .discovery:
                return true
            }
            if let next = step.next { step = next }
            return false
        } catch {
            self.error = error.asAppError
            return false
        }
    }

    func skipAvailability() {
        progress.skippedAvailability = true
        if let next = step.next { step = next }
    }

    /// Last step. `on == false` keeps discovery paused ("Not now").
    func chooseDiscovery(_ on: Bool) async -> Bool {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            if on || profile?.discoverable == true {
                profile = try await services.profiles.setDiscoverable(on)
            }
            progress.discoveryDecided = true
            cache.set(nil as ProfileDraft?, for: "onboarding.draft")
            return true
        } catch {
            self.error = error.asAppError
            return false
        }
    }

    private func saveProfile(discoveryExplained: Bool) async throws {
        let input = draft.input(revision: profile?.revision ?? 0, discoveryExplained: discoveryExplained)
        do {
            profile = try await services.profiles.saveProfile(input)
        } catch AppError.api(.revisionConflict, _) {
            // Saved from another device mid-onboarding: take its revision and keep this draft.
            let me = try await services.account.me()
            profile = me.profile
            profile = try await services.profiles.saveProfile(
                draft.input(revision: me.profile?.revision ?? 0, discoveryExplained: discoveryExplained))
        }
    }
}
