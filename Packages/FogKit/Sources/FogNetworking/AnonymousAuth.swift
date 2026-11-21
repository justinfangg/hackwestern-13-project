import Foundation
import Security
import FogCore

/// Minimal Supabase anonymous sign-in (no SDK): signs up on first use, keeps the session in the
/// Keychain, and refreshes the access token before it expires or when FogKit asks after a 401.
///
/// Uses Supabase Auth's REST API:
/// - `POST /auth/v1/signup` with `{}` → anonymous user + session (anonymous sign-ins must be enabled)
/// - `POST /auth/v1/token?grant_type=refresh_token` → new session
///
/// Jonathan's `AuthService` can wrap this, or replace it with `supabase-swift`.
public actor SupabaseAnonymousAuth: AuthTokenProviding {
    public struct Session: Codable, Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresAt: Date
        public var userID: UUID

        public init(accessToken: String, refreshToken: String, expiresAt: Date, userID: UUID) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.userID = userID
        }
    }

    public enum AuthError: Error, Equatable {
        case http(status: Int, body: String)
        case invalidResponse
    }

    private let config: BackendConfig
    private let store: SessionStore
    private let urlSession: URLSession
    private var session: Session?
    private var inFlight: Task<Session, Error>?

    public init(config: BackendConfig, store: SessionStore = KeychainSessionStore(), urlSession: URLSession = .shared) {
        self.config = config
        self.store = store
        self.urlSession = urlSession
        self.session = store.load()
    }

    /// The signed-in user's id, once a session exists.
    public var userID: UUID? { session?.userID }

    public func accessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let s = session, s.expiresAt > Date().addingTimeInterval(60) {
            return s.accessToken
        }
        // One request at a time; concurrent callers share it.
        if let inFlight { return try await inFlight.value.accessToken }
        let current = session
        let task = Task { () throws -> Session in
            if let current {
                do { return try await self.refresh(current) } catch AuthError.http(let status, _) where (400..<500).contains(status) {
                    // Refresh token rejected (expired, or the user was deleted): start a new anonymous user.
                    return try await self.signUp()
                }
            }
            return try await self.signUp()
        }
        inFlight = task
        defer { inFlight = nil }
        let fresh = try await task.value
        session = fresh
        store.save(fresh)
        return fresh.accessToken
    }

    /// Forget the session (next call signs up a new anonymous user).
    public func signOut() {
        session = nil
        store.clear()
    }

    // MARK: Supabase Auth REST

    private struct TokenResponse: Decodable {
        struct User: Decodable { var id: UUID }
        var access_token: String
        var refresh_token: String
        var expires_in: Double
        var user: User
    }

    private func signUp() async throws -> Session {
        try await post("auth/v1/signup", query: nil, body: [:])
    }

    private func refresh(_ s: Session) async throws -> Session {
        try await post("auth/v1/token", query: URLQueryItem(name: "grant_type", value: "refresh_token"),
                       body: ["refresh_token": s.refreshToken])
    }

    private func post(_ path: String, query: URLQueryItem?, body: [String: String]) async throws -> Session {
        var components = URLComponents(url: config.projectURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if let query { components.queryItems = [query] }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        let t = try JSONDecoder().decode(TokenResponse.self, from: data)
        return Session(accessToken: t.access_token, refreshToken: t.refresh_token,
                       expiresAt: Date().addingTimeInterval(t.expires_in), userID: t.user.id)
    }
}

// MARK: - Session storage

public protocol SessionStore: Sendable {
    func load() -> SupabaseAnonymousAuth.Session?
    func save(_ session: SupabaseAnonymousAuth.Session)
    func clear()
}

/// Stores the session in the Keychain (this device only).
public struct KeychainSessionStore: SessionStore {
    private let service: String
    private let account = "supabase-session"

    public init(service: String = "fogofwar.auth") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> SupabaseAnonymousAuth.Session? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SupabaseAnonymousAuth.Session.self, from: data)
    }

    public func save(_ session: SupabaseAnonymousAuth.Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    public func clear() { SecItemDelete(query as CFDictionary) }
}

/// In-memory session storage (tests, previews).
public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private var value: SupabaseAnonymousAuth.Session?
    private let lock = NSLock()
    public init(_ session: SupabaseAnonymousAuth.Session? = nil) { value = session }
    public func load() -> SupabaseAnonymousAuth.Session? { lock.withLock { value } }
    public func save(_ session: SupabaseAnonymousAuth.Session) { lock.withLock { value = session } }
    public func clear() { lock.withLock { value = nil } }
}
