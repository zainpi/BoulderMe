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

    func testBlockHidesProfileChatAndInvitesBothWays() async throws {
        let backend = makeBackend()
        let before = try await backend.chats(cursor: nil).items
        let chatId = try XCTUnwrap(before.first { $0.otherMember.accountId == theo }?.chatId)
        _ = try await backend.block(accountId: theo)

        let chats = try await backend.chats(cursor: nil).items
        XCTAssertFalse(chats.contains { $0.otherMember.accountId == theo }, "A block hides the chat")
        let incoming = try await backend.invitations(box: .incoming, cursor: nil).items
        XCTAssertFalse(incoming.contains { $0.sender.accountId == theo }, "A block hides the pair's invitations")
        await assertNotFound { try await backend.profile(id: theo) }
        await assertNotFound { try await backend.chat(id: chatId) }
        await assertNotFound { try await backend.send(chatId: chatId, body: "hi", idempotencyKey: UUID()) }
        let blocks = try await backend.blocks(cursor: nil).items
        XCTAssertEqual(blocks.map(\.blockedAccountId), [theo])
    }

    func testUnblockLeavesTheChatClosed() async throws {
        let backend = makeBackend()
        _ = try await backend.block(accountId: theo)
        try await backend.unblock(accountId: theo)
        let chats = try await backend.chats(cursor: nil).items
        let chat = try XCTUnwrap(chats.first { $0.otherMember.accountId == theo })
        XCTAssertEqual(chat.status, .closed)
        XCTAssertNil(chat.upcomingSession, "The block cancelled the accepted session")
        do {
            _ = try await backend.send(chatId: chat.chatId, body: "hi", idempotencyKey: UUID())
            XCTFail("Closed chat should reject messages")
        } catch {
            XCTAssertEqual(error as? AppError, .api(.chatClosed, requestId: nil))
        }
    }

    /// The T7 "done when": invite → accept → chat → block, with the demo climber playing the other side.
    func testTwoSidedInviteAcceptChatBlock() async throws {
        let clock = TestClock(start)
        let backend = DemoBackend(now: { clock.now })
        let gym = DemoFixtures.cozyCrimp.gymId

        let sent = try await backend.create(
            InvitationInput(recipientAccountId: jun, gymId: gym, proposedStartAt: start.addingTimeInterval(2 * 86_400), note: "Roofs?"),
            idempotencyKey: UUID())
        XCTAssertEqual(sent.status, .pending)
        XCTAssertNil(sent.chatId, "No chat before acceptance")

        clock.advance(by: DemoBackend.partnerDelay)
        let accepted = try await backend.invitation(id: sent.invitationId)
        XCTAssertEqual(accepted.status, .accepted, "Jun accepts on their side")
        let chatId = try XCTUnwrap(accepted.chatId)
        let chat = try await backend.chat(id: chatId)
        XCTAssertEqual(chat.status, .open)
        XCTAssertEqual(chat.upcomingSession?.invitationId, sent.invitationId)

        let mine = try await backend.send(chatId: chatId, body: "See you there!", idempotencyKey: UUID())
        clock.advance(by: DemoBackend.partnerDelay)
        let replies = try await backend.messages(chatId: chatId, after: mine.messageId, cursor: nil).items
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.senderAccountId, jun, "Jun answers")

        _ = try await backend.block(accountId: jun)
        let afterBlock = try await backend.invitations(box: .outgoing, cursor: nil).items
        XCTAssertFalse(afterBlock.contains { $0.invitationId == sent.invitationId })
        await assertNotFound { try await backend.messages(chatId: chatId, after: nil, cursor: nil) }
        let discover = try await backend.discover(gymId: gym, filter: .any, cursor: nil).items
        XCTAssertFalse(discover.contains { $0.accountId == jun })
    }

    func testRetriedSendsAndInvitesAreIdempotent() async throws {
        let backend = makeBackend()
        let key = UUID()
        let input = InvitationInput(recipientAccountId: jun, gymId: DemoFixtures.cozyCrimp.gymId,
                                    proposedStartAt: start.addingTimeInterval(86_400))
        let first = try await backend.create(input, idempotencyKey: key)
        let replay = try await backend.create(input, idempotencyKey: key)
        XCTAssertEqual(first.invitationId, replay.invitationId)

        let chatId = DemoFixtures.id(401)
        let messageKey = UUID()
        let one = try await backend.send(chatId: chatId, body: "hey", idempotencyKey: messageKey)
        let two = try await backend.send(chatId: chatId, body: "hey", idempotencyKey: messageKey)
        XCTAssertEqual(one.messageId, two.messageId)
    }

    func testOnlyTheRecipientCanAcceptAndSenderCannotCancelAccepted() async throws {
        let backend = makeBackend()
        let sent = try await backend.invitations(box: .outgoing, cursor: nil).items
        let outgoing = try XCTUnwrap(sent.first { $0.status == .pending })
        do {
            _ = try await backend.accept(id: outgoing.invitationId)
            XCTFail("The sender can't accept")
        } catch {
            XCTAssertEqual(error as? AppError, .api(.invalidState, requestId: nil))
        }
        let cancelled = try await backend.cancel(id: outgoing.invitationId)
        XCTAssertEqual(cancelled.status, .cancelled)
    }

    func testReportsCheckTheirContext() async throws {
        let backend = makeBackend()
        let theoMessage = DemoFixtures.id(501)
        let ok = try await backend.report(ReportInput(reportedAccountId: theo, context: .message, messageId: theoMessage,
                                                      reason: .harassment), idempotencyKey: UUID())
        XCTAssertEqual(ok.context, .message)
        await assertNotFound {
            try await backend.report(ReportInput(reportedAccountId: maya, context: .message, messageId: theoMessage,
                                                 reason: .spam), idempotencyKey: UUID())
        }
    }

    private func assertNotFound<T>(_ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("Expected not_found", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AppError, .api(.notFound, requestId: nil), file: file, line: line)
        }
    }

    @MainActor
    func testEnteringDemoGivesFreshDataEachTime() async throws {
        let app = AppModel.preview()
        XCTAssertTrue(app.isDemo)
        _ = try await app.services.safety.block(accountId: theo)
        app.leaveDemo()
        XCTAssertEqual(app.mode, .welcome)
        app.enterDemo()
        let blocks = try await app.services.safety.blocks(cursor: nil).items
        XCTAssertTrue(blocks.isEmpty)
    }
}
