import XCTest
@testable import MacParakeetCore

final class ChatGPTLiveClientTests: XCTestCase {
    func testSubscriptionRequestOmitsUnsupportedFieldsAndMovesSystemToInstructions() throws {
        let data = try ChatGPTLiveClient.requestBody(
            messages: [
                ChatMessage(role: .system, content: "Answer briefly."),
                ChatMessage(role: .user, content: "Question", modelPromptOverride: "Fresh question"),
            ], model: "discovered-model", effort: "none")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["model", "instructions", "input", "reasoning", "store", "stream"])
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["instructions"] as? String, "Answer briefly.")
        XCTAssertEqual(json["input"] as? [[String: String]], [["role": "user", "content": "Fresh question"]])
    }

    func testDeltasAreImmediateButOnlyCompletedMarksSuccess() throws {
        var decoder = ChatGPTStreamDecoder()
        XCTAssertEqual(
            try decoder.line("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}"), .ignored)
        XCTAssertEqual(try decoder.line(""), .text("Hello"))
        XCTAssertFalse(decoder.completed)
        _ = try decoder.line("data: {\"type\":\"response.completed\"}")
        XCTAssertEqual(try decoder.line(""), .completed)
        XCTAssertTrue(decoder.completed)
    }

    func testLateUsageFailureDoesNotCompletePartialResponse() throws {
        var decoder = ChatGPTStreamDecoder()
        _ = try decoder.line("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}")
        _ = try decoder.line("")
        _ = try decoder.line(
            "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}"
        )
        XCTAssertThrowsError(try decoder.line("")) { error in
            XCTAssertEqual(error as? ChatGPTLiveError, .failed("subscription_sharing_usage_limit_exceeded"))
        }
        XCTAssertFalse(decoder.completed)
    }

    func testIncompleteAndMalformedStreamsFail() throws {
        var decoder = ChatGPTStreamDecoder()
        _ = try decoder.line("data: {\"type\":\"response.incomplete\"}")
        XCTAssertThrowsError(try decoder.line("")) { XCTAssertEqual($0 as? ChatGPTLiveError, .incomplete) }
        _ = try decoder.line("data: not-json")
        XCTAssertThrowsError(try decoder.line("")) { XCTAssertEqual($0 as? ChatGPTLiveError, .malformedEvent) }
        XCTAssertFalse(decoder.completed)
    }

    func testFinalEventWithoutBlankDelimiterIsParsed() throws {
        var decoder = ChatGPTStreamDecoder()
        _ = try decoder.line(": keepalive")
        _ = try decoder.line("")
        _ = try decoder.line("data: {\"type\":\"response.completed\"}")
        XCTAssertEqual(try decoder.flush(), .completed)
    }

    func testRealSSEByteFramingPreservesBlankLinesAndSplitUnicode() throws {
        var decoder = ChatGPTStreamDecoder()
        let wire =
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Café 🙂\"}\r\n\r\ndata: {\"type\":\"response.completed\"}\n\n"
        var events: [ChatGPTStreamDecoder.Event] = []
        for byte in wire.utf8 {
            let event = try decoder.byte(byte)
            if event != .ignored { events.append(event) }
        }
        XCTAssertEqual(events, [.text("Café 🙂"), .completed])
        XCTAssertTrue(decoder.completed)
    }

    func testServerErrorCodeCannotLeakArbitraryText() {
        XCTAssertEqual(ChatGPTStreamDecoder.safeCode("secret or prompt with spaces"), "unknown_error")
        XCTAssertEqual(
            ChatGPTStreamDecoder.safeCode("subscription_sharing_usage_unavailable"),
            "subscription_sharing_usage_unavailable")
    }
}
