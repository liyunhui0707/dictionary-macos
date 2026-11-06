import Foundation
import Network

/// Minimal HTTP/1.1 server bound to 127.0.0.1 only. Single-route: delegates
/// every request to the injected handler. Does NOT handle keep-alive,
/// chunked transfer, pipelining, or HTTPS — by design, since the only
/// client is a local browser extension making single-shot POSTs.
final class HTTPServer {
    private let port: UInt16
    private let handler: TranslateHandler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "DictionaryApp.HTTPServer")

    /// Allows isolated socket tests to use an OS-assigned port instead of 49152.
    var boundPort: UInt16? { listener?.port?.rawValue }

    init(port: UInt16, handler: TranslateHandler) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        // Bind to 127.0.0.1 explicitly — never to the wildcard. The
        // requiredLocalEndpoint constraint ensures we listen on loopback only.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("HTTPServer listener failed: \(error)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                NSLog("HTTPServer receive error: \(error)")
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data { buffer.append(data) }

            // Have we received the full request? Headers end with \r\n\r\n;
            // body length is Content-Length.
            do {
                if let request = try Self.parseRequest(from: buffer) {
                    Task {
                        let result = await self.handler.handle(request)
                        self.send(result, on: connection)
                    }
                } else if isComplete {
                    // Client closed before sending a full request.
                    connection.cancel()
                } else {
                    self.receive(on: connection, accumulated: buffer)
                }
            } catch {
                // Reject malformed framing before authentication; never log input.
                self.send(.empty(status: 400), on: connection)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: Self.serialize(response), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func serialize(_ response: HTTPResponse) -> Data {
        let statusText = Self.statusText(for: response.status)
        var headerLines = "HTTP/1.1 \(response.status) \(statusText)\r\n"
        var headers = response.headers
        if response.status == 204 {
            headers = headers.filter { !["content-length", "transfer-encoding"].contains($0.key.lowercased()) }
        } else if headers["Content-Length"] == nil {
            headers["Content-Length"] = "\(response.body.count)"
        }
        if headers["Connection"] == nil {
            headers["Connection"] = "close"
        }
        for (k, v) in headers {
            headerLines += "\(k): \(v)\r\n"
        }
        headerLines += "\r\n"

        var payload = Data(headerLines.utf8)
        if response.status != 204 { payload.append(response.body) }
        return payload
    }

    // MARK: - Parsing

    enum ParseError: Error { case invalidRequest }

    /// Nil means incomplete. Invalid framing throws so the connection is rejected,
    /// rather than buffered indefinitely or passed to the authenticated handler.
    static func parseRequest(from buffer: Data) throws -> HTTPRequest? {
        // Find header terminator.
        let separator = Data([0x0d, 0x0a, 0x0d, 0x0a]) // \r\n\r\n
        guard let separatorRange = buffer.range(of: separator) else { return nil }

        let headerData = buffer[..<separatorRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else { throw ParseError.invalidRequest }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw ParseError.invalidRequest }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { throw ParseError.invalidRequest }
        let method = requestParts[0]
        let path = requestParts[1]

        var headers: [String: String] = [:]
        let fieldCharacters = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  line[..<colon].utf8.allSatisfy({ fieldCharacters.contains($0) }) else {
                throw ParseError.invalidRequest
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            // This single-request server does not implement transfer codings.
            // Reject even identical duplicate lengths instead of choosing a winner.
            guard name != "transfer-encoding",
                  !(name == "content-length" && headers[name] != nil) else { throw ParseError.invalidRequest }
            headers[name] = value
        }

        let lengthValue = headers["content-length"] ?? "0"
        guard !lengthValue.isEmpty, lengthValue.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let contentLength = Int(lengthValue) else { throw ParseError.invalidRequest }
        let bodyStart = separatorRange.upperBound
        let bodyAvailable = buffer.endIndex - bodyStart
        // Check against available bytes before adding indices (including Int.max).
        guard bodyAvailable >= contentLength else { return nil }

        let body = buffer[bodyStart..<(bodyStart + contentLength)]
        return HTTPRequest(method: method, path: path, headers: headers, body: Data(body))
    }

    static func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }
}
