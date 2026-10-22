import Foundation
import CryptoKit

/// Atlassian OAuth 2.0 (3LO) + PKCE for Jira Cloud.
///
/// Auth:  `https://auth.atlassian.com/authorize`
/// Token: `https://auth.atlassian.com/oauth/token`
/// Redirect: `admiral://oauth/jira`
/// Scopes: `read:jira-work offline_access`
///
/// Atlassian has no public-client mode: the token endpoint also needs the app's client
/// secret (Keychain-only, like the tokens). PKCE is sent on top as defense in depth.
/// Tokens land in `TicketsAuthStore` (Keychain only).
public enum JiraOAuth {
    public static let redirectURI = "admiral://oauth/jira"
    public static let authorizeURL = URL(string: "https://auth.atlassian.com/authorize")!
    public static let tokenURL = URL(string: "https://auth.atlassian.com/oauth/token")!
    public static let resourcesURL = URL(string: "https://api.atlassian.com/oauth/token/accessible-resources")!
    public static let scopes = "read:jira-work offline_access"

    public struct PKCE: Sendable {
        public let verifier: String
        public let challenge: String
        public let state: String
    }

    public static func makePKCE() -> PKCE {
        let verifier = randomURLSafe(32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        return PKCE(verifier: verifier, challenge: challenge, state: randomURLSafe(16))
    }

    /// Build the authorize URL for `ASWebAuthenticationSession`.
    public static func authorizationURL(clientId: String, pkce: PKCE) -> URL {
        var comps = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "audience", value: "api.atlassian.com"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return comps.url!
    }

    public enum OAuthError: Error, LocalizedError {
        case missingCode
        case stateMismatch
        case http(Int, String)
        case decode
        case noCloudId
        case missingClientSecret
        case notConnected

        public var errorDescription: String? {
            switch self {
            case .missingCode: return "Authorization response had no code."
            case .stateMismatch: return "OAuth state mismatch."
            case .http(let code, let body): return "Token exchange failed (\(code)): \(body)"
            case .decode: return "Could not decode token response."
            case .noCloudId: return "No Jira Cloud site matched the configured site URL."
            case .missingClientSecret: return "Set the OAuth client secret first."
            case .notConnected: return "Jira is not connected."
            }
        }
    }

    /// Exchange the redirect callback for tokens, resolve cloudId, persist to Keychain.
    public static func complete(
        callbackURL: URL,
        clientId: String,
        siteURL: String,
        pkce: PKCE,
        session: URLSession = .shared
    ) async throws {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let code = items.first(where: { $0.name == "code" })?.value
        let state = items.first(where: { $0.name == "state" })?.value
        guard let code, !code.isEmpty else { throw OAuthError.missingCode }
        guard state == pkce.state else { throw OAuthError.stateMismatch }

        guard let secret = TicketsAuthStore.clientSecret else { throw OAuthError.missingClientSecret }
        let token = try await exchangeCode(
            code: code, clientId: clientId, secret: secret, verifier: pkce.verifier, session: session)
        let cloudId = try await resolveCloudId(
            accessToken: token.accessToken, siteURL: siteURL, session: session)
        let expiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn))
        TicketsAuthStore.save(.init(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? "",
            expiresAt: expiresAt,
            cloudId: cloudId
        ))
    }

    /// Refresh when expired; updates Keychain. Returns current valid tokens.
    public static func validTokens(
        clientId: String,
        session: URLSession = .shared
    ) async throws -> TicketsAuthStore.Tokens {
        guard var tokens = TicketsAuthStore.load() else { throw OAuthError.notConnected }
        guard tokens.isExpired else { return tokens }
        guard let secret = TicketsAuthStore.clientSecret else { throw OAuthError.missingClientSecret }
        let refreshed = try await refresh(
            refreshToken: tokens.refreshToken, clientId: clientId, secret: secret, session: session)
        tokens.accessToken = refreshed.accessToken
        if let r = refreshed.refreshToken, !r.isEmpty { tokens.refreshToken = r }
        tokens.expiresAt = Date().addingTimeInterval(TimeInterval(refreshed.expiresIn))
        TicketsAuthStore.save(tokens)
        return tokens
    }

    // MARK: - HTTP

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private struct AccessibleResource: Decodable {
        let id: String
        let url: String
    }

    private static func exchangeCode(
        code: String, clientId: String, secret: String, verifier: String, session: URLSession
    ) async throws -> TokenResponse {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "client_secret": secret,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await postToken(req, session: session)
    }

    private static func refresh(
        refreshToken: String, clientId: String, secret: String, session: URLSession
    ) async throws -> TokenResponse {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": clientId,
            "client_secret": secret,
            "refresh_token": refreshToken,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await postToken(req, session: session)
    }

    private static func postToken(_ req: URLRequest, session: URLSession) async throws -> TokenResponse {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw OAuthError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !decoded.accessToken.isEmpty
        else { throw OAuthError.decode }
        return decoded
    }

    private static func resolveCloudId(
        accessToken: String, siteURL: String, session: URLSession
    ) async throws -> String {
        var req = URLRequest(url: resourcesURL)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw OAuthError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let resources = try? JSONDecoder().decode([AccessibleResource].self, from: data),
              !resources.isEmpty
        else { throw OAuthError.noCloudId }

        let wantHost = URL(string: siteURL)?.host?.lowercased()
        if let wantHost,
           let match = resources.first(where: { URL(string: $0.url)?.host?.lowercased() == wantHost }) {
            return match.id
        }
        // Fall back to the first resource when siteURL is empty or unmatched.
        return resources[0].id
    }

    private static func randomURLSafe(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
