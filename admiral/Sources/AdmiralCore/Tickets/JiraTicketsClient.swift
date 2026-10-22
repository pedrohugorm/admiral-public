import Foundation

/// Fetches Jira issue summary + status via the Atlassian gateway.
public enum JiraTicketsClient {
    /// Parse the issue JSON body into a `TicketRef`. Exposed for unit tests (no network).
    public static func parseIssue(key: String, data: Data) -> TicketRef? {
        guard let issue = try? JSONDecoder().decode(IssuePayload.self, from: data) else { return nil }
        let statusName = issue.fields.status?.name
        let category = TicketRef.category(fromJiraKey: issue.fields.status?.statusCategory?.key)
        return TicketRef(
            key: key,
            summary: issue.fields.summary,
            statusName: statusName,
            statusCategory: category
        )
    }

    /// GET `/ex/jira/{cloudId}/rest/api/3/issue/{key}?fields=summary,status`.
    /// Returns nil on HTTP/decode failure so callers can still show the bare key.
    public static func fetchIssue(
        key: String,
        tokens: TicketsAuthStore.Tokens,
        session: URLSession = .shared
    ) async -> TicketRef? {
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        guard let url = URL(
            string: "https://api.atlassian.com/ex/jira/\(tokens.cloudId)/rest/api/3/issue/\(encoded)?fields=summary,status"
        ) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { return nil }
            return parseIssue(key: key, data: data)
        } catch {
            return nil
        }
    }

    // MARK: - JSON

    struct IssuePayload: Decodable {
        let fields: Fields
        struct Fields: Decodable {
            let summary: String?
            let status: Status?
        }
        struct Status: Decodable {
            let name: String?
            let statusCategory: StatusCategory?
        }
        struct StatusCategory: Decodable {
            let key: String?
        }
    }
}
