import AppKit
import CryptoKit
import Foundation
import Network

/// Errors surfaced by the Google OAuth flow.
enum GoogleOAuthError: LocalizedError {
    case missingClientCredentials
    case userCancelled
    case redirectFailed
    case tokenExchangeFailed(status: Int, body: String)
    case userInfoFailed
    case invalidResponse
    case noRefreshToken
    case alreadyInProgress

    var errorDescription: String? {
        switch self {
        case .missingClientCredentials:
            return "Add your Google OAuth client ID and client secret in Settings first."
        case .userCancelled:
            return "Sign-in was cancelled."
        case .redirectFailed:
            return "Could not capture the OAuth redirect from Google."
        case .tokenExchangeFailed(let status, _):
            return "Google rejected the sign-in (HTTP \(status))."
        case .userInfoFailed:
            return "Signed in, but could not look up the account email."
        case .invalidResponse:
            return "Google returned an unexpected response."
        case .noRefreshToken:
            return "Google did not return a refresh token. Re-run with prompt=consent."
        case .alreadyInProgress:
            return "A Google sign-in is already in progress."
        }
    }
}

/// Stored tokens for the Google account currently signed in.
private struct GoogleTokenBundle: Codable {
    var refreshToken: String
    var accessToken: String?
    var accessTokenExpiresAt: Date?
    var email: String?
}

/// Persistent storage interface for Google tokens. Production uses the Keychain; tests inject a mock.
protocol GoogleOAuthStorage: Sendable {
    func loadTokens() -> Data?
    func saveTokens(_ data: Data)
    func deleteTokens()
}

struct KeychainGoogleOAuthStorage: GoogleOAuthStorage {
    static let key = "googleCalendarOAuthTokens"

    func loadTokens() -> Data? {
        guard let stringValue = KeychainHelper.load(key: Self.key) else { return nil }
        return stringValue.data(using: .utf8)
    }

    func saveTokens(_ data: Data) {
        guard let stringValue = String(data: data, encoding: .utf8) else { return }
        KeychainHelper.save(key: Self.key, value: stringValue)
    }

    func deleteTokens() {
        KeychainHelper.delete(key: Self.key)
    }
}

/// Drives the OAuth 2.0 Authorization Code + PKCE flow against Google for a Desktop OAuth client.
///
/// The redirect URI is a loopback HTTP server bound to a random port — the same pattern used by
/// gcloud and Google's official Python helpers. The user must supply their own Google OAuth
/// client ID and secret (registered as a "Desktop application" in Google Cloud Console) — see
/// README for setup.
@MainActor
final class GoogleOAuthClient {
    private let clientID: String
    private let clientSecret: String
    private let storage: GoogleOAuthStorage
    private let urlSession: URLSession
    private let scopes = [
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/userinfo.email",
    ]

    private var inFlight = false

    init(
        clientID: String,
        clientSecret: String,
        storage: GoogleOAuthStorage = KeychainGoogleOAuthStorage(),
        urlSession: URLSession = .shared
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.storage = storage
        self.urlSession = urlSession
    }

    /// True if a refresh token is persisted locally.
    var hasStoredTokens: Bool { loadBundle()?.refreshToken.isEmpty == false }

    /// The email of the signed-in account, if known.
    var storedAccountEmail: String? { loadBundle()?.email }

    /// Run the full authorization flow. Returns the signed-in account email.
    func authorize() async throws -> String {
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            throw GoogleOAuthError.missingClientCredentials
        }
        guard !inFlight else {
            throw GoogleOAuthError.alreadyInProgress
        }
        inFlight = true
        defer { inFlight = false }

        let listener = try LoopbackRedirectListener()
        try listener.start()
        let redirectURI = "http://127.0.0.1:\(listener.port)/callback"

        let verifier = Self.randomCodeVerifier()
        let challenge = Self.codeChallenge(forVerifier: verifier)
        let state = Self.randomState()

        guard let authURL = buildAuthorizationURL(
            redirectURI: redirectURI,
            codeChallenge: challenge,
            state: state
        ) else {
            listener.cancel()
            throw GoogleOAuthError.invalidResponse
        }

        NSWorkspace.shared.open(authURL)

        let callback: LoopbackCallback
        do {
            callback = try await listener.waitForCallback()
        } catch {
            throw GoogleOAuthError.redirectFailed
        }

        if let errorParam = callback.queryItems["error"] {
            if errorParam == "access_denied" {
                throw GoogleOAuthError.userCancelled
            }
            throw GoogleOAuthError.tokenExchangeFailed(status: 0, body: errorParam)
        }

        guard callback.queryItems["state"] == state, let code = callback.queryItems["code"] else {
            throw GoogleOAuthError.redirectFailed
        }

        let tokenResponse = try await exchangeCodeForTokens(
            code: code,
            codeVerifier: verifier,
            redirectURI: redirectURI
        )

        guard let refreshToken = tokenResponse.refresh_token else {
            throw GoogleOAuthError.noRefreshToken
        }

        let email = try await fetchUserEmail(accessToken: tokenResponse.access_token)

        let bundle = GoogleTokenBundle(
            refreshToken: refreshToken,
            accessToken: tokenResponse.access_token,
            accessTokenExpiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in ?? 3600)),
            email: email
        )
        saveBundle(bundle)
        return email
    }

    /// Returns a usable access token, refreshing if needed.
    func accessToken() async throws -> String {
        guard var bundle = loadBundle() else {
            throw GoogleOAuthError.noRefreshToken
        }
        if let token = bundle.accessToken,
           let expiresAt = bundle.accessTokenExpiresAt,
           expiresAt.timeIntervalSinceNow > 60 {
            return token
        }
        let refreshed = try await refreshAccessToken(refreshToken: bundle.refreshToken)
        bundle.accessToken = refreshed.access_token
        bundle.accessTokenExpiresAt = Date().addingTimeInterval(TimeInterval(refreshed.expires_in ?? 3600))
        saveBundle(bundle)
        return refreshed.access_token
    }

    /// Clear stored tokens.
    func signOut() {
        storage.deleteTokens()
    }

    // MARK: - Network calls

    private func buildAuthorizationURL(
        redirectURI: String,
        codeChallenge: String,
        state: String
    ) -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components?.url
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
    }

    private struct UserInfoResponse: Decodable {
        let email: String
    }

    private func exchangeCodeForTokens(
        code: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> TokenResponse {
        let params: [String: String] = [
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier,
        ]
        return try await postToken(params: params)
    }

    private func refreshAccessToken(refreshToken: String) async throws -> TokenResponse {
        let params: [String: String] = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        return try await postToken(params: params)
    }

    private func postToken(params: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Self.formEncode(params).data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleOAuthError.tokenExchangeFailed(status: status, body: body)
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw GoogleOAuthError.invalidResponse
        }
    }

    private func fetchUserEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GoogleOAuthError.userInfoFailed
        }
        do {
            return try JSONDecoder().decode(UserInfoResponse.self, from: data).email
        } catch {
            throw GoogleOAuthError.invalidResponse
        }
    }

    // MARK: - Storage

    private func loadBundle() -> GoogleTokenBundle? {
        guard let data = storage.loadTokens() else { return nil }
        return try? JSONDecoder().decode(GoogleTokenBundle.self, from: data)
    }

    private func saveBundle(_ bundle: GoogleTokenBundle) {
        guard let data = try? JSONEncoder().encode(bundle) else { return }
        storage.saveTokens(data)
    }

    // MARK: - PKCE / utilities

    nonisolated static func randomCodeVerifier(length: Int = 64) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var result = ""
        result.reserveCapacity(length)
        for _ in 0..<length {
            result.append(alphabet.randomElement()!)
        }
        return result
    }

    nonisolated static func codeChallenge(forVerifier verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func randomState() -> String {
        UUID().uuidString
    }

    nonisolated static func formEncode(_ params: [String: String]) -> String {
        // RFC 3986 unreserved characters: ALPHA / DIGIT / "-" / "." / "_" / "~"
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return params
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
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

// MARK: - Loopback HTTP Listener

struct LoopbackCallback: Sendable {
    let queryItems: [String: String]
}

/// Minimal one-shot HTTP listener bound to `127.0.0.1` on a randomly chosen port.
/// Returns the parsed query items from the first valid GET it receives.
final class LoopbackRedirectListener: @unchecked Sendable {
    private let listener: NWListener
    private var continuation: CheckedContinuation<LoopbackCallback, Error>?
    private let queue = DispatchQueue(label: "openoats.googleoauth.loopback")
    private var hasResumed = false
    private var liveConnections: [NWConnection] = []

    let port: UInt16

    init() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.start(queue: queue)
        // Wait briefly for `port` to populate.
        let deadline = Date().addingTimeInterval(2)
        while listener.port == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let actualPort = listener.port else {
            listener.cancel()
            throw GoogleOAuthError.redirectFailed
        }
        self.port = actualPort.rawValue
    }

    func start() throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
    }

    func waitForCallback() async throws -> LoopbackCallback {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
            }
        }
    }

    func cancel() {
        queue.async {
            self.listener.cancel()
            for connection in self.liveConnections {
                connection.cancel()
            }
            self.liveConnections.removeAll()
            if !self.hasResumed, let continuation = self.continuation {
                self.hasResumed = true
                self.continuation = nil
                continuation.resume(throwing: GoogleOAuthError.redirectFailed)
            }
        }
    }

    private func handle(connection: NWConnection) {
        liveConnections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            defer { connection.cancel() }
            guard let data, let request = String(data: data, encoding: .utf8) else { return }
            guard let firstLine = request.split(separator: "\r\n", omittingEmptySubsequences: true).first else { return }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else { return }
            let path = String(parts[1])
            guard let queryItems = self.parseQueryItems(fromPath: path) else { return }

            let body = "<html><body><h2>You can close this window.</h2><p>OpenOats has finished connecting to Google Calendar.</p></body></html>"
            let response = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Content-Length: \(body.utf8.count)\r
                Connection: close\r
                \r
                \(body)
                """
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })

            if !self.hasResumed, let continuation = self.continuation {
                self.hasResumed = true
                self.continuation = nil
                continuation.resume(returning: LoopbackCallback(queryItems: queryItems))
                self.listener.cancel()
            }
        }
    }

    private func parseQueryItems(fromPath path: String) -> [String: String]? {
        guard let components = URLComponents(string: "http://127.0.0.1\(path)") else { return nil }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value {
                result[item.name] = value
            }
        }
        return result
    }
}
