import XCTest
@testable import RoadsAndRunesCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Exports are downloaded with the rider's token and shared as files (docs/GARMIN.md, step 2).
final class ExportFileTests: XCTestCase {
    // MARK: The server's filename

    func testAQuotedFilenameIsTakenAsItIs() {
        XCTAssertEqual(ExportFile.filename(contentDisposition: #"attachment; filename="Scenic ride.fit""#, fallback: "route.fit"), "Scenic ride.fit")
    }

    func testAnUnquotedFilenameRunsToTheNextParameter() {
        XCTAssertEqual(ExportFile.filename(contentDisposition: "attachment; filename=Ride 8 Oct 2026.fit", fallback: "journey.fit"), "Ride 8 Oct 2026.fit")
        XCTAssertEqual(ExportFile.filename(contentDisposition: "attachment;FILENAME=route.gpx; size=12", fallback: "route.fit"), "route.gpx")
    }

    func testQuotesMayHoldSemicolonsAndEscapedQuotes() {
        let header = #"attachment; filename="The \"Old\" Mill; loop.fit"; creation-date="x""#
        XCTAssertEqual(ExportFile.filename(contentDisposition: header, fallback: "route.fit"), #"The "Old" Mill; loop.fit"#)
    }

    func testTheExtendedFilenameWinsWhenBothAreSent() {
        let header = #"attachment; filename="Cafe ride.fit"; filename*=UTF-8''Caf%C3%A9%20ride.fit"#
        XCTAssertEqual(ExportFile.filename(contentDisposition: header, fallback: "route.fit"), "Café ride.fit")
    }

    func testNoHeaderOrNoFilenameFallsBack() {
        XCTAssertEqual(ExportFile.filename(contentDisposition: nil, fallback: "route.fit"), "route.fit")
        XCTAssertEqual(ExportFile.filename(contentDisposition: "attachment", fallback: "journey.gpx"), "journey.gpx")
        XCTAssertEqual(ExportFile.filename(contentDisposition: #"attachment; filename="""#, fallback: "journey.fit"), "journey.fit")
        XCTAssertEqual(ExportFile.filename(contentDisposition: #"attachment; filename="..""#, fallback: "journey.fit"), "journey.fit")
    }

    func testPathSeparatorsAreStrippedAndNothingIsHidden() {
        XCTAssertEqual(ExportFile.filename(contentDisposition: #"attachment; filename="../../etc/passwd.fit""#, fallback: "route.fit"), "etcpasswd.fit")
        XCTAssertEqual(ExportFile.filename(contentDisposition: #"attachment; filename="C:\rides\loop.gpx""#, fallback: "route.gpx"), "Cridesloop.gpx")
        XCTAssertEqual(ExportFile.filename(contentDisposition: #"attachment; filename=".hidden.fit""#, fallback: "route.fit"), "hidden.fit")
    }

    func testANameWithoutAnExtensionKeepsTheFormats() {
        XCTAssertEqual(ExportFile.filename(contentDisposition: #"attachment; filename="Scenic ride""#, fallback: "route.fit"), "Scenic ride.fit")
    }

    func testAnUnclosedQuoteRunsToTheEnd() {
        XCTAssertEqual(ExportFile.filename(contentDisposition: #"attachment; filename="Old Mill loop.fit"#, fallback: "route.fit"), "Old Mill loop.fit")
    }

    // MARK: The file

    func testWriteKeepsTheNameAndDiscardTakesItsFolder() throws {
        let body = Data([0x0E, 0x10, 0x2E, 0x46, 0x49, 0x54])
        let url = try ExportFile.write(body, named: "Scenic ride.fit")
        XCTAssertEqual(url.lastPathComponent, "Scenic ride.fit")
        XCTAssertEqual(try Data(contentsOf: url), body)
        let folder = url.deletingLastPathComponent()
        XCTAssertEqual(folder.deletingLastPathComponent().resolvingSymlinksInPath(), ExportFile.directory.resolvingSymlinksInPath())

        let second = try ExportFile.write(body, named: "Scenic ride.fit")
        XCTAssertNotEqual(second, url, "two downloads of one route never overwrite each other")

        ExportFile.discard(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        ExportFile.discard(second)
    }

    func testDiscardLeavesFilesThatAreNotExports() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("not-an-export-\(UUID().uuidString).txt")
        try Data("keep".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        ExportFile.discard(outside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    // MARK: Downloading with the rider's token

    private func client(tokens: AuthTokens? = AuthTokens(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: .distantFuture)) -> (APIClient, InMemoryTokenStore) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let store = InMemoryTokenStore(tokens: tokens)
        let api = APIClient(baseURL: URL(string: "https://api.example.test")!, tokenStore: store, session: URLSession(configuration: configuration))
        return (api, store)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testARouteDownloadsToAFileNamedByTheServer() async throws {
        let body = Data([0x0E, 0x20, 0x2E, 0x46, 0x49, 0x54, 0x00, 0x01])
        StubURLProtocol.reply { _ in
            StubURLProtocol.Reply(status: 200, headers: [
                "Content-Type": "application/vnd.ant.fit",
                "Content-Disposition": #"attachment; filename="Scenic ride.fit""#,
            ], body: body)
        }
        let (api, _) = client()
        let url = try await api.downloadRouteExport(id: SampleData.routeId, format: .fit)
        defer { ExportFile.discard(url) }

        XCTAssertEqual(url.lastPathComponent, "Scenic ride.fit")
        XCTAssertEqual(try Data(contentsOf: url), body)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
        XCTAssertEqual(request.url?.path, "/api/v1/routes/\(SampleData.routeId.uuidString)/export")
        XCTAssertEqual(request.url?.query, "format=fit")
    }

    func testAJourneyWithNoFilenameIsCalledJourney() async throws {
        StubURLProtocol.reply { _ in StubURLProtocol.Reply(status: 200, headers: [:], body: Data("<gpx/>".utf8)) }
        let (api, _) = client()
        let url = try await api.downloadRideExport(id: SampleData.rideId, format: .gpx)
        defer { ExportFile.discard(url) }
        XCTAssertEqual(url.lastPathComponent, "journey.gpx")
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.path, "/api/v1/rides/\(SampleData.rideId.uuidString)/export")
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.query, "format=gpx")
    }

    func testASealedRouteSaysWhyInTheServersWords() async throws {
        let message = "This quest's goal is still sealed. Its route opens when the quest is done."
        StubURLProtocol.reply { _ in
            StubURLProtocol.Reply(status: 409, headers: ["Content-Type": "application/json"], body: Data(
                #"{"error":{"code":"ROUTE_SEALED","message":"\#(message)","details":{}}}"#.utf8
            ))
        }
        let (api, _) = client()
        do {
            _ = try await api.downloadRouteExport(id: SampleData.routeId, format: .fit)
            XCTFail("a sealed route is refused")
        } catch let error as APIError {
            XCTAssertEqual(error.errorCode, APIErrorCode.routeSealed)
            XCTAssertEqual(error.localizedDescription, message)
        }
    }

    func testAnExpiredTokenIsRefreshedAndTheDownloadTriedAgain() async throws {
        let refreshed = try JSONCoding.encode(TokenResponse(accessToken: "access-2", refreshToken: "refresh-2", expiresIn: 3600, isNewUser: false, user: SampleData.sampleUser))
        StubURLProtocol.reply { request in
            if request.url?.path.hasSuffix("/auth/refresh") == true {
                return StubURLProtocol.Reply(status: 200, headers: ["Content-Type": "application/json"], body: refreshed)
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer access-2" {
                return StubURLProtocol.Reply(status: 200, headers: ["Content-Disposition": #"attachment; filename="Ride 8 Oct 2026.fit""#], body: Data([1, 2, 3]))
            }
            return StubURLProtocol.Reply(status: 401, headers: [:], body: Data(#"{"error":{"code":"UNAUTHENTICATED","message":"Expired"}}"#.utf8))
        }
        let (api, store) = client()
        let url = try await api.downloadRideExport(id: SampleData.rideId, format: .fit)
        defer { ExportFile.discard(url) }
        XCTAssertEqual(url.lastPathComponent, "Ride 8 Oct 2026.fit")
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        XCTAssertEqual(store.load()?.accessToken, "access-2")
        XCTAssertEqual(StubURLProtocol.requests.count, 3, "export, refresh, export again")
    }

    func testWithoutASessionNothingIsAsked() async throws {
        let (api, _) = client(tokens: nil)
        do {
            _ = try await api.downloadRouteExport(id: SampleData.routeId, format: .gpx)
            XCTFail("no token, no download")
        } catch let error as APIError {
            guard case .unauthenticated = error else { return XCTFail("expected unauthenticated, got \(error)") }
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: The mock

    func testTheMockHandsOverAFileAndRefusesAnOpenSealedRoute() async throws {
        let api = MockAPI()
        let route = try await api.downloadRouteExport(id: SampleData.routeId, format: .fit)
        XCTAssertEqual(route.pathExtension, "fit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: route.path))
        ExportFile.discard(route)

        let gpx = try await api.downloadRideExport(id: SampleData.rideId, format: .gpx)
        XCTAssertEqual(gpx.pathExtension, "gpx")
        XCTAssertTrue(try String(contentsOf: gpx, encoding: .utf8).contains("<trkpt"))
        ExportFile.discard(gpx)

        let sealed = try await api.sealedQuest(SealedQuestRequest(minutes: 40, at: SampleData.origin))
        let sealedRoute = try XCTUnwrap(sealed.suggestedRouteId)
        do {
            _ = try await api.downloadRouteExport(id: sealedRoute, format: .fit)
            XCTFail("an open sealed quest's route is never sent")
        } catch let error as APIError {
            XCTAssertEqual(error.errorCode, APIErrorCode.routeSealed)
        }
    }
}

/// Answers every request of a session with what the test says, and keeps them.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply)?
    private static var seen: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    static func reply(_ handler: @escaping (URLRequest) -> Reply) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        seen = []
        lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let url = request.url, let reply = handler?(request),
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
