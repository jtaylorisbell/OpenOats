import Foundation

/// M2M OAuth client for Databricks workspaces.
///
/// Exchanges a service principal's client_id + client_secret for a short-lived
/// access token at `<workspace>/oidc/v1/token` and caches it until shortly
/// before expiry. Tokens are typically valid for ~1 hour; we refresh 60s early
/// to absorb clock skew and avoid mid-request expiry.
actor DatabricksAuth {
    static let shared = DatabricksAuth()

    struct Credentials: Hashable, Sendable {
        let workspaceHost: String
        let clientID: String
        let clientSecret: String
    }

    enum AuthError: LocalizedError {
        case invalidWorkspaceURL(String)
        case missingCredentials
        case tokenExchangeFailed(status: Int, body: String?)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .invalidWorkspaceURL(let raw):
                return "Invalid Databricks workspace URL: \(raw)"
            case .missingCredentials:
                return "Databricks client ID and secret are required"
            case .tokenExchangeFailed(let status, let body):
                if let body, !body.isEmpty {
                    return "Databricks OAuth token exchange failed (HTTP \(status)): \(body)"
                }
                return "Databricks OAuth token exchange failed (HTTP \(status))"
            case .malformedResponse:
                return "Databricks OAuth response was malformed"
            }
        }
    }

    private struct CachedToken {
        let value: String
        let expiresAt: Date
    }

    private var cache: [Credentials: CachedToken] = [:]
    private static let refreshLeadSeconds: TimeInterval = 60

    /// Returns a valid bearer token, refreshing if cached value is missing or
    /// near expiry.
    func token(for credentials: Credentials) async throws -> String {
        if let cached = cache[credentials],
           cached.expiresAt.timeIntervalSinceNow > Self.refreshLeadSeconds {
            return cached.value
        }
        let fresh = try await exchange(credentials: credentials)
        cache[credentials] = fresh
        return fresh.value
    }

    /// Drops any cached token for these credentials. Useful when settings change.
    func invalidate(for credentials: Credentials) {
        cache.removeValue(forKey: credentials)
    }

    /// Clear all cached tokens.
    func invalidateAll() {
        cache.removeAll()
    }

    // MARK: - Internals

    private func exchange(credentials: Credentials) async throws -> CachedToken {
        guard !credentials.clientID.isEmpty, !credentials.clientSecret.isEmpty else {
            throw AuthError.missingCredentials
        }
        guard let tokenURL = Self.tokenURL(for: credentials.workspaceHost) else {
            throw AuthError.invalidWorkspaceURL(credentials.workspaceHost)
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let basic = "\(credentials.clientID):\(credentials.clientSecret)"
            .data(using: .utf8)!
            .base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")

        let body = "grant_type=client_credentials&scope=all-apis"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.malformedResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw AuthError.tokenExchangeFailed(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        let lifetime = TimeInterval(decoded.expires_in ?? 3600)
        return CachedToken(
            value: decoded.access_token,
            expiresAt: Date().addingTimeInterval(lifetime)
        )
    }

    /// Builds the OIDC token endpoint from a user-provided workspace URL.
    /// Accepts forms like `https://workspace.cloud.databricks.com`,
    /// `workspace.cloud.databricks.com`, or with a trailing slash.
    static func tokenURL(for rawWorkspace: String) -> URL? {
        guard let base = normalizedWorkspaceURL(rawWorkspace) else { return nil }
        return base.appendingPathComponent("oidc/v1/token")
    }

    /// Builds the chat completions URL for the Databricks Foundation Model APIs.
    /// Path: `<workspace>/serving-endpoints/chat/completions`.
    static func chatCompletionsURL(for rawWorkspace: String) -> URL? {
        guard let base = normalizedWorkspaceURL(rawWorkspace) else { return nil }
        return base
            .appendingPathComponent("serving-endpoints")
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
    }

    private static func normalizedWorkspaceURL(_ rawWorkspace: String) -> URL? {
        var raw = rawWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.lowercased().hasPrefix("http://") && !raw.lowercased().hasPrefix("https://") {
            raw = "https://" + raw
        }
        // Drop trailing slash so appendingPathComponent doesn't produce double slashes.
        while raw.hasSuffix("/") { raw.removeLast() }
        return URL(string: raw)
    }

    private struct TokenResponse: Codable {
        let access_token: String
        let token_type: String?
        let expires_in: Int?
        let scope: String?
    }
}
