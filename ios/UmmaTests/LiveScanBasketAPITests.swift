import Foundation
import XCTest
@testable import Umma

enum LiveScanBasketFixtures {
    static let scanID = UUID(uuidString: "7c9e6679-7425-40de-944b-e07fc1f90ae7")!

    static func result(_ name: String, status: LiveScanItemStatus = .new, canonical: String? = nil,
                       confidence: LiveScanConfidence = .high) -> LiveScanItemResult {
        LiveScanItemResult(status: status, key: canonical ?? name, canonicalName: canonical ?? name,
                           displayName: name, confidence: confidence, existingPantryItemId: nil)
    }

    static let itemJSON = """
    {"status":"new","key":"soy sauce","canonical_name":"soy sauce","display_name":"shoyu","confidence":"high",
     "existing_pantry_item_id":null}
    """

    static var finishedJSON: String {
        #"{"saved":["# + PantryFixtures.itemJSON(raw: "eggs", normalized: "egg", source: "live", confidence: "0.9") + """
        ],"review":[
          {"status":"new","key":"gochujang","canonical_name":"gochujang","display_name":"gochujang","confidence":"medium",
           "existing_pantry_item_id":null,"reason":"unsure"},
          {"status":"in_pantry","key":"butter","canonical_name":"butter","display_name":"butter","confidence":"high",
           "existing_pantry_item_id":"\(PantryFixtures.onionId)","reason":"in_pantry"},
          {"status":"merged","key":"x","canonical_name":"x","display_name":"x","confidence":"certain","reason":"later"}
        ]}
        """
    }

    static func rateLimited() -> APIError {
        .server(status: 429, code: "RATE_LIMITED", message: "Too many live scans in the last hour; try again later",
                retryable: true, correlationId: nil)
    }
}

/// Basket endpoints through the `URLProtocol` stub, and the DTOs' conservative decoding.
final class LiveScanBasketAPITests: XCTestCase {
    private func makeClient() -> APIClient {
        APIClient(session: StubURLProtocol.makeSession(),
                  baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://stub.test:8000")),
                  tokenProvider: InMemoryTokenStore(token: "tok"))
    }

    func testBasketEndpointsSendAndDecodeTheContract() async throws {
        let scan = LiveScanBasketFixtures.scanID.uuidString.lowercased()
        let base = "/v1/pantry/live-scans"
        StubURLProtocol.install { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("POST", base):
                return (.stub(request, status: 201), Data(#"{"id":"\#(scan)","demo":true,"expires_at":"2026-11-15T10:00:00Z"}"#.utf8))
            case ("POST", "\(base)/\(scan)/items"):
                return (.stub(request, status: 200), Data(LiveScanBasketFixtures.itemJSON.utf8))
            case ("DELETE", "\(base)/\(scan)/items/soy sauce"):
                return (.stub(request, status: 204), Data())
            case ("POST", "\(base)/\(scan)/finish"):
                return (.stub(request, status: 200), Data(LiveScanBasketFixtures.finishedJSON.utf8))
            default:
                return (.stub(request, status: 404), Data())
            }
        }
        let client = makeClient()

        let created = try await client.createLiveScan(demo: false)
        XCTAssertEqual(created.id, LiveScanBasketFixtures.scanID)
        XCTAssertTrue(created.demo, "the server's demo flag wins")
        XCTAssertEqual(try StubURLProtocol.requests[0].jsonBody()["demo"] as? Bool, false)

        let item = try await client.addLiveScanItem(
            scanID: created.id, LiveScanItemReport(name: "shoyu", kind: nil, confidence: .medium))
        XCTAssertEqual(item, LiveScanItemResult(status: .new, key: "soy sauce", canonicalName: "soy sauce",
                                                displayName: "shoyu", confidence: .high, existingPantryItemId: nil))
        let body = try StubURLProtocol.requests[1].jsonBody()
        XCTAssertEqual(body["name"] as? String, "shoyu")
        XCTAssertEqual(body["confidence"] as? String, "medium")
        XCTAssertNil(body["kind"], "an absent kind is left out (the server forbids unknown keys, not missing ones)")

        try await client.removeLiveScanItem(scanID: created.id, key: "soy sauce")
        XCTAssertEqual(StubURLProtocol.requests[2].httpMethod, "DELETE")

        let finished = try await client.finishLiveScan(scanID: created.id)
        XCTAssertEqual(finished.saved.map(\.rawLabel), ["eggs"])
        XCTAssertEqual(finished.saved.first?.source, .other, "`live` is a source this build shows neutrally")
        XCTAssertEqual(finished.review.map(\.reason), [.unsure, .inPantry, .unknown])
        XCTAssertEqual(finished.review.map(\.status), [.new, .inPantry, .unknown], "an unknown status never crashes")
        XCTAssertEqual(finished.review.last?.confidence, .unknown)
        XCTAssertEqual(StubURLProtocol.requests.count, 4)
    }

    func testTokenRequestCarriesTheBasketAndADemoAnswerDecodes() async throws {
        let demoJSON = """
        {"token":null,"model":"gemini-3.8-live","expires_at":null,"new_session_expires_at":null,"max_session_seconds":30,
         "nudge_text":"Report any new items now visible.","nudge_every_frames":2,"frame_max_fps":1.0,"demo":true,
         "ai_notice":{"reason":"user_live_daily_cap","message":"Today's live scan allowance is used up"}}
        """
        StubURLProtocol.install { request in (.stub(request, status: 200), Data(demoJSON.utf8)) }
        let long = String(repeating: "a", count: 80)
        let token = try await makeClient().liveScanToken(alreadyInBasket: ["eggs", long])
        XCTAssertTrue(token.demo)
        XCTAssertEqual(token.token, "")
        XCTAssertEqual(token.maxSessionSeconds, 30)
        let names = try XCTUnwrap(try StubURLProtocol.requests[0].jsonBody()["already_in_basket"] as? [String])
        XCTAssertEqual(names, ["eggs", String(repeating: "a", count: 60)])

        let missing = demoJSON.replacingOccurrences(of: #""demo":true"#, with: #""demo":false"#)
        XCTAssertThrowsError(try JSONCoding.makeDecoder().decode(LiveScanToken.self, from: Data(missing.utf8)),
                             "a real token without a token is not usable")
    }
}
