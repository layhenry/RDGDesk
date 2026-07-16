import XCTest
@testable import RdcCore

final class RdpSessionEngineTests: XCTestCase {
    func testMockEngineConnectsWithExplicitRequestAndStateContract() async throws {
        let engine = MockRdpSessionEngine()
        let request = RdpConnectionRequest(
            serverID: "rdp.example.test:6166",
            host: "rdp.example.test",
            port: 6166,
            username: "administrator",
            domain: "DZ-8-3-21-57"
        )

        let viewport = RdpViewport(width: 1_024, height: 768)
        let session = try await engine.connect(request, credential: nil, viewport: viewport)

        XCTAssertEqual(session.request, request)
        XCTAssertEqual(session.transport, .mock)
        let state = await engine.currentState()
        XCTAssertEqual(state, .connected(session))
        XCTAssertEqual(engine.stateHistory, [.idle, .connecting(request), .connected(session)])
    }

    func testMockEngineDisconnectsAndReconnectsFromLastRequest() async throws {
        let engine = MockRdpSessionEngine()
        let request = RdpConnectionRequest(
            serverID: "198.51.100.57",
            host: "198.51.100.57",
            port: nil,
            username: nil,
            domain: nil
        )

        let viewport = RdpViewport(width: 1_024, height: 768)
        let firstSession = try await engine.connect(request, credential: nil, viewport: viewport)
        await engine.disconnect()
        let secondSession = try await engine.reconnect()

        XCTAssertNotEqual(firstSession.id, secondSession.id)
        XCTAssertEqual(secondSession.request, request)
        let state = await engine.currentState()
        XCTAssertEqual(state, .connected(secondSession))
        XCTAssertTrue(engine.stateHistory.contains(.disconnecting(firstSession)))
        XCTAssertTrue(engine.stateHistory.contains(.disconnected))
    }

    func testMockEngineSurfacesContractErrorsWithoutServerValidation() async {
        let engine = MockRdpSessionEngine()
        let request = RdpConnectionRequest(
            serverID: "missing-host",
            host: "",
            port: 3389,
            username: nil,
            domain: nil
        )

        do {
            _ = try await engine.connect(
                request, credential: nil, viewport: RdpViewport(width: 1_024, height: 768)
            )
            XCTFail("Expected missing endpoint to fail")
        } catch let error as RdpSessionError {
            XCTAssertEqual(error, .missingEndpoint)
            let state = await engine.currentState()
            XCTAssertEqual(state, .failed(.missingEndpoint))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
