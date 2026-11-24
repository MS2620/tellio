import Foundation

enum HTTPError: LocalizedError {
    case status(Int, String)

    var errorDescription: String? {
        switch self {
        case let .status(code, body):
            return "HTTP \(code): \(body.prefix(200))"
        }
    }
}

extension URLSession {
    /// Performs the request and throws on non-2xx responses.
    func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError.status(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

extension JSONDecoder {
    static let snake: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }

    /// Safe as one piece of a URL path: spaces and slashes are escaped, ":" (in episode ids) is kept.
    var pathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? self
    }
}

/// Xtream Codes panels are inconsistent about whether IDs are strings or numbers.
extension KeyedDecodingContainer {
    func flexString(_ key: Key) -> String? {
        if let s = try? decode(String.self, forKey: key) { return s }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        if let d = try? decode(Double.self, forKey: key) { return String(Int(d)) }
        return nil
    }

    func flexInt(_ key: Key) -> Int? {
        if let i = try? decode(Int.self, forKey: key) { return i }
        if let s = try? decode(String.self, forKey: key) { return Int(s) }
        return nil
    }
}
