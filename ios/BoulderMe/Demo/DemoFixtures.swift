import Foundation

/// Synthetic data for demo mode. Fictional climbers at two fictional gyms; no
/// real people or places. Never mixed with an account's cache.
enum DemoFixtures {
    static let region = "CA-ON"

    static func id(_ n: Int) -> EntityID {
        EntityID(String(format: "00000000-0000-4000-8000-%012ld", n))!
    }

    static let meId = id(1)

    static let cozyCrimp = Gym(
        gymId: id(101), name: "Cozy Crimp Collective (demo)", city: "Toronto", region: region,
        country: "CA", address: nil, websiteUrl: nil, isBoulderingOnly: true)
    static let sloperSocial = Gym(
        gymId: id(102), name: "Sloper Social Club (demo)", city: "Hamilton", region: region,
        country: "CA", address: nil, websiteUrl: nil, isBoulderingOnly: true)
    static let gyms = [cozyCrimp, sloperSocial]

    struct Climber {
        var profile: PublicProfile
        var discoverable: Bool
    }

    static func climbers(now: Date) -> [Climber] {
        func access(_ gym: Gym, _ type: AccessType) -> GymAccess {
            GymAccess(gym: gym, accessType: type, selfReported: true, updatedAt: now)
        }
        func slot(_ n: Int, _ day: Weekday, _ start: Int, _ end: Int, gym: Gym? = nil) -> AvailabilitySlot {
            AvailabilitySlot(slotId: id(1000 + n), weekday: day, startMinute: start, endMinute: end,
                             timeZone: "America/Toronto", gymId: gym?.gymId)
        }
        return [
            Climber(profile: PublicProfile(
                accountId: id(11), displayName: "Maya", gradeMin: 3, gradeMax: 5,
                styles: [.slab, .technical, .crimps],
                intro: "Slab lover, snack sharer. Looking for a Tuesday crew.",
                gyms: [access(cozyCrimp, .membership)],
                availability: [slot(1, .tuesday, 1080, 1260), slot(2, .saturday, 600, 780)],
                activeRecently: true), discoverable: true),
            Climber(profile: PublicProfile(
                accountId: id(12), displayName: "Theo", gradeMin: 4, gradeMax: 6,
                styles: [.overhang, .power, .dynamic],
                intro: "Projecting the purple cave. Happy to spot and cheer.",
                gyms: [access(cozyCrimp, .membership), access(sloperSocial, .guestPass)],
                availability: [slot(3, .wednesday, 1080, 1260), slot(4, .sunday, 780, 960)],
                activeRecently: true), discoverable: true),
            Climber(profile: PublicProfile(
                accountId: id(13), displayName: "Priya", gradeMin: 2, gradeMax: 4,
                styles: [.vertical, .slopers],
                intro: "Newish to bouldering and keen to learn footwork.",
                gyms: [access(cozyCrimp, .guestPass)],
                availability: [slot(5, .monday, 420, 540), slot(6, .thursday, 420, 540)],
                activeRecently: true), discoverable: true),
            Climber(profile: PublicProfile(
                accountId: id(14), displayName: "Sam", gradeMin: 6, gradeMax: 8,
                styles: [.compStyle, .dynamic, .pinches],
                intro: "Comp-style coordination nerd. Will share beta.",
                gyms: [access(sloperSocial, .membership)],
                availability: [slot(7, .friday, 1110, 1290)],
                activeRecently: false), discoverable: true),
            Climber(profile: PublicProfile(
                accountId: id(15), displayName: "Jun", gradeMin: 3, gradeMax: 6,
                styles: [.roof, .highball, .power],
                intro: nil,
                gyms: [access(cozyCrimp, .membership), access(sloperSocial, .membership)],
                availability: [slot(8, .saturday, 780, 960)],
                activeRecently: true), discoverable: true),
            Climber(profile: PublicProfile(
                accountId: id(16), displayName: "Rosa", gradeMin: 1, gradeMax: 3,
                styles: [.slab, .vertical],
                intro: "Paused for a bit while my finger heals.",
                gyms: [access(cozyCrimp, .membership)],
                availability: [],
                activeRecently: false), discoverable: false),
        ]
    }

    static func me(now: Date) -> OwnProfile {
        OwnProfile(
            accountId: meId, revision: 1, displayName: "You (demo)", gradeMin: 3, gradeMax: 5,
            styles: [.slab, .overhang, .crimps], intro: "Exploring BoulderMe in demo mode.",
            discoverable: true, adultConfirmed: true, discoveryExplained: true, updatedAt: now)
    }

    static func myGyms(now: Date) -> [GymAccess] {
        [GymAccess(gym: cozyCrimp, accessType: .membership, selfReported: true, updatedAt: now),
         GymAccess(gym: sloperSocial, accessType: .guestPass, selfReported: true, updatedAt: now)]
    }

    static func mySlots() -> [AvailabilitySlot] {
        [AvailabilitySlot(slotId: id(2001), weekday: .tuesday, startMinute: 1080, endMinute: 1260,
                          timeZone: "America/Toronto", gymId: nil),
         AvailabilitySlot(slotId: id(2002), weekday: .saturday, startMinute: 600, endMinute: 780,
                          timeZone: "America/Toronto", gymId: cozyCrimp.gymId)]
    }
}
