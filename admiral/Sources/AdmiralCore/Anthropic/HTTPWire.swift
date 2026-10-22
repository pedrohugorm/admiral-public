import Foundation

/// A parsed HTTP/1.1 request. Header keys are lowercased.
public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    /// True for a request that looks like a browser sent it rather than an SDK client, curl
    /// or an MCP client — refused on every route the loopback server serves. Browsers always
    /// send `Origin` on cross-origin fetch/XHR; those clients never do. A DNS-rebinding
    /// attacker reaches the loopback server via a hostname that resolves to 127.0.0.1, so a
    /// non-loopback `Host` header is the other tell.
    public var looksBrowserOriginated: Bool {
        if let origin = headers["origin"], !origin.isEmpty { return true }
        if let host = headers["host"], !host.isEmpty {
            if !Self.allowedLoopbackHosts.contains(Self.hostWithoutPort(host)) { return true }
        }
        return false
    }

    private static let allowedLoopbackHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]"]

    /// Strip a trailing `:port` from a `Host` header value, preserving the
    /// bracket form of an IPv6 literal (e.g. `[::1]:4141` -> `[::1]`).
    private static func hostWithoutPort(_ host: String) -> String {
        if host.hasPrefix("["), let bracketEnd = host.firstIndex(of: "]") {
            return String(host[...bracketEnd])
        }
        if let colon = host.lastIndex(of: ":") {
            return String(host[..<colon])
        }
        return host
    }
}

/// Minimal HTTP/1.1 encode/decode for the loopback Anthropic endpoint. Supports
/// exactly what Anthropic SDK clients send: a request line, headers, and a
/// `Content-Length` body. No chunked request bodies, no keep-alive.
public enum HTTPWire {
    /// How long a connection may take to deliver its whole request, and how long any one
    /// write to it may block.
    public static let ioTimeout: TimeInterval = 10

    /// Read one request from a connected, blocking socket. Sets the socket's read and write
    /// timeouts to `timeout` (the writes that answer it inherit the send timeout), and gives
    /// the whole request the same budget, so neither a silent client nor one dribbling a byte
    /// at a time holds the connection longer. nil on EOF, a timeout, or past `maxBytes`.
    public static func readRequest(from fd: Int32, timeout: TimeInterval = ioTimeout,
                                   maxBytes: Int = 10 << 20) -> HTTPRequest? {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while buffer.count < maxBytes, Date() < deadline {
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            if let parsed = parse(buffer) { return parsed }
        }
        return nil
    }

    /// Parse a complete request from accumulated bytes; nil until head + body have arrived.
    public static func parse(_ buffer: Data) -> HTTPRequest? {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0 else { return nil }
        let bodyStart = headEnd.upperBound
        guard buffer.count - bodyStart >= length else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        return HTTPRequest(method: requestLine[0], path: requestLine[1], headers: headers, body: body)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 503: "Service Unavailable"
        case 529: "Overloaded"
        default: "Error"
        }
    }

    public static func response(status: Int, body: Data) -> Data {
        var out = Data("HTTP/1.1 \(status) \(reason(status))\r\n".utf8)
        out.append(Data("Content-Type: application/json\r\n".utf8))
        out.append(Data("Content-Length: \(body.count)\r\n".utf8))
        out.append(Data("Connection: close\r\n\r\n".utf8))
        out.append(body)
        return out
    }

    public static func sseHead() -> Data {
        Data(("HTTP/1.1 200 OK\r\n"
              + "Content-Type: text/event-stream\r\n"
              + "Cache-Control: no-cache\r\n"
              + "Connection: close\r\n\r\n").utf8)
    }

    public static func sseFrame(event: String, data: Data) -> Data {
        var out = Data("event: \(event)\ndata: ".utf8)
        out.append(data)
        out.append(Data("\n\n".utf8))
        return out
    }
}
