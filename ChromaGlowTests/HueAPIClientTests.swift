// HueAPIClientTests.swift
// ChromaGlow — Unit Tests
//
// Tests for HueAPIClient using URLProtocol stub injection.
// All tests run fully offline — no real Bridge or Keychain required.

import XCTest
@testable import ChromaGlow

// MARK: - URLProtocol Stub

/// Intercepts all URLSession requests and returns pre-configured stub responses.
final class StubURLProtocol: URLProtocol {

    // Keyed on URL path for precise matching
    static var stubs: [String: (data: Data, statusCode: Int)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if let stub = StubURLProtocol.stubs[path] {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
        } else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() { stubs = [:] }
}

// MARK: - TestableAPIClient

/// HueAPIClient subclass that uses the stub URLSession and bypasses Keychain.
final class TestableAPIClient: HueAPIClient {

    let stubIP:    String
    let stubToken: String

    override init(ip: String = "192.168.1.1", token: String = "test-token") {
        self.stubIP    = ip
        self.stubToken = token
        super.init()
    }

    override func credentials() throws -> (ip: String, token: String) {
        (stubIP, stubToken)
    }

    // Override the internal session to use the stub protocol
    private lazy var testSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }()

    override func get(path: String, ip: String, token: String) async throws -> Data {
        let urlStr = "https://\(ip)\(path)"
        guard let url = URL(string: urlStr) else { throw HueAPIError.badURL(urlStr) }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "hue-application-key")
        let (data, response) = try await testSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw HueAPIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    override func put(path: String, body: [String: Any], ip: String, token: String) async throws -> Data {
        let urlStr = "https://\(ip)\(path)"
        guard let url = URL(string: urlStr) else { throw HueAPIError.badURL(urlStr) }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(token, forHTTPHeaderField: "hue-application-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await testSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw HueAPIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}

// MARK: - HueAPIClientTests

final class HueAPIClientTests: XCTestCase {

    var client: TestableAPIClient!

    override func setUp() {
        super.setUp()
        client = TestableAPIClient()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Rooms

    func testFetchRoomsDecodesCorrectly() async throws {
        StubURLProtocol.stubs["/clip/v2/resource/room"] = (
            data: roomsJSON,
            statusCode: 200
        )

        let rooms = try await client.fetchRooms()

        XCTAssertEqual(rooms.count, 2)
        XCTAssertEqual(rooms[0].metadata.name, "Living Room")
        XCTAssertEqual(rooms[1].metadata.name, "Bedroom")
        XCTAssertEqual(rooms[0].groupedLightID, "gl-001")
    }

    func testFetchRoomsHTTPErrorThrows() async {
        StubURLProtocol.stubs["/clip/v2/resource/room"] = (data: Data(), statusCode: 500)

        do {
            _ = try await client.fetchRooms()
            XCTFail("Expected HueAPIError.httpError")
        } catch HueAPIError.httpError(let code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Lights

    func testFetchLightsDecodesCorrectly() async throws {
        StubURLProtocol.stubs["/clip/v2/resource/light"] = (
            data: lightsJSON,
            statusCode: 200
        )

        let lights = try await client.fetchLights()

        XCTAssertEqual(lights.count, 1)
        XCTAssertEqual(lights[0].metadata.name, "Floor Lamp")
        XCTAssertTrue(lights[0].on.on)
        XCTAssertEqual(lights[0].dimming?.brightness, 80.0)
    }

    // MARK: - Grouped Light

    func testFetchGroupedLightDecodesCorrectly() async throws {
        StubURLProtocol.stubs["/clip/v2/resource/grouped_light/gl-001"] = (
            data: groupedLightJSON,
            statusCode: 200
        )

        let gl = try await client.fetchGroupedLight(id: "gl-001")

        XCTAssertEqual(gl.id, "gl-001")
        XCTAssertTrue(gl.on.on)
        XCTAssertEqual(gl.dimming?.brightness, 75.0)
    }

    // MARK: - Toggle

    func testSetGroupedLightDoesNotThrowOn200() async throws {
        StubURLProtocol.stubs["/clip/v2/resource/grouped_light/gl-001"] = (
            data: "{}".data(using: .utf8)!,
            statusCode: 200
        )

        await XCTAssertNoThrowAsync(try await client.setGroupedLight(id: "gl-001", on: true))
    }

    // MARK: - Decoding Helper

    func testDecodeThrowsOnMalformedJSON() {
        let badData = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try client.decode(HueV2Response<HueRoom>.self, from: badData))
    }

    // MARK: - Credentials

    func testMissingCredentialsThrowsCorrectError() async {
        let noCredClient = TestableAPIClient(ip: "", token: "")
        do {
            _ = try await noCredClient.fetchRooms()
            XCTFail("Expected missingCredentials")
        } catch HueAPIError.missingCredentials {
            // ✅
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - XCTest Async Helper

func XCTAssertNoThrowAsync(
    _ expression: @autoclosure () async throws -> Void,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line
) async {
    do {
        try await expression()
    } catch {
        XCTFail("Expected no error but got: \(error). \(message)", file: file, line: line)
    }
}

// MARK: - JSON Fixtures

private let roomsJSON = """
{
  "errors": [],
  "data": [
    {
      "id": "room-001",
      "metadata": {"name": "Living Room", "archetype": "living_room"},
      "children": [{"rid": "light-001", "rtype": "light"}],
      "services": [{"rid": "gl-001", "rtype": "grouped_light"}]
    },
    {
      "id": "room-002",
      "metadata": {"name": "Bedroom", "archetype": "bedroom"},
      "children": [],
      "services": [{"rid": "gl-002", "rtype": "grouped_light"}]
    }
  ]
}
""".data(using: .utf8)!

private let lightsJSON = """
{
  "errors": [],
  "data": [
    {
      "id": "light-001",
      "metadata": {"name": "Floor Lamp", "archetype": "floor_shade"},
      "on": {"on": true},
      "dimming": {"brightness": 80.0},
      "owner": {"rid": "device-001", "rtype": "device"}
    }
  ]
}
""".data(using: .utf8)!

private let groupedLightJSON = """
{
  "errors": [],
  "data": [
    {
      "id": "gl-001",
      "on": {"on": true},
      "dimming": {"brightness": 75.0},
      "type": "grouped_light"
    }
  ]
}
""".data(using: .utf8)!
