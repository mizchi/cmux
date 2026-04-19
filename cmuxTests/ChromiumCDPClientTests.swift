import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ChromiumCDPClientTests: XCTestCase {

    private final class FakeTransport: CDPTransport {
        var sent: [Data] = []
        private var continuation: AsyncStream<Data>.Continuation?

        func start() async throws {}
        func stop() { continuation?.finish() }
        func send(_ data: Data) async throws { sent.append(data) }
        func makeIncoming() -> AsyncStream<Data> {
            AsyncStream { self.continuation = $0 }
        }

        func deliver(_ json: String) {
            continuation?.yield(Data(json.utf8))
        }
    }

    func test_sendReturnsMatchingResponse() async throws {
        let transport = FakeTransport()
        let client = ChromiumCDPClient(transport: transport)
        try await client.connect()

        let resultTask = Task<[String: Any], Error> {
            try await client.send(method: "Target.getTargets", params: [:])
        }

        // Wait for the client to flush its send.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.sent.count, 1)
        let sentJSON = try JSONSerialization.jsonObject(with: transport.sent[0]) as! [String: Any]
        let id = sentJSON["id"] as! Int
        XCTAssertEqual(sentJSON["method"] as? String, "Target.getTargets")

        transport.deliver("""
        {"id":\(id),"result":{"targetInfos":[{"targetId":"t-1","type":"page"}]}}
        """)

        let result = try await resultTask.value
        let infos = result["targetInfos"] as? [[String: Any]]
        XCTAssertEqual(infos?.first?["targetId"] as? String, "t-1")
    }

    func test_remoteErrorPropagates() async throws {
        let transport = FakeTransport()
        let client = ChromiumCDPClient(transport: transport)
        try await client.connect()

        let resultTask = Task<[String: Any], Error> {
            try await client.send(method: "Browser.setWindowBounds", params: [:])
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let sentJSON = try JSONSerialization.jsonObject(with: transport.sent[0]) as! [String: Any]
        let id = sentJSON["id"] as! Int

        transport.deliver("""
        {"id":\(id),"error":{"code":-32602,"message":"invalid params"}}
        """)

        do {
            _ = try await resultTask.value
            XCTFail("expected error")
        } catch CDPError.remote(let code, let message) {
            XCTAssertEqual(code, -32602)
            XCTAssertEqual(message, "invalid params")
        }
    }

    func test_multipleInflightRequestsMatchByID() async throws {
        let transport = FakeTransport()
        let client = ChromiumCDPClient(transport: transport)
        try await client.connect()

        async let a = client.send(method: "Target.getTargets", params: [:])
        async let b = client.send(method: "Browser.getVersion", params: [:])

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.sent.count, 2)
        let ids = try transport.sent.map { data -> Int in
            let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return obj["id"] as! Int
        }
        // Deliver responses out of order.
        transport.deliver("""
        {"id":\(ids[1]),"result":{"product":"HeadlessChrome"}}
        """)
        transport.deliver("""
        {"id":\(ids[0]),"result":{"targetInfos":[]}}
        """)

        let (resA, resB) = try await (a, b)
        XCTAssertNotNil(resA["targetInfos"])
        XCTAssertEqual(resB["product"] as? String, "HeadlessChrome")
    }

    func test_emulationSetDeviceMetricsOverrideHelperShape() async throws {
        let transport = FakeTransport()
        let client = ChromiumCDPClient(transport: transport)
        try await client.connect()

        let task = Task {
            try await client.emulationSetDeviceMetricsOverride(
                sessionId: "sess-1",
                width: 1024,
                height: 768,
                deviceScaleFactor: 2.0
            )
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let sentJSON = try JSONSerialization.jsonObject(with: transport.sent[0]) as! [String: Any]
        XCTAssertEqual(sentJSON["method"] as? String, "Emulation.setDeviceMetricsOverride")
        XCTAssertEqual(sentJSON["sessionId"] as? String, "sess-1")
        let params = sentJSON["params"] as! [String: Any]
        XCTAssertEqual(params["width"] as? Int, 1024)
        XCTAssertEqual(params["height"] as? Int, 768)
        XCTAssertEqual(params["deviceScaleFactor"] as? Double, 2.0)
        XCTAssertEqual(params["mobile"] as? Bool, false)

        let id = sentJSON["id"] as! Int
        transport.deliver("{\"id\":\(id),\"result\":{}}")
        try await task.value
    }

    func test_closeCancelsInflightRequestWithNotConnected() async throws {
        let transport = FakeTransport()
        let client = ChromiumCDPClient(transport: transport)
        try await client.connect()

        let resultTask = Task<[String: Any], Error> {
            try await client.send(method: "Target.getTargets", params: [:])
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.sent.count, 1)

        await client.close()

        do {
            _ = try await resultTask.value
            XCTFail("expected notConnected after close()")
        } catch CDPError.notConnected {
            // expected
        }
    }

    func test_connectIsIdempotent() async throws {
        let transport = FakeTransport()
        let client = ChromiumCDPClient(transport: transport)
        try await client.connect()
        // Second connect should be a no-op; subsequent send should still work.
        try await client.connect()

        let task = Task<[String: Any], Error> {
            try await client.send(method: "Browser.getVersion", params: [:])
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.sent.count, 1)
        let sentJSON = try JSONSerialization.jsonObject(with: transport.sent[0]) as! [String: Any]
        let id = sentJSON["id"] as! Int
        transport.deliver("{\"id\":\(id),\"result\":{\"product\":\"X\"}}")
        let result = try await task.value
        XCTAssertEqual(result["product"] as? String, "X")
    }

    func test_sendWithoutConnectThrowsNotConnected() async throws {
        let transport = FakeTransport()
        let client = ChromiumCDPClient(transport: transport)
        do {
            _ = try await client.send(method: "Browser.getVersion", params: [:])
            XCTFail("expected notConnected before connect()")
        } catch CDPError.notConnected {
            // expected
        }
    }
}
