import XCTest
@testable import BoulderMe

final class DemoBackendTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_284_400) // 2026-10-06
    private let maya = DemoFixtures.id(11)
    private let theo = DemoFixtures.id(12)
    private let jun = DemoFixtures.id(15)
    private let rosa = DemoFixtures.id(16)

    private func makeBackend() -> DemoBackend {
        let fixed = start
        return DemoBackend(now: { fixed })
    }

    func testDiscoveryHidesPausedClimbersAndAppliesFilters() async throws {
        let backend = makeBackend()
        let all = try await backend.discover(gymId: DemoFixtures.cozyCrimp.gymId, filter: .any, cursor: nil).items
        XCTAssertFalse(all.contains { $0.accountId == rosa }, "Paused climbers never appear")
        XCTAssertTrue(all.contains { $0.accountId == maya })

        var guests = DiscoveryFilter.any
        guests.accessType = .guestPass
        let guestOnly = try await backend.discover(gymId: DemoFixtures.cozyCrimp.gymId, filter: guests, cursor: nil).items
        XCTAssertTrue(guestOnly.allSatisfy { $0.accessType == .guestPass })
        XCTAssertFalse(guestOnly.isEmpty)
    }

    func testInviteAcceptOpensChatAndAllowsMessages() async throws {
        let backend = makeBackend()
        let incoming = try await backend.invitations(box: .incoming, cursor: nil).items
        let pending = try XCTUnwrap(incoming.first { $0.status == .pending })
        let accepted = try await backend.accept(id: pending.invitationId)
        XCTAssertEqual(accepted.status, .accepted)
        let chatId = try XCTUnwrap(accepted.chatId)
        let message = try await backend.send(chatId: chatId, body: "  See you there!  ", idempotencyKey: UUID())
        XCTAssertEqual(message.body, "See you there!")
        let polled = try await backend.messages(chatId: chatId, after: nil, cursor: nil).items
        XCTAssertEqual(polled.first?.messageId, message.messageId)
    }

    func testOnlyOnePendingInvitePerPair() async throws {
        let backend = makeBackend()
        let input = InvitationInput(recipientAccountId: jun, gymId: DemoFixtures.cozyCrimp.gymId,
                                    proposedStartAt: start.addingTimeInterval(86_400))
        _ = try await backend.create(input, idempotencyKey: UUID())
        do {
            _ = try await backend.create(input, idempotencyKey: UUID())
            XCTFail("Second pending invite should fail")
        } catch {
            XCTAssertEqual(error as? AppError, .api(.invitationAlreadyOpen, requestId: nil))
        }
    }

    func testBlockHidesProfileAndClosesChat() async throws {
        let backend = makeBackend()
        _ = try await backend.block(accountId: theo)
        let chats = try await backend.chats(cursor: nil).items
        XCTAssertEqual(chats.first { $0.otherMember.accountId == theo }?.status, .closed)
        do {
            _ = try await backend.profile(id: theo)
            XCTFail("Blocked profile should be not_found")
        } catch {
            XCTAssertEqual(error as? AppError, .api(.notFound, requestId: nil))
        }
        let chatId = try XCTUnwrap(chats.first?.chatId)
        do {
            _ = try await backend.send(chatId: chatId, body: "hi", idempotencyKey: UUID())
            XCTFail("Closed chat should reject messages")
        } catch {
            XCTAssertEqual(error as? AppError, .api(.chatClosed, requestId: nil))
        }
    }

    @MainActor
    func testEnteringDemoGivesFreshDataEachTime() async throws {
        let app = AppModel(config: .preview)
        XCTAssertTrue(app.isDemo)
        _ = try await app.services.safety.block(accountId: theo)
        app.leaveDemo()
        XCTAssertEqual(app.mode, .welcome)
        app.enterDemo()
        let blocks = try await app.services.safety.blocks(cursor: nil).items
        XCTAssertTrue(blocks.isEmpty)
    }
}
