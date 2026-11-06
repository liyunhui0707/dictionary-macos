import Foundation

/// Minimal HTTP request value type used between the raw socket layer
/// and the route handler.
struct HTTPRequest {
    let method: String
    let path: String
    /// Header names are normalized to lowercase.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json(status: Int, _ object: Any) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(
            status: status,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Content-Length": "\(body.count)"
            ],
            body: body
        )
    }

    static func json(status: Int, raw: Data) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Content-Length": "\(raw.count)"
            ],
            body: raw
        )
    }

    static func empty(status: Int) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Length": "0"],
            body: Data()
        )
    }
}
