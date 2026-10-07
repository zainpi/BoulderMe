import XCTest
@testable import BoulderMe

/// Request shapes for the T7 routes (discovery, invitations, chats, safety) and
/// the pure logic behind their screens.
final class SocialServicesTests: XCTestCase {
    private let base = URL(string: "http://localhost:8787")!
    private let chatId = EntityID(UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")!)
    private let otherId = EntityID(UUID(uuidString: "00000000-0000-4000-8000-0000000000b2")!)

    private func services(_ handler: @escaping FakeTransport.Handler) -> (LiveServices, FakeTransport) {
        let transport = FakeTransport(handler)
        let client = APIClient(baseURL: base, transport: transport, store: InMemorySessionStore(Wire.session("a")),
                               installationId: EntityID(UUID(uuidString: "00000000-0000-4000-8000-0000000000f1")!))
        return (LiveServices(client: client), transport)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testDiscoverySendsOnlyTheFiltersThatAreSet() async throws {
        let (live, transport) = services { _ in (200, Wire.json(Page<ProfileCard>(items: []))) }
        var filter = DiscoveryFilter.any
        filter.gradeMin = 3
        filter.accessType = .guestPass
        filter.weekday = .tuesday
        _ = try await live.discover(gymId: DemoFixtures.cozyCrimp.gymId, filter: filter, cursor: "next")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/discovery")
        let params = query(request)
        XCTAssertEqual(params["gym_id"], DemoFixtures.cozyCrimp.gymId.description)
        XCTAssertEqual(params["grade_min"], "3")
        XCTAssertNil(params["grade_max"])
        XCTAssertEqual(params["access_type"], "guest_pass")
        XCTAssertEqual(params["weekday"], "2")
        XCTAssertNil(params["time_of_day"])
        XCTAssertEqual(params["cursor"], "next")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Installation-Id"), "00000000-0000-4000-8000-0000000000f1")
    }

    func testCreateInvitationSendsKeyAndExplicitNullNote() async throws {
        let invitation = Self.invitation(status: .pending)
        let (live, transport) = services { _ in (201, Wire.json(invitation)) }
        let key = UUID()
        _ = try await live.create(InvitationInput(recipientAccountId: otherId, gymId: DemoFixtures.cozyCrimp.gymId,
                                                  proposedStartAt: Date(timeIntervalSince1970: 1_791_500_000)),
                                  idempotencyKey: key)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/invitations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), key.uuidString.lowercased())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["recipient_account_id"] as? String, otherId.description)
        XCTAssertEqual(body["duration_minutes"] as? Int, 120)
        XCTAssertTrue(body.keys.contains("note"))
        XCTAssertTrue(body["note"] is NSNull)
    }

    func testInvitationActionsAndListUseTheirRoutes() async throws {
        let accepted = Self.invitation(status: .accepted)
        let (live, transport) = services { request in
            request.url?.path == "/v1/invitations"
                ? (200, Wire.json(Page(items: [accepted])))
                : (200, Wire.json(accepted))
        }
        let id = accepted.invitationId
        _ = try await live.invitations(box: .outgoing, cursor: nil)
        _ = try await live.accept(id: id)
        _ = try await live.decline(id: id)
        _ = try await live.cancel(id: id)
        let calls = transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        XCTAssertEqual(calls, [
            "GET /v1/invitations",
            "POST /v1/invitations/\(id)/accept",
            "POST /v1/invitations/\(id)/decline",
            "POST /v1/invitations/\(id)/cancel",
        ])
        XCTAssertEqual(query(transport.requests[0])["box"], "outgoing")
    }

    func testPollingUsesAfterAndNeverACursor() async throws {
        let (live, transport) = services { _ in (200, Wire.json(Page<Message>(items: []))) }
        let after = EntityID()
        _ = try await live.messages(chatId: chatId, after: after, cursor: "ignored")
        _ = try await live.messages(chatId: chatId, after: nil, cursor: "older")
        let poll = query(transport.requests[0])
        XCTAssertEqual(poll["after"], after.description)
        XCTAssertNil(poll["cursor"], "`after` and `cursor` can't be combined")
        let page = query(transport.requests[1])
        XCTAssertEqual(page["cursor"], "older")
        XCTAssertNil(page["after"])
    }

    func testBlockUnblockAndReport() async throws {
        let block = Block(blockedAccountId: otherId, displayName: "Maya", createdAt: Date(timeIntervalSince1970: 1_791_284_400))
        let report = Report(reportId: EntityID(), reportedAccountId: otherId, context: .message, reason: "spam",
                            status: .open, createdAt: Date(timeIntervalSince1970: 1_791_284_400))
        let (live, transport) = services { request in
            switch (request.httpMethod, request.url?.path) {
            case ("PUT", _): return (200, Wire.json(block))
            case ("DELETE", _): return (204, Data())
            default: return (201, Wire.json(report))
            }
        }
        _ = try await live.block(accountId: otherId)
        try await live.unblock(accountId: otherId)
        let messageId = EntityID()
        _ = try await live.report(ReportInput(reportedAccountId: otherId, context: .message, messageId: messageId,
                                              reason: .spam), idempotencyKey: UUID())
        XCTAssertEqual(transport.requests[0].url?.path, "/v1/blocks/\(otherId)")
        XCTAssertEqual(transport.requests[1].httpMethod, "DELETE")
        let reportRequest = transport.requests[2]
        XCTAssertEqual(reportRequest.url?.path, "/v1/reports")
        XCTAssertNotNil(reportRequest.value(forHTTPHeaderField: "Idempotency-Key"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(reportRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["context"] as? String, "message")
        XCTAssertEqual(body["message_id"] as? String, messageId.description)
        XCTAssertTrue(body["invitation_id"] is NSNull)
        XCTAssertTrue(body["details"] is NSNull)
    }

    func testDeletedMemberDecodesWithNullGrades() throws {
        let json = #"{"account_id":"00000000-0000-4000-8000-0000000000b2","display_name":"Deleted climber","grade_min":null,"grade_max":null}"#
        let party = try APICoding.makeDecoder().decode(InvitationParty.self, from: Data(json.utf8))
        XCTAssertTrue(party.isDeleted)
        XCTAssertEqual(party.displayName, "Deleted climber")
    }

    func testInvitationSections() {
        let now = Date(timeIntervalSince1970: 1_791_284_400)
        var pending = Self.invitation(status: .pending, start: now.addingTimeInterval(86_400))
        var stale = Self.invitation(status: .pending, start: now.addingTimeInterval(-60))
        stale.invitationId = EntityID()
        var upcoming = Self.invitation(status: .accepted, start: now.addingTimeInterval(-600)) // Still on: 2 hours long.
        upcoming.invitationId = EntityID()
        var declined = Self.invitation(status: .declined, start: now.addingTimeInterval(86_400))
        declined.invitationId = EntityID()
        pending.invitationId = EntityID()
        let sections = InvitationSections([pending, stale, upcoming, declined], now: now)
        XCTAssertEqual(sections.pending.map(\.id), [pending.id])
        XCTAssertEqual(sections.upcoming.map(\.id), [upcoming.id])
        XCTAssertEqual(Set(sections.past.map(\.id)), [stale.id, declined.id])
    }

    @MainActor
    func testChatMergeKeepsOrderAndDropsDuplicates() {
        let model = ChatThreadModel()
        let t0 = Date(timeIntervalSince1970: 1_791_284_400)
        func message(_ n: Int, _ offset: TimeInterval) -> Message {
            Message(messageId: DemoFixtures.id(900 + n), chatId: chatId, senderAccountId: otherId, body: "\(n)",
                    createdAt: t0.addingTimeInterval(offset))
        }
        model.merge([message(3, 30), message(2, 20)])
        model.merge([message(1, 10), message(3, 30), message(4, 40)])
        XCTAssertEqual(model.messages.map(\.body), ["1", "2", "3", "4"])
        XCTAssertTrue(ChatThreadModel.showsTime(at: 0, in: model.messages))
        XCTAssertFalse(ChatThreadModel.showsTime(at: 1, in: model.messages))
    }

    func testInviteWindowMatchesTheWorker() {
        let now = Date(timeIntervalSince1970: 1_791_284_400)
        let range = InviteSheet.allowedRange(now: now)
        XCTAssertGreaterThanOrEqual(range.lowerBound.timeIntervalSince(now), 3_600)
        XCTAssertLessThanOrEqual(range.upperBound.timeIntervalSince(now), 60 * 86_400)
        XCTAssertEqual(InviteSheet.durationLabel(90), "1 h 30 min")
        XCTAssertEqual(InviteSheet.durationLabel(120), "2 hours")
    }

    static func invitation(status: InvitationStatus, start: Date = Date(timeIntervalSince1970: 1_791_500_000)) -> Invitation {
        let me = InvitationParty(accountId: Wire.accountId, displayName: "Sam", gradeMin: 2, gradeMax: 5)
        let other = InvitationParty(accountId: EntityID(UUID(uuidString: "00000000-0000-4000-8000-0000000000b2")!),
                                    displayName: "Maya", gradeMin: 3, gradeMax: 5)
        return Invitation(
            invitationId: EntityID(UUID(uuidString: "00000000-0000-4000-8000-0000000000d1")!), status: status,
            sender: me, recipient: other, gym: DemoFixtures.cozyCrimp, proposedStartAt: start, durationMinutes: 120,
            note: nil, chatId: status == .accepted ? EntityID() : nil, createdAt: start.addingTimeInterval(-86_400),
            respondedAt: nil, expiresAt: start)
    }
}
