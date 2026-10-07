import XCTest
@testable import BoulderMe

final class WireFormatTests: XCTestCase {
    func testEntityIDEncodesLowercase() throws {
        let id = EntityID(UUID(uuidString: "8F6C2C7E-1D2A-4B9E-9A3F-0123456789AB")!)
        let data = try APICoding.makeEncoder().encode([id])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["8f6c2c7e-1d2a-4b9e-9a3f-0123456789ab"]"#)
    }

    func testDecodesInvitationWithNullsAndBothTimestampForms() throws {
        let json = """
        {
          "invitation_id": "8f6c2c7e-1d2a-4b9e-9a3f-0123456789ab",
          "status": "pending",
          "sender": {"account_id": "00000000-0000-4000-8000-000000000011", "display_name": "Maya", "grade_min": 3, "grade_max": 5},
          "recipient": {"account_id": "00000000-0000-4000-8000-000000000001", "display_name": "You", "grade_min": 3, "grade_max": 5},
          "gym": {"gym_id": "00000000-0000-4000-8000-000000000101", "name": "Gym", "city": "Toronto", "region": "CA-ON",
                  "country": "CA", "address": null, "website_url": "https://example.com", "is_bouldering_only": true},
          "proposed_start_at": "2026-10-08T18:30:00Z",
          "duration_minutes": 120,
          "note": null,
          "chat_id": null,
          "created_at": "2026-10-06T10:00:00.123Z",
          "responded_at": null,
          "expires_at": "2026-10-08T18:30:00Z"
        }
        """
        let invitation = try APICoding.makeDecoder().decode(Invitation.self, from: Data(json.utf8))
        XCTAssertEqual(invitation.status, .pending)
        XCTAssertEqual(invitation.sender.displayName, "Maya")
        XCTAssertNil(invitation.chatId)
        XCTAssertEqual(invitation.gym.websiteUrl, URL(string: "https://example.com"))
        XCTAssertEqual(APICoding.formatTimestamp(invitation.proposedStartAt), "2026-10-08T18:30:00Z")
    }

    func testProfileInputEncodesNullIntroAndSnakeCase() throws {
        let input = ProfileInput(revision: 0, displayName: "Maya", gradeMin: 3, gradeMax: 5,
                                 styles: [.compStyle], intro: nil, adultConfirmed: true, discoveryExplained: true)
        let object = try JSONSerialization.jsonObject(with: APICoding.makeEncoder().encode(input)) as! [String: Any]
        XCTAssertTrue(object.keys.contains("intro"))
        XCTAssertTrue(object["intro"] is NSNull)
        XCTAssertEqual(object["display_name"] as? String, "Maya")
        XCTAssertEqual(object["styles"] as? [String], ["comp_style"])
    }

    func testErrorEnvelopeToleratesUnknownCodes() throws {
        let json = #"{"error": {"code": "brand_new_code", "message": "x", "request_id": "r1", "details": null}}"#
        let envelope = try APICoding.makeDecoder().decode(APIErrorEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.error.code, .unknown)
        XCTAssertEqual(envelope.error.requestId, "r1")
    }

    func testEnumWireValues() throws {
        let data = try APICoding.makeEncoder().encode([AccessType.guestPass])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["guest_pass"]"#)
        XCTAssertEqual(ReportReason.inappropriateContent.rawValue, "inappropriate_content")
    }
}
