import Foundation

/// A parsed HTTP/1.1 request. Header keys are lowercased.
public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
}

/// Minimal HTTP/1.1 encode/decode for the loopback Anthropic endpoint. Supports
/// exactly what Anthropic SDK clients send: a request line, headers, and a
/// `Content-Length` body. No chunked request bodies, no keep-alive.
public enum HTTPWire {
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
