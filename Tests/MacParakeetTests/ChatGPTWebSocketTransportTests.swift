import XCTest
@testable import MacParakeetCore

private final class SocketFixture: ChatGPTWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private let batches: [[Data]?]
    private var queue: [Data] = []
    private var receiver: CheckedContinuation<Data, Error>?
    private var pong: CheckedContinuation<Void, Error>?
    private var pingCalls = 0
    private var failPing = false
    private var holdPing = false
    private var closed = false
    private var sent: [String] = []
    private var cancellations = 0
    init(_ batches: [[Data]?]) { self.batches = batches }
    var isReusable: Bool { lock.withLock { !closed } }
    var sendCount: Int { lock.withLock { sent.count } }
    var pingCount: Int { lock.withLock { pingCalls } }
    func simulateHalfOpen() { lock.withLock { failPing = true } }
    func holdPongs() { lock.withLock { holdPing = true } }
    func closeWhileIdle() { lock.withLock { closed = true } }
    var cancelCount: Int { lock.withLock { cancellations } }
    var payloads: [String] { lock.withLock { sent } }
    func ping() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<Void, Error>? = lock.withLock {
                pingCalls += 1
                if closed { return .failure(CancellationError()) }
                if failPing { return .failure(URLError(.networkConnectionLost)) }
                if holdPing {
                    precondition(pong == nil, "Overlapping pings crossed the socket lease")
                    pong = continuation
                    return nil
                }
                return .success(())
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }
    func send(_ text: String) async throws {
        let batch: [Data]? = try lock.withLock {
            guard !closed else { throw CancellationError() }
            let index = sent.count
            sent.append(text)
            return index < batches.count ? batches[index] : nil
        }
        if let batch { push(batch) }
    }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<Data, Error>? = lock.withLock {
                if closed { return .failure(CancellationError()) }
                if !queue.isEmpty { return .success(queue.removeFirst()) }
                precondition(receiver == nil, "Two readers crossed the exclusive socket lease")
                receiver = continuation
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }
    func push(_ events: [Data]) {
        let delivery: (CheckedContinuation<Data, Error>, Data)? = lock.withLock {
            guard !closed else { return nil }
            queue += events
            guard let receiver, !queue.isEmpty else { return nil }
            self.receiver = nil
            return (receiver, queue.removeFirst())
        }
        if let delivery { delivery.0.resume(returning: delivery.1) }
    }
    func cancel() {
        let pending = lock.withLock {
            cancellations += 1; closed = true; queue.removeAll()
            let pending = (receiver, pong); receiver = nil; pong = nil; return pending
        }
        pending.0?.resume(throwing: CancellationError())
        pending.1?.resume(throwing: CancellationError())
    }
}

private final class SocketConnectorFixture: ChatGPTWebSocketConnecting, @unchecked Sendable {
    private let lock = NSLock()
    let sockets: [SocketFixture]
    private var calls = 0
    init(_ sockets: [SocketFixture]) { self.sockets = sockets }
    var count: Int { lock.withLock { calls } }
    func connect(token: String) throws -> any ChatGPTWebSocket {
        try lock.withLock {
            let index = calls; calls += 1
            guard index < sockets.count else { throw ChatGPTLiveError.failed("fixture_missing_socket") }
            return sockets[index]
        }
    }
}

private final class SocketTestValues: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 10_000)
    private var values: [String] = []
    private var authorizations = 0
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
    func append(_ text: String) { lock.withLock { values.append(text) } }
    var output: [String] { lock.withLock { values } }
    func authorized() { lock.withLock { authorizations += 1 } }
    var authorizationCount: Int { lock.withLock { authorizations } }
}

private actor SocketAuthorizationGate {
    private var waiting: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async { entered = true; await withCheckedContinuation { waiting = $0 } }
    func open() { waiting?.resume(); waiting = nil }
}

private func socketEvent(_ type: String, _ fields: [String: Any] = [:]) -> Data {
    var object = fields; object["type"] = type
    return try! JSONSerialization.data(withJSONObject: object)
}
private func socketResponse(_ id: String, _ text: String = "A useful answer.") -> [Data] {
    [
        socketEvent("response.created", ["response": ["id": id, "status": "in_progress"]]),
        socketEvent("response.output_text.delta", ["delta": text]),
        socketEvent("response.completed", ["response": ["id": id, "status": "completed"]]),
    ]
}
private func fixtureToken(expiry: Date) -> String {
    let claims = try! JSONSerialization.data(withJSONObject: ["exp": expiry.timeIntervalSince1970])
    let encoded = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "fixture.\(encoded).not-a-real-signature"
}

@MainActor
final class ChatGPTWebSocketTransportTests: XCTestCase {
    private func waitUntil(_ check: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await check()), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(2)) }
        let fulfilled = await check()
        XCTAssertTrue(fulfilled)
    }

    func testWireBodyKeepsFullHistoryAndOmitsUnsupportedFields() throws {
        let messages = [
            ChatMessage(role: .system, content: "Keep the approval condition."),
            ChatMessage(role: .user, content: "Previous question"),
            ChatMessage(role: .assistant, content: "Previous answer"),
            ChatMessage(role: .user, content: "Fresh", modelPromptOverride: "Current full context"),
        ]
        let raw = try ChatGPTLiveClient.webSocketRequestBody(messages: messages, model: "catalog-model", effort: "none")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["type", "model", "instructions", "input", "reasoning", "store"])
        XCTAssertEqual(body["type"] as? String, "response.create")
        XCTAssertNil(body["stream_id"], "Named lanes are rejected by the current ChatGPT plan route")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(
            body["input"] as? [[String: String]],
            [
                ["role": "user", "content": "Previous question"],
                ["role": "assistant", "content": "Previous answer"],
                ["role": "user", "content": "Current full context"],
            ])
    }

    func testConcurrentTurnsSerializeAndReuseOneSocket() async throws {
        let socket = SocketFixture([nil, socketResponse("second", "Second answer.")])
        let connector = SocketConnectorFixture([socket])
        let transport = ChatGPTWebSocketTransport(connector: connector)
        let values = SocketTestValues()
        let first = Task {
            try await transport.run(
                accountID: "account", model: "model", payload: "first",
                authorization: {
                    values.authorized(); return "fixture-token"
                }, yield: { values.append($0) })
        }
        try await waitUntil { socket.sendCount == 1 }
        let second = Task {
            try await transport.run(
                accountID: "account", model: "model", payload: "second",
                authorization: {
                    values.authorized(); return "fixture-token"
                }, yield: { values.append($0) })
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(socket.sendCount, 1)
        XCTAssertEqual(socket.pingCount, 0, "A queued request cannot ping while the active response owns the socket")
        XCTAssertEqual(values.authorizationCount, 1, "Queued turns refresh credentials only after acquiring the lease")
        socket.push(socketResponse("first", "First answer."))
        try await first.value; try await second.value
        XCTAssertEqual(connector.count, 1)
        XCTAssertEqual(socket.payloads, ["first", "second"])
        XCTAssertEqual(socket.pingCount, 1, "The completed socket is checked before its next model request")
        XCTAssertEqual(values.output, ["First answer.", "Second answer."])
    }

    func testKnownIdleClosedSocketReconnectsBeforeSendingNextRequest() async throws {
        let closed = SocketFixture([socketResponse("first")])
        let fresh = SocketFixture([socketResponse("second", "Fresh answer.")])
        let connector = SocketConnectorFixture([closed, fresh])
        let transport = ChatGPTWebSocketTransport(connector: connector)
        let values = SocketTestValues()
        try await transport.run(
            accountID: "a", model: "m", payload: "first", authorization: { "fixture" }, yield: { _ in })
        closed.closeWhileIdle()
        try await transport.run(
            accountID: "a", model: "m", payload: "second", authorization: { "fixture" },
            yield: { values.append($0) })
        XCTAssertEqual(connector.count, 2)
        XCTAssertEqual(
            closed.payloads, ["first"], "A known closed idle socket must never receive the next model request")
        XCTAssertEqual(fresh.payloads, ["second"])
        XCTAssertEqual(values.output, ["Fresh answer."])
        XCTAssertGreaterThan(closed.cancelCount, 0)
    }

    func testHalfOpenWarmupSocketIsReplacedBeforeAnyModelSend() async throws {
        let stale = SocketFixture([])
        stale.simulateHalfOpen()
        let fresh = SocketFixture([socketResponse("fresh", "Fresh answer.")])
        let connector = SocketConnectorFixture([stale, fresh])
        let transport = ChatGPTWebSocketTransport(connector: connector)
        try await transport.warmUp(accountID: "a", model: "m", authorization: { "fixture" })
        XCTAssertTrue(stale.isReusable, "Foundation state alone can miss a half-open socket")
        XCTAssertEqual(stale.pingCount, 0, "warmUp opens an unused socket without model input")
        try await transport.run(
            accountID: "a", model: "m", payload: "only-model-request", authorization: { "fixture" }, yield: { _ in })
        XCTAssertEqual(stale.pingCount, 1)
        XCTAssertEqual(stale.sendCount, 0)
        XCTAssertEqual(fresh.payloads, ["only-model-request"])
        XCTAssertEqual(connector.count, 2)
    }

    func testPingTimeoutReplacesStaleSocketBeforeModelSend() async throws {
        let stale = SocketFixture([])
        stale.holdPongs()
        let fresh = SocketFixture([socketResponse("fresh")])
        let connector = SocketConnectorFixture([stale, fresh])
        let transport = ChatGPTWebSocketTransport(connector: connector, healthCheckTimeout: .milliseconds(30))
        try await transport.warmUp(accountID: "a", model: "m", authorization: { "fixture" })
        try await transport.run(
            accountID: "a", model: "m", payload: "only-model-request", authorization: { "fixture" }, yield: { _ in })
        XCTAssertEqual(stale.sendCount, 0)
        XCTAssertGreaterThan(stale.cancelCount, 0)
        XCTAssertEqual(fresh.sendCount, 1)
        XCTAssertEqual(connector.count, 2)
    }

    func testHealthyPongRetiresHealthDeadlineBeforeLongerModelResponse() async throws {
        let socket = SocketFixture([nil])
        let connector = SocketConnectorFixture([socket])
        let transport = ChatGPTWebSocketTransport(connector: connector, healthCheckTimeout: .milliseconds(20))
        try await transport.warmUp(accountID: "a", model: "m", authorization: { "fixture" })
        let task = Task {
            try await transport.run(
                accountID: "a", model: "m", payload: "only-model-request", authorization: { "fixture" }, yield: { _ in }
            )
        }
        try await waitUntil { socket.sendCount == 1 }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(socket.cancelCount, 0, "A losing health timer must not close a socket during inference")
        socket.push(socketResponse("completed"))
        try await task.value
        XCTAssertEqual(socket.pingCount, 1)
        XCTAssertEqual(connector.count, 1)
    }

    func testCancellationDuringPingCannotReconnectOrSendModelInput() async throws {
        let stale = SocketFixture([])
        stale.holdPongs()
        let connector = SocketConnectorFixture([stale, SocketFixture([socketResponse("unused")])])
        let transport = ChatGPTWebSocketTransport(connector: connector)
        try await transport.warmUp(accountID: "a", model: "m", authorization: { "fixture" })
        let task = Task {
            try await transport.run(
                accountID: "a", model: "m", payload: "never-send", authorization: { "fixture" }, yield: { _ in })
        }
        try await waitUntil { stale.pingCount == 1 }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled ping must not recover") } catch {}
        XCTAssertEqual(stale.sendCount, 0)
        XCTAssertEqual(connector.count, 1)
        XCTAssertGreaterThan(stale.cancelCount, 0)
    }

    func testAccountInvalidationDuringPingCannotReconnectOrSendModelInput() async throws {
        let stale = SocketFixture([])
        stale.holdPongs()
        let connector = SocketConnectorFixture([stale, SocketFixture([socketResponse("unused")])])
        let transport = ChatGPTWebSocketTransport(connector: connector)
        try await transport.warmUp(accountID: "a", model: "m", authorization: { "fixture" })
        let task = Task {
            try await transport.run(
                accountID: "a", model: "m", payload: "never-send", authorization: { "fixture" }, yield: { _ in })
        }
        try await waitUntil { stale.pingCount == 1 }
        transport.cancelAll()
        do { try await task.value; XCTFail("An invalidated epoch must not recover") } catch {}
        XCTAssertEqual(stale.sendCount, 0)
        XCTAssertEqual(connector.count, 1)
    }

    func testFailureAfterSuccessfulPingNeverReplaysModelRequest() async throws {
        let socket = SocketFixture([
            [
                socketEvent("response.created", ["response": ["id": "first"]]),
                socketEvent("response.output_text.delta", ["delta": "Partial"]),
                socketEvent("response.incomplete"),
            ]
        ])
        let connector = SocketConnectorFixture([socket, SocketFixture([socketResponse("must-not-run")])])
        let transport = ChatGPTWebSocketTransport(connector: connector)
        try await transport.warmUp(accountID: "a", model: "m", authorization: { "fixture" })
        do {
            try await transport.run(
                accountID: "a", model: "m", payload: "only-model-request", authorization: { "fixture" }, yield: { _ in }
            )
            XCTFail("An incomplete inference must fail")
        } catch { XCTAssertEqual(error as? ChatGPTLiveError, .incomplete) }
        XCTAssertEqual(socket.pingCount, 1)
        XCTAssertEqual(socket.sendCount, 1)
        XCTAssertEqual(connector.count, 1, "Only pre-send control failures may replace a socket")
    }

    func testCancellingQueuedTurnDoesNotCloseActiveTurn() async throws {
        let socket = SocketFixture([nil, socketResponse("third")])
        let connector = SocketConnectorFixture([socket])
        let transport = ChatGPTWebSocketTransport(connector: connector)
        let first = Task {
            try await transport.run(
                accountID: "a", model: "m", payload: "first", authorization: { "fixture" }, yield: { _ in })
        }
        try await waitUntil { socket.sendCount == 1 }
        let queued = Task {
            try await transport.run(
                accountID: "a", model: "m", payload: "queued", authorization: { "fixture" }, yield: { _ in })
        }
        try await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        do { try await queued.value; XCTFail("Queued cancellation should throw") } catch {}
        XCTAssertEqual(socket.cancelCount, 0)
        socket.push(socketResponse("first"))
        try await first.value
        try await transport.run(
            accountID: "a", model: "m", payload: "third", authorization: { "fixture" }, yield: { _ in })
        XCTAssertEqual(socket.payloads, ["first", "third"])
        XCTAssertEqual(connector.count, 1)
    }

    func testCancellationClosesOwnedSocketAndOldDeltasCannotReachNextTurn() async throws {
        let firstSocket = SocketFixture([
            [
                socketEvent("response.created", ["response": ["id": "first"]]),
                socketEvent("response.output_text.delta", ["delta": "Partial "]),
            ]
        ])
        let secondSocket = SocketFixture([socketResponse("second", "New answer.")])
        let connector = SocketConnectorFixture([firstSocket, secondSocket])
        let transport = ChatGPTWebSocketTransport(connector: connector)
        let values = SocketTestValues()
        let task = Task {
            try await transport.run(
                accountID: "a", model: "m", payload: "first", authorization: { "fixture" }, yield: { values.append($0) }
            )
        }
        try await waitUntil { values.output == ["Partial "] }
        task.cancel()
        do { try await task.value; XCTFail("Partial cancellation must not complete") } catch {}
        XCTAssertGreaterThan(firstSocket.cancelCount, 0)
        firstSocket.push(socketResponse("stale", "STALE"))
        try await transport.run(
            accountID: "a", model: "m", payload: "second", authorization: { "fixture" }, yield: { values.append($0) })
        XCTAssertEqual(values.output, ["Partial ", "New answer."])
        XCTAssertEqual(connector.count, 2)
    }

    func testLateUsageFailureIsNotReplayedAndNextTurnReconnects() async throws {
        let failed = SocketFixture([
            [
                socketEvent("response.created", ["response": ["id": "first"]]),
                socketEvent("response.output_text.delta", ["delta": "Partial"]),
                socketEvent(
                    "response.failed", ["response": ["error": ["code": "subscription_sharing_usage_limit_exceeded"]]]),
            ]
        ])
        let next = SocketFixture([socketResponse("next")])
        let connector = SocketConnectorFixture([failed, next])
        let transport = ChatGPTWebSocketTransport(connector: connector)
        do {
            try await transport.run(
                accountID: "a", model: "m", payload: "first", authorization: { "fixture" }, yield: { _ in })
            XCTFail("A partial usage failure cannot complete")
        } catch { XCTAssertEqual(error as? ChatGPTLiveError, .failed("subscription_sharing_usage_limit_exceeded")) }
        XCTAssertEqual(connector.count, 1)
        XCTAssertEqual(failed.sendCount, 1, "No automatic duplicate request")
        XCTAssertGreaterThan(failed.cancelCount, 0)
        try await transport.run(
            accountID: "a", model: "m", payload: "next", authorization: { "fixture" }, yield: { _ in })
        XCTAssertEqual(connector.count, 2)
    }

    func testIncompleteAndCompletedWithoutMeaningfulTextCloseConnection() async throws {
        for batch in [
            [socketEvent("response.created", ["response": ["id": "one"]]), socketEvent("response.incomplete")],
            socketResponse("one", " ... "),
        ] {
            let socket = SocketFixture([batch])
            let connector = SocketConnectorFixture([socket])
            let transport = ChatGPTWebSocketTransport(connector: connector)
            do {
                try await transport.run(
                    accountID: "a", model: "m", payload: "one", authorization: { "fixture" }, yield: { _ in })
                XCTFail("Incomplete/empty responses must fail")
            } catch { XCTAssertEqual(error as? ChatGPTLiveError, .incomplete) }
            XCTAssertEqual(connector.count, 1)
            XCTAssertGreaterThan(socket.cancelCount, 0)
        }
    }

    func testAccountModelAndRotatedTokenEachRequireNewSocket() async throws {
        let sockets = (0..<4).map { SocketFixture([socketResponse("response-\($0)")]) }
        let connector = SocketConnectorFixture(sockets)
        let transport = ChatGPTWebSocketTransport(connector: connector)
        let contexts = [
            ("a", "m", "token1"), ("b", "m", "token1"), ("b", "new-model", "token1"), ("b", "new-model", "token2"),
        ]
        for (account, model, token) in contexts {
            try await transport.run(
                accountID: account, model: model, payload: "fixture", authorization: { token }, yield: { _ in })
        }
        XCTAssertEqual(connector.count, 4)
        XCTAssertTrue(sockets.prefix(3).allSatisfy { $0.cancelCount > 0 })
    }

    func testExpiryAndConnectionAgePreventSocketReuse() async throws {
        for useTokenExpiry in [false, true] {
            let values = SocketTestValues()
            let first = SocketFixture([socketResponse("first")])
            let second = SocketFixture([socketResponse("second")])
            let connector = SocketConnectorFixture([first, second])
            let transport = ChatGPTWebSocketTransport(connector: connector, now: { values.now() })
            let token = fixtureToken(expiry: values.now().addingTimeInterval(useTokenExpiry ? 120 : 7_200))
            try await transport.run(
                accountID: "a", model: "m", payload: "first", authorization: { token }, yield: { _ in })
            values.advance(useTokenExpiry ? 31 : 55 * 60 + 1)
            try await transport.run(
                accountID: "a", model: "m", payload: "second", authorization: { token }, yield: { _ in })
            XCTAssertEqual(connector.count, 2)
            XCTAssertGreaterThan(first.cancelCount, 0)
        }
    }

    func testCancelAllDuringAuthorizationPreventsLateSocketPublication() async throws {
        let socket = SocketFixture([socketResponse("unused")])
        let connector = SocketConnectorFixture([socket])
        let transport = ChatGPTWebSocketTransport(connector: connector)
        let gate = SocketAuthorizationGate()
        let task = Task {
            try await transport.run(
                accountID: "a", model: "m", payload: "unused",
                authorization: {
                    await gate.wait(); return "fixture"
                }, yield: { _ in XCTFail("No text may be sent after account invalidation") })
        }
        try await waitUntil { await gate.entered }
        transport.cancelAll()
        await gate.open()
        do { try await task.value; XCTFail("Late authorization must be invalidated") } catch {}
        XCTAssertEqual(connector.count, 0)
    }

    func testWarmUpOpensOnlyHandshakeAndCancelAllClosesIdleSocket() async throws {
        let socket = SocketFixture([socketResponse("first")])
        let connector = SocketConnectorFixture([socket])
        let transport = ChatGPTWebSocketTransport(connector: connector)
        try await transport.warmUp(accountID: "a", model: "m", authorization: { "fixture" })
        XCTAssertEqual(connector.count, 1)
        XCTAssertEqual(socket.sendCount, 0, "Prewarming must not transmit meeting text or generate a response")
        try await transport.run(
            accountID: "a", model: "m", payload: "first", authorization: { "fixture" }, yield: { _ in })
        XCTAssertEqual(connector.count, 1)
        transport.cancelAll()
        XCTAssertGreaterThan(socket.cancelCount, 0)
    }

    func testDeadlineClosesSocketWithoutReplaying() async throws {
        let socket = SocketFixture([nil])
        let connector = SocketConnectorFixture([socket])
        let transport = ChatGPTWebSocketTransport(connector: connector, deadline: .milliseconds(30))
        do {
            try await transport.run(
                accountID: "a", model: "m", payload: "fixture", authorization: { "fixture" }, yield: { _ in })
            XCTFail("Deadline must throw")
        } catch {}
        XCTAssertEqual(socket.sendCount, 1)
        XCTAssertEqual(connector.count, 1)
        XCTAssertGreaterThan(socket.cancelCount, 0)
    }

    func testLeaseInvalidatedBeforeInstallCannotPublishSocket() throws {
        let control = ChatGPTWebSocketControl()
        let oldGeneration = control.generation
        control.cancel()
        let socket = SocketFixture([])
        XCTAssertThrowsError(try control.install(socket, connectionID: UUID(), generation: oldGeneration))
        XCTAssertEqual(socket.cancelCount, 1)
    }

    func testDecoderRejectsMissingCreationAndMismatchedResponseIDs() throws {
        var decoder = ChatGPTWebSocketDecoder()
        XCTAssertThrowsError(try decoder.decode(socketEvent("response.output_text.delta", ["delta": "orphan"])))
        _ = try decoder.decode(socketEvent("response.created", ["response": ["id": "right"]]))
        XCTAssertThrowsError(
            try decoder.decode(socketEvent("response.completed", ["response": ["id": "wrong", "status": "completed"]])))
        XCTAssertThrowsError(
            try decoder.decode(
                socketEvent("response.output_text.delta", ["delta": "Stale.", "response_id": "old-response"])))
        XCTAssertEqual(
            try decoder.decode(
                socketEvent("response.output_text.delta", ["delta": "Current.", "response_id": "right"])),
            .text("Current."))
        XCTAssertEqual(
            try decoder.decode(socketEvent("response.output_text.delta", ["delta": "No optional response ID."])),
            .text("No optional response ID."))
        XCTAssertEqual(
            try decoder.decode(
                socketEvent("response.completed", ["response": ["id": "right", "status": "completed"]])), .completed)
    }
    func testHandshakeStatusMappingPreservesClearErrorsAndGenericNetworkFailures() throws {
        let failure = URLError(.badServerResponse)
        let url = URL(string: "https://api.openai.com/v1/responses")!
        for status in [401, 429, 503] {
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            XCTAssertEqual(
                ChatGPTWebSocketFailure.map(failure, response: response) as? ChatGPTLiveError,
                .http(status, "websocket_handshake_rejected"))
        }
        let upgraded = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 101, httpVersion: nil, headerFields: nil))
        let lost = URLError(.networkConnectionLost)
        XCTAssertEqual(
            (ChatGPTWebSocketFailure.map(lost, response: upgraded) as? URLError)?.code, .networkConnectionLost)
        XCTAssertEqual((ChatGPTWebSocketFailure.map(failure, response: nil) as? URLError)?.code, .badServerResponse)
    }

}
