import AppKit
import AuthenticationServices
import AdmiralCore

/// One Jira sign-in: an `ASWebAuthenticationSession` on the `admiral` scheme, plus the PKCE
/// pair it was started with so the callback can be exchanged. Tokens go to the Keychain.
@MainActor
final class JiraAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    let pkce = JiraOAuth.makePKCE()
    private var session: ASWebAuthenticationSession?

    /// Present the Atlassian consent page. `completion` gets the callback URL, or an error
    /// (including the user cancelling).
    @discardableResult
    func start(clientId: String, completion: @escaping (Result<URL, Error>) -> Void) -> Bool {
        let url = JiraOAuth.authorizationURL(clientId: clientId, pkce: pkce)
        let s = ASWebAuthenticationSession(url: url, callback: .customScheme("admiral")) { callback, error in
            DispatchQueue.main.async {
                if let callback { completion(.success(callback)) }
                else { completion(.failure(error ?? JiraOAuth.OAuthError.missingCode)) }
            }
        }
        s.presentationContextProvider = self
        session = s
        return s.start()
    }

    func cancel() { session?.cancel() }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
    }
}
