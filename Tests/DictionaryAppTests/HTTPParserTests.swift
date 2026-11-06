import Foundation
import Testing
@testable import DictionaryApp

struct HTTPParserTests {
    private func wire(_ headers: String = "", body: Data = Data()) -> Data {
        var bytes = Data("POST /v1/translate HTTP/1.1\r\n\(headers)\r\n".utf8)
        bytes.append(body)
        return bytes
    }

    // Exact unauthenticated C1 reproducer. Run only in the disposable test process.
    @Test func negativeContentLengthIsRejectedWithoutCrashing() {
        let wire = Data("POST /v1/translate HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)
        #expect(throws: (any Error).self) {
            _ = try HTTPServer.parseRequest(from: wire)
        }
    }

    @Test(arguments: ["", "abc", "-0", "+1", "1.0", "0x10", "1e3", "1 0", "1\t0",
                      "999999999999999999999999999999999999", "１", "٣", "1\0", "\u{a0}1"])
    func invalidDecimalLengthsAreRejected(_ value: String) {
        #expect(throws: (any Error).self) {
            _ = try HTTPServer.parseRequest(from: wire("Content-Length: \(value)\r\n"))
        }
    }

    @Test(arguments: [
        "Content-Length: 0\r\ncontent-length: 0\r\n",
        "Content-Length: 0\r\nCONTENT-LENGTH: 1\r\n",
        "Content-Length: -1\r\nContent-Length: 0\r\n",
        "Content-Length: 1, 1\r\n", "Content-Length: 0, 1\r\n",
        "Content-Length : 0\r\n", "Content-Length\r\n", "Content-Length: 1\r\n 0\r\n",
        "Transfer-Encoding: chunked\r\n", "Transfer-Encoding: identity\r\nContent-Length: 0\r\n"
    ])
    func ambiguousOrUnsupportedFramingIsRejected(_ headers: String) {
        #expect(throws: (any Error).self) { _ = try HTTPServer.parseRequest(from: wire(headers)) }
    }

    @Test func zeroAbsentAndOWSLengthsRemainSupported() throws {
        for headers in ["", "Content-Length: 0\r\n", "cOnTeNt-LeNgTh:\t000 \t\r\n"] {
            let request = try #require(try HTTPServer.parseRequest(from: wire(headers)))
            #expect(request.method == "POST")
            #expect(request.path == "/v1/translate")
            #expect(request.body.isEmpty)
        }
    }

    @Test func fragmentedHeadersAndBodyRemainIncompleteUntilAllBytesArrive() throws {
        let body = Data("bank 河岸".utf8)
        let bytes = wire("Authorization: Bearer synthetic-test-value\r\nContent-Length: \(body.count)\r\n", body: body)
        for count in 0..<bytes.count {
            #expect(try HTTPServer.parseRequest(from: Data(bytes.prefix(count))) == nil)
        }
        let request = try #require(try HTTPServer.parseRequest(from: bytes))
        #expect(request.body == body)
        #expect(request.header("Authorization") == "Bearer synthetic-test-value")
    }

    @Test func maximumRepresentableLengthWaitsWithoutIndexOverflow() throws {
        #expect(try HTTPServer.parseRequest(from: wire("Content-Length: \(Int.max)\r\n")) == nil)
    }

    @Test(arguments: ["", "ignored"])
    func nonzeroDataIndicesAndTrailingBytesDoNotChangeBodyBounds(_ trailing: String) throws {
        let bytes = wire("Content-Length: 4\r\n", body: Data("bank\(trailing)".utf8))
        let offset = (Data([1, 2, 3]) + bytes).dropFirst(3)
        let request = try #require(try HTTPServer.parseRequest(from: offset))
        #expect(request.body == Data("bank".utf8))
    }

    @Test func malformedRequestDoesNotPoisonNextValidParse() throws {
        #expect(throws: (any Error).self) {
            _ = try HTTPServer.parseRequest(from: wire("Content-Length: invalid\r\n"))
        }
        let next = try #require(try HTTPServer.parseRequest(from: wire("Content-Length: 4\r\n", body: Data("bank".utf8))))
        #expect(next.body == Data("bank".utf8))
    }
}
