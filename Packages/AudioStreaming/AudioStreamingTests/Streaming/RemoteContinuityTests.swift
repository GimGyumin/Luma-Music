import XCTest
@testable import AudioStreaming

/// Exercises the real remote source with deterministic HTTP responses, without audio hardware.
final class RemoteContinuityTests: XCTestCase {
    final class HTTP: URLProtocol {
        static var handler: ((HTTP) -> Void)?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { Self.handler?(self) }
        override func stopLoading() {}
        func respond(_ status: Int, range: String? = nil, acceptsRanges: Bool = false) {
            var headers = ["Content-Type": "audio/mpeg", "Content-Length": "1000", "Server": "Fixture"]
            if let range { headers["Content-Range"] = range }
            headers["Accept-Ranges"] = acceptsRanges ? "bytes" : "none"
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        }
    }
    final class Sink: AudioStreamSourceDelegate {
        var data = Data()
        var errors = 0
        var received: (() -> Void)?
        func dataAvailable(source: CoreAudioStreamSource, data: Data) { self.data += data; received?() }
        func errorOccurred(source: CoreAudioStreamSource, error: Error) { errors += 1 }
        func endOfFileOccurred(source: CoreAudioStreamSource) {}
        func metadataReceived(data: [String: String]) {}
    }
    private func source() -> (RemoteAudioSource, Sink) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTP.self]
        let queue = DispatchQueue(label: "continuity-test")
        let source = RemoteAudioSource(networking: NetworkingClient(configuration: config, networkQueue: queue),
            url: URL(string: "https://fixture.invalid/song.mp3")!, underlyingQueue: queue)
        let sink = Sink()
        source.delegate = sink
        return (source, sink)
    }
    override func tearDown() { HTTP.handler = nil }

    func testDisconnectWithoutRangesNeverReplaysThePrefix() {
        let (source, sink) = source()
        let received = expectation(description: "prefix delivered")
        sink.received = { received.fulfill() }
        var bodies = 0
        HTTP.handler = { request in
            request.respond(200)
            if request.request.value(forHTTPHeaderField: "Range") == "bytes=0-1" { return }
            bodies += 1
            request.client?.urlProtocol(request, didLoad: Data(repeating: 7, count: 32))
            // Failure after a committed prefix must not reopen byte zero.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                request.client?.urlProtocol(request, didFailWithError: URLError(.networkConnectionLost))
            }
        }
        source.seek(at: 0)
        wait(for: [received], timeout: 2)
        sink.received = nil
        let settled = expectation(description: "retry window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        source.close()
        XCTAssertEqual(bodies, 1)
        XCTAssertEqual(sink.data.count, 32)
        XCTAssertGreaterThan(sink.errors, 0)
    }

    func testIgnoredRangeNeverReachesDecoder() {
        checkRangeResponse(status: 200, range: nil, expectedBytes: 32, expectedErrors: 1)
    }
    func testWrongRangeNeverReachesDecoder() {
        checkRangeResponse(status: 206, range: "bytes 0-967/1000", expectedBytes: 32, expectedErrors: 1)
    }
    func testMatchingRangeContinuesAtRequestedByte() {
        checkRangeResponse(status: 206, range: "bytes 32-999/1000", expectedBytes: 64, expectedErrors: 0)
    }
    private func checkRangeResponse(status: Int, range: String?, expectedBytes: Int, expectedErrors: Int) {
        let (source, sink) = source()
        let received = expectation(description: "first prefix")
        sink.received = { received.fulfill() }
        HTTP.handler = { request in
            let requested = request.request.value(forHTTPHeaderField: "Range")
            if requested == "bytes=0-1" { request.respond(206, range: "bytes 0-1/1000", acceptsRanges: true); return }
            if requested == "bytes=32-" { request.respond(status, range: range, acceptsRanges: true) }
            else { request.respond(200, acceptsRanges: true) }
            request.client?.urlProtocol(request, didLoad: Data(repeating: 7, count: 32))
        }
        source.seek(at: 0)
        wait(for: [received], timeout: 2)
        sink.received = nil
        source.seek(at: 32)
        let settled = expectation(description: "range response")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        source.close()
        XCTAssertEqual(sink.data.count, expectedBytes)
        XCTAssertEqual(sink.errors, expectedErrors)
    }
}
