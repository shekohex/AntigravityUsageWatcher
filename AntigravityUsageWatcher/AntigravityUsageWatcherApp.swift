import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import os
import Security
import SwiftUI

enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.github.shekohex.AntigravityUsageWatcher"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let oauth = Logger(subsystem: subsystem, category: "oauth")
    static let languageServer = Logger(subsystem: subsystem, category: "language_server")
    static let network = Logger(subsystem: subsystem, category: "network")

    static var isVerboseEnabled: Bool {
#if DEBUG
        // Default to verbose logs in Debug while we stabilize sign-in/LS startup.
        return true
#else
        if UserDefaults.standard.bool(forKey: "debugLogsEnabled") {
            return true
        }
        return ProcessInfo.processInfo.environment["ANTIGRAVITY_DEBUG_LOGS"] == "1"
#endif
    }

    static func sanitizeExternalLogLine(_ line: String) -> String {
        var sanitized = line

        // Best-effort redaction in case a child process logs tokens.
        // Google OAuth access tokens often start with "ya29." and refresh tokens often start with "1//".
        sanitized = sanitized.replacingOccurrences(ofPattern: "ya29\\.[A-Za-z0-9._-]+", with: "<redacted>")
        sanitized = sanitized.replacingOccurrences(ofPattern: "1//[A-Za-z0-9._-]+", with: "<redacted>")

        let maxLength = 800
        if sanitized.count > maxLength {
            sanitized = String(sanitized.prefix(maxLength)) + "…"
        }

        return sanitized
    }

    static func summarizeError(_ error: Error) -> String {
        let nsError = error as NSError
        let message = nsError.localizedDescription
        if message.isEmpty {
            return "\(nsError.domain)(\(nsError.code))"
        }
        return "\(nsError.domain)(\(nsError.code)): \(message)"
    }
}

private extension String {
    func replacingOccurrences(ofPattern pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return self
        }

        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: replacement)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let model = AppModel()
    private let settingsWindow = SettingsWindowController()

    private let menu = NSMenu()
    private var isMenuOpen = false
    private var defaultsCancellable: AnyCancellable?

    private lazy var statusContentHostingView: NSHostingView<StatusMenuView> = {
        let hosting = NSHostingView(rootView: StatusMenuView(model: model))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: 360, height: max(1, size.height)))
        return hosting
    }()

    private lazy var statusContentItem: NSMenuItem = {
        let item = NSMenuItem()
        item.view = statusContentHostingView
        return item
    }()

    private lazy var refreshItem = makeMenuItem(
        title: "Refresh Now",
        systemImage: "arrow.clockwise",
        action: #selector(refreshNow),
        keyEquivalent: "r"
    )

    private lazy var switchAccountItem = makeMenuItem(
        title: "Switch Account…",
        systemImage: "person.crop.circle",
        action: #selector(switchAccount),
        keyEquivalent: ""
    )

    private lazy var pinRootItem: NSMenuItem = {
        let item = NSMenuItem(title: "Pin Model", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        menu.setSubmenu(pinMenu, for: item)
        return item
    }()

    private let pinMenu = NSMenu()

    private lazy var settingsItem = makeMenuItem(
        title: "Settings…",
        systemImage: "gearshape",
        action: #selector(openSettings),
        keyEquivalent: ","
    )

    private lazy var aboutItem = makeMenuItem(
        title: "About…",
        systemImage: "info.circle",
        action: #selector(openAbout),
        keyEquivalent: ""
    )

    private lazy var signInItem = makeMenuItem(
        title: "Sign in with Google…",
        systemImage: "person.crop.circle.badge.plus",
        action: #selector(signIn),
        keyEquivalent: "s"
    )

    private lazy var signOutItem = makeMenuItem(
        title: "Sign Out",
        systemImage: "person.crop.circle.badge.xmark",
        action: #selector(signOut),
        keyEquivalent: ""
    )

    private lazy var quitItem = makeMenuItem(
        title: "Quit",
        systemImage: "power",
        action: #selector(quit),
        keyEquivalent: "q"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.app.info("App launched (verbose=\(AppLog.isVerboseEnabled, privacy: .public))")

        setupStatusBar()

        model.onUpdate = { [weak self] in
            self?.applyStatusBarPresentation()
            self?.updateMenuItems()
        }

        defaultsCancellable = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyStatusBarPresentation()
                self?.updateMenuItems()
            }

        Task {
            await model.bootstrap()
        }
    }

    private func statusBarUsageImage() -> NSImage? {
        if let image = NSImage(named: "StatusBarIcon") {
            image.isTemplate = true
            return image
        }

        return NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "Antigravity Usage")
    }

    private func setupStatusBar() {
        let statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = statusBarUsageImage()
            button.title = ""
            button.toolTip = "Antigravity Usage"
        }


        menu.delegate = self
        menu.autoenablesItems = false
        configureMenu()
        statusItem?.menu = menu

        applyStatusBarPresentation()
        updateMenuItems()
    }

    private func applyStatusBarPresentation() {
        guard let button = statusItem?.button else {
            return
        }

        if let snapshot = model.snapshot {
            let pinned = model.pinnedModelId
            let hidden = AppSettings.hiddenModelIds()
            let visibleModels = snapshot.modelsSortedForDisplay.filter { quota in
                if let pinned, quota.modelId == pinned {
                    return true
                }
                return !hidden.contains(quota.modelId)
            }

            let primary = visibleModels.first

            if AppSettings.showStatusText, let primary {
                button.image = nil
                button.title = "\(primary.shortName) \(primary.remainingPercent)%"
            } else {
                button.image = statusBarUsageImage()
                button.title = ""
            }

            button.toolTip = snapshot.tooltipText

            if let primary {
                if primary.isExhausted || primary.remainingPercent < 15 {
                    button.contentTintColor = .systemRed
                } else if primary.remainingPercent < 25 {
                    button.contentTintColor = .systemOrange
                } else {
                    button.contentTintColor = nil
                }
            } else {
                button.contentTintColor = nil
            }

            return
        }

        button.contentTintColor = nil

        if model.isSignedIn {
            button.image = statusBarUsageImage()
            button.title = ""

            if model.isRefreshing {
                button.toolTip = "Syncing…"
            } else if let lastError = model.lastErrorMessage {
                button.toolTip = lastError
            } else {
                button.toolTip = "Signed in"
            }
        } else {
            button.image = NSImage(systemSymbolName: "person.crop.circle.badge.exclamationmark", accessibilityDescription: "Sign in")
            button.title = ""
            button.toolTip = "Sign in to show Antigravity usage"
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        rebuildPinMenu()
        updateMenuItems()

        let size = statusContentHostingView.fittingSize
        statusContentHostingView.frame.size = NSSize(width: 360, height: max(1, size.height))
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    private func configureMenu() {
        menu.removeAllItems()
        menu.addItem(statusContentItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(refreshItem)
        menu.addItem(switchAccountItem)
        menu.addItem(pinRootItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(settingsItem)
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(signInItem)
        menu.addItem(signOutItem)
        menu.addItem(quitItem)
    }

    private func updateMenuItems() {
        refreshItem.isHidden = !model.isSignedIn
        refreshItem.isEnabled = model.isSignedIn && !model.isRefreshing

        switchAccountItem.isHidden = !model.isSignedIn
        switchAccountItem.isEnabled = model.isSignedIn && !model.isRefreshing

        let hasModels = (model.snapshot?.models.isEmpty == false)
        pinRootItem.isHidden = !(model.isSignedIn && hasModels)
        pinRootItem.isEnabled = !pinRootItem.isHidden

        signInItem.isHidden = model.isSignedIn
        signInItem.isEnabled = !model.isSignedIn && !model.isRefreshing

        signOutItem.isHidden = !model.isSignedIn
        signOutItem.isEnabled = model.isSignedIn

        if isMenuOpen {
            menu.update()
        }
    }

    private func rebuildPinMenu() {
        pinMenu.removeAllItems()

        guard let snapshot = model.snapshot, !snapshot.models.isEmpty else {
            return
        }

        if model.pinnedModelId != nil {
            pinMenu.addItem(makeMenuItem(
                title: "Unpin",
                systemImage: "pin.slash",
                action: #selector(unpinModel),
                keyEquivalent: ""
            ))
            pinMenu.addItem(NSMenuItem.separator())
        }

        let hidden = AppSettings.hiddenModelIds()

        for quota in snapshot.models {
            if hidden.contains(quota.modelId), quota.modelId != model.pinnedModelId {
                continue
            }

            let item = NSMenuItem(title: quota.label, action: #selector(pinModel(_:)), keyEquivalent: "")
            item.representedObject = quota.modelId
            item.state = (quota.modelId == model.pinnedModelId) ? .on : .off
            pinMenu.addItem(item)
        }
    }

    private func makeMenuItem(title: String, systemImage: String, action: Selector?, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        return item
    }

    @objc private func signIn() {
        Task {
            await model.signIn()
        }
    }

    @objc private func signOut() {
        Task {
            await model.signOut()
        }
    }

    @objc private func quit() {
        Task { [model] in
            await model.prepareForQuit()
            NSApp.terminate(nil)
        }
    }

    @objc private func refreshNow() {
        Task {
            await model.refreshNow()
        }
    }

    @objc private func switchAccount() {
        Task {
            await model.signOut()
            await model.signIn()
        }
    }

    @objc private func openSettings() {
        AppSettings.setSelectedSettingsTab(.general)
        settingsWindow.show()
    }

    @objc private func openAbout() {
        AppSettings.setSelectedSettingsTab(.about)
        settingsWindow.show()
    }

    @objc private func pinModel(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String else {
            return
        }
        AppSettings.setModelHidden(modelId, hidden: false)
        model.setPinnedModelId(modelId)
    }

    @objc private func unpinModel() {
        model.setPinnedModelId(nil)
    }
}

// MARK: - App Model

@MainActor
final class AppModel: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    var onUpdate: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var autoRefreshTask: Task<Void, Never>?

    init() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.restartAutoRefreshIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func notifyChanged() {
        objectWillChange.send()
        onUpdate?()
    }

    private(set) var isRefreshing = false {
        didSet { notifyChanged() }
    }

    private(set) var lastErrorMessage: String? {
        didSet { notifyChanged() }
    }

    private(set) var snapshot: QuotaSnapshot? {
        didSet { notifyChanged() }
    }

    private var authState: AuthState? {
        didSet { notifyChanged() }
    }

    private var currentAccessToken: AccessToken? = nil

    private let tokenStore = TokenStore()
    private let oauth = OAuthController()
    private let languageServer = LanguageServerSupervisor()

    var isSignedIn: Bool {
        authState != nil
    }

    var pinnedModelId: String? {
        UserDefaults.standard.string(forKey: UserDefaultsKeys.pinnedModelId)
    }

    func setPinnedModelId(_ modelId: String?) {
        if let modelId {
            UserDefaults.standard.set(modelId, forKey: UserDefaultsKeys.pinnedModelId)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.pinnedModelId)
        }

        if let snapshot {
            self.snapshot = snapshot.withPinnedModelId(modelId)
        }
    }

    func bootstrap() async {
        authState = tokenStore.loadAuthState()
        restartAutoRefreshIfNeeded()

        if authState != nil {
            await refreshNow()
        }
    }

    func signIn() async {
        AppLog.app.info("Sign-in started")

        lastErrorMessage = nil
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let newState = try await oauth.signIn()
            tokenStore.saveAuthState(newState)
            authState = newState
            currentAccessToken = nil
            restartAutoRefreshIfNeeded()

            AppLog.app.info("Sign-in completed; refreshing status")
            await refreshNow()
        } catch {
            AppLog.app.error("Sign-in failed: \(String(describing: error), privacy: .public)")
            lastErrorMessage = Self.userFacingErrorMessage(prefix: "Sign-in failed", error: error)
        }
    }

    func signOut() async {
        AppLog.app.info("Sign-out")

        lastErrorMessage = nil
        snapshot = nil
        currentAccessToken = nil
        authState = nil
        restartAutoRefreshIfNeeded()

        tokenStore.deleteAuthState()
        await languageServer.stop()
    }

    func prepareForQuit() async {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        await languageServer.stop()
    }

    func refreshNow() async {
        guard let authState else {
            return
        }

        if isRefreshing {
            return
        }

        AppLog.app.debug("Refresh started")

        lastErrorMessage = nil
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let accessToken = try await oauth.getValidAccessToken(using: authState, cached: currentAccessToken)
            currentAccessToken = accessToken

            let connection = try await languageServer.ensureRunning(apiKey: accessToken.token)

            // Best-effort token sync. If this fails, GetUserStatus may still succeed.
            try? await connection.client.saveOAuthTokenInfo(accessToken: accessToken, refreshToken: authState.refreshToken)

            let statusData = try await connection.client.getUserStatus(accessToken: accessToken)
            let parsed = try QuotaParser.parseUserStatusJSON(statusData)
            let merged = parsed.withPinnedModelId(pinnedModelId)
            snapshot = merged

            let known = merged.models
                .map { KnownModel(modelId: $0.modelId, label: $0.label) }
                .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            AppSettings.saveKnownModels(known)

            AppLog.app.debug("Refresh succeeded")

        } catch {
            AppLog.app.error("Refresh failed: \(String(describing: error), privacy: .public)")
            snapshot = nil
            lastErrorMessage = Self.userFacingErrorMessage(prefix: "Failed to fetch quota", error: error)
        }
    }

    private static func userFacingErrorMessage(prefix: String, error: Error) -> String {
        if let oauthError = error as? OAuthError {
            switch oauthError {
            case .callbackListenerFailed(let detail):
                return "\(prefix): \(detail). Check app entitlements for incoming connections."
            case .callbackTimedOut:
                return "\(prefix): timed out waiting for browser redirect."
            case .remoteError(let message):
                return "\(prefix): \(message)"
            default:
                return "\(prefix): \(oauthError.localizedDescription)"
            }
        }

        if let lsError = error as? LanguageServerError {
            return "\(prefix): \(lsError.localizedDescription)"
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCannotConnectToHost {
            return "\(prefix): could not connect to the local Antigravity language server. Ensure Antigravity.app is installed and relaunch this app."
        }

        let description = error.localizedDescription
        if description.isEmpty {
            return "\(prefix): \(String(describing: error))"
        }
        return "\(prefix): \(description)"
    }

    private func restartAutoRefreshIfNeeded() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil

        guard isSignedIn else {
            return
        }

        let interval = AppSettings.refreshCadence.seconds
        guard interval > 0 else {
            return
        }

        autoRefreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled {
                    break
                }
                if !self.isSignedIn {
                    break
                }
                await self.refreshNow()
            }
        }
    }
}

// MARK: - Persistence

enum UserDefaultsKeys {
    static let pinnedModelId = "pinnedModelId"
}

struct AuthState: Codable {
    let refreshToken: String
    let tokenType: String
    let expiryDateSeconds: Int
}

final class TokenStore {
    private static let keychainAccount = "authStateV1"

    func loadAuthState() -> AuthState? {
        guard let json = KeychainStore.loadString(account: Self.keychainAccount) else {
            return nil
        }

        do {
            return try JSONDecoder().decode(AuthState.self, from: Data(json.utf8))
        } catch {
            return nil
        }
    }

    func saveAuthState(_ state: AuthState) {
        do {
            let data = try JSONEncoder().encode(state)
            if let json = String(data: data, encoding: .utf8) {
                try KeychainStore.saveString(json, account: Self.keychainAccount)
            }
        } catch {
            // Intentionally ignore; app can still function for current session.
        }
    }

    func deleteAuthState() {
        try? KeychainStore.delete(account: Self.keychainAccount)
    }
}

// MARK: - OAuth

struct AccessToken {
    let token: String
    let tokenType: String
    let expiryDate: Date

    var isExpiringSoon: Bool {
        expiryDate.timeIntervalSinceNow < 60
    }
}

final class OAuthController {
    private let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!

    func signIn() async throws -> AuthState {
        AppLog.oauth.info("OAuth sign-in starting")

        let verifier = PKCE.verifier()
        let challenge = PKCE.challengeS256(for: verifier)
        let state = PKCE.state()

        let server = OAuthCallbackServer(expectedState: state)
        let redirectURL = try await server.start()
        AppLog.oauth.info("OAuth callback listening on \(redirectURL.absoluteString, privacy: .public)")

        guard var components = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidAuthURL
        }

        components.queryItems = [
            URLQueryItem(name: "client_id", value: AntigravityConfig.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: AntigravityConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]

        guard let url = components.url else {
            throw OAuthError.invalidAuthURL
        }

        _ = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        AppLog.oauth.debug("Opened browser for consent")

        let callback = try await server.waitForCallback(timeoutSeconds: 180)
        AppLog.oauth.info("OAuth callback received")

        let token = try await exchangeCode(code: callback.code, codeVerifier: verifier, redirectURL: redirectURL)
        AppLog.oauth.info("Exchanged code for tokens (hasRefresh=\((token.refreshToken?.isEmpty == false), privacy: .public))")

        guard let refresh = token.refreshToken, !refresh.isEmpty else {
            throw OAuthError.missingRefreshToken
        }

        let expiresIn = token.expiresIn ?? 0
        let expirySeconds = Int(Date().timeIntervalSince1970) + expiresIn

        return AuthState(
            refreshToken: refresh,
            tokenType: token.tokenType ?? "Bearer",
            expiryDateSeconds: expirySeconds
        )
    }

    func getValidAccessToken(using auth: AuthState, cached: AccessToken?) async throws -> AccessToken {
        if let cached, !cached.isExpiringSoon {
            return cached
        }

        AppLog.oauth.debug("Refreshing access token")
        let token = try await refresh(refreshToken: auth.refreshToken)
        guard let accessToken = token.accessToken, !accessToken.isEmpty else {
            throw OAuthError.missingAccessToken
        }

        let expiresIn = token.expiresIn ?? 0
        let expiryDate = Date().addingTimeInterval(TimeInterval(expiresIn))

        return AccessToken(
            token: accessToken,
            tokenType: token.tokenType ?? "Bearer",
            expiryDate: expiryDate
        )
    }

    private func exchangeCode(code: String, codeVerifier: String, redirectURL: URL) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = FormURLEncoder.encode([
            "client_id": AntigravityConfig.clientId,
            "client_secret": AntigravityConfig.clientSecret,
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": codeVerifier,
            "redirect_uri": redirectURL.absoluteString,
        ])

        request.httpBody = Data(body.utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)

        if let error = decoded.error {
            throw OAuthError.remoteError(error)
        }

        guard let access = decoded.accessToken, !access.isEmpty else {
            throw OAuthError.missingAccessToken
        }

        return OAuthTokenResponse(
            accessToken: access,
            tokenType: decoded.tokenType ?? "Bearer",
            expiresIn: decoded.expiresIn ?? 0,
            refreshToken: decoded.refreshToken,
            error: nil
        )
    }

    private func refresh(refreshToken: String) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = FormURLEncoder.encode([
            "client_id": AntigravityConfig.clientId,
            "client_secret": AntigravityConfig.clientSecret,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])

        request.httpBody = Data(body.utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)

        if let error = decoded.error {
            throw OAuthError.remoteError(error)
        }

        guard let access = decoded.accessToken, !access.isEmpty else {
            throw OAuthError.missingAccessToken
        }

        return OAuthTokenResponse(
            accessToken: access,
            tokenType: decoded.tokenType ?? "Bearer",
            expiresIn: decoded.expiresIn ?? 0,
            refreshToken: decoded.refreshToken,
            error: nil
        )
    }
}

enum OAuthError: Error, LocalizedError {
    case invalidAuthURL
    case missingRefreshToken
    case missingAccessToken
    case remoteError(String)
    case callbackListenerFailed(String)
    case callbackTimedOut
    case callbackRejected

    var errorDescription: String? {
        switch self {
        case .invalidAuthURL:
            return "Invalid OAuth URL"
        case .missingRefreshToken:
            return "Missing refresh token"
        case .missingAccessToken:
            return "Missing access token"
        case .remoteError(let message):
            return message
        case .callbackListenerFailed(let detail):
            return "Failed to start local callback server: \(detail)"
        case .callbackTimedOut:
            return "Timed out waiting for browser redirect"
        case .callbackRejected:
            return "OAuth callback did not include required parameters"
        }
    }
}

struct OAuthTokenResponse: Codable {
    let accessToken: String?
    let tokenType: String?
    let expiresIn: Int?
    let refreshToken: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case error
    }
}

enum FormURLEncoder {
    static func encode(_ parameters: [String: String]) -> String {
        parameters
            .map { key, value in
                let escapedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
                let escapedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(escapedKey)=\(escapedValue)"
            }
            .sorted()
            .joined(separator: "&")
    }
}

enum PKCE {
    static func verifier() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        return base64url(Data(bytes))
    }

    static func challengeS256(for verifier: String) -> String {
        let hashed = SHA256.hash(data: Data(verifier.utf8))
        return base64url(Data(hashed))
    }

    static func state() -> String {
        base64url(Data(UUID().uuidString.utf8))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct OAuthCallback {
    let code: String
}

final class OAuthCallbackServer {
    private let expectedState: String

    private var listener: NWListener?
    private var continuation: CheckedContinuation<OAuthCallback, Error>?

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    func start() async throws -> URL {
        AppLog.oauth.debug("Starting OAuth loopback server")

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        if let loopback = IPv4Address("127.0.0.1") {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: .any)
        }

        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        continuation.resume(throwing: OAuthError.callbackListenerFailed("Listener ready but no port"))
                        return
                    }
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port)/oauth-callback")!)
                case .failed(let error):
                    continuation.resume(throwing: OAuthError.callbackListenerFailed("\(error)"))
                default:
                    break
                }
            }

            listener.start(queue: DispatchQueue(label: "oauth.callback.listener"))
        }
    }

    func waitForCallback(timeoutSeconds: TimeInterval) async throws -> OAuthCallback {
        AppLog.oauth.info("Waiting for OAuth callback (timeout=\(timeoutSeconds, privacy: .public)s)")

        return try await withThrowingTaskGroup(of: OAuthCallback.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { continuation in
                    self?.continuation = continuation
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw OAuthError.callbackTimedOut
            }

            defer {
                group.cancelAll()
                stop()
            }

            guard let result = try await group.next() else {
                throw OAuthError.invalidAuthURL
            }

            return result
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "oauth.callback.connection"))

        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] content, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            let requestText = String(decoding: content ?? Data(), as: UTF8.self)

            let firstLine = requestText.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")

            let pathPart = parts.count >= 2 ? String(parts[1]) : ""
            let components = URLComponents(string: "http://127.0.0.1\(pathPart)")

            let code = components?.queryItems?.first(where: { $0.name == "code" })?.value
            let state = components?.queryItems?.first(where: { $0.name == "state" })?.value

            let ok = (code != nil && state == self.expectedState)
            if ok {
                AppLog.oauth.info("OAuth callback accepted")
            } else {
                AppLog.oauth.error("OAuth callback rejected")
            }

            let html: String

            if ok {
                html = """
                <html><body style=\"font-family: -apple-system; padding: 24px;\">
                <h2>Signed in</h2>
                <p>You can close this window and return to the menu bar app.</p>
                </body></html>
                """
            } else {
                html = """
                <html><body style=\"font-family: -apple-system; padding: 24px;\">
                <h2>Sign-in failed</h2>
                <p>Please return to the app and try again.</p>
                </body></html>
                """
            }

            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            guard let code, let state, state == self.expectedState else {
                self.continuation?.resume(throwing: OAuthError.callbackRejected)
                self.continuation = nil
                return
            }

            self.continuation?.resume(returning: OAuthCallback(code: code))
            self.continuation = nil
        }
    }
}

// MARK: - Language Server

struct LanguageServerConnection {
    let port: UInt16
    let csrfToken: String
    let client: LanguageServerClient
}

enum ProcessKiller {
    static func forceKill(_ process: Process) {
        _ = kill(process.processIdentifier, SIGKILL)
    }
}

enum LanguageServerError: Error, LocalizedError {
    case failedToStart(port: UInt16, lastError: Error?)

    var errorDescription: String? {
        switch self {
        case .failedToStart(let port, let lastError):
            if let lastError {
                return "Language server failed to start on 127.0.0.1:\(port): \(lastError.localizedDescription)"
            }
            return "Language server failed to start on 127.0.0.1:\(port)"
        }
    }
}

actor LanguageServerSupervisor {
    private var process: Process?
    private var connection: LanguageServerConnection?
    private var currentApiKey: String?

    func ensureRunning(apiKey: String) async throws -> LanguageServerConnection {
        if let connection, process?.isRunning == true, currentApiKey == apiKey {
            return connection
        }

        await stop()

        let port = try allocatePort()
        let csrf = UUID().uuidString

        AppLog.languageServer.info("Starting language server on 127.0.0.1:\(port, privacy: .public)")

        let metadata = ProtobufBuilders.buildMetadata(apiKey: apiKey)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: AntigravityConfig.languageServerPath)
        proc.arguments = [
            "-server_port", "\(port)",
            "-random_port=false",
            "-enable_lsp=false",
            "-csrf_token", csrf,
            "-cloud_code_endpoint", AntigravityConfig.cloudCodeEndpoint,
            "-gemini_dir", AntigravityConfig.geminiDir,
            "-app_data_dir", AntigravityConfig.appDataDir,
        ]

        let stdinPipe = Pipe()
        proc.standardInput = stdinPipe

        if AppLog.isVerboseEnabled {
            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }

                let line = AppLog.sanitizeExternalLogLine(String(decoding: data, as: UTF8.self))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return }

                // Avoid double-printing: forward child process output only to stdout/stderr.
                let prefixed = "ls(stdout): \(line)\n"
                if let outData = prefixed.data(using: .utf8) {
                    try? FileHandle.standardOutput.write(contentsOf: outData)
                }
            }

            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }

                let line = AppLog.sanitizeExternalLogLine(String(decoding: data, as: UTF8.self))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return }

                // Filter extremely noisy TLS EOF spam while we debug readiness.
                if line.contains("http: TLS handshake error") {
                    return
                }

                let prefixed = "ls(stderr): \(line)\n"
                if let errData = prefixed.data(using: .utf8) {
                    try? FileHandle.standardError.write(contentsOf: errData)
                }
            }
        } else {
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
        }

        proc.terminationHandler = { process in
            AppLog.languageServer.error("Language server exited (pid=\(process.processIdentifier, privacy: .public) code=\(process.terminationStatus, privacy: .public))")
        }

        try proc.run()

        stdinPipe.fileHandleForWriting.write(metadata)
        try? stdinPipe.fileHandleForWriting.close()

        let client = try LanguageServerClient(port: port, csrfToken: csrf)

        // Wait briefly for readiness.
        var lastError: Error?
        var ready = false

        for attempt in 1...50 {
            do {
                _ = try await client.getStatus()
                ready = true
                break
            } catch {
                lastError = error
                if AppLog.isVerboseEnabled {
                    if attempt == 1 || attempt % 10 == 0 {
                        AppLog.languageServer.debug("GetStatus not ready (attempt=\(attempt, privacy: .public)): \(AppLog.summarizeError(error), privacy: .public)")
                    }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        guard ready else {
            AppLog.languageServer.error("Language server never became ready on 127.0.0.1:\(port, privacy: .public)")
            proc.terminate()
            throw LanguageServerError.failedToStart(port: port, lastError: lastError)
        }

        let conn = LanguageServerConnection(port: port, csrfToken: csrf, client: client)
        process = proc
        connection = conn
        currentApiKey = apiKey
        return conn
    }

    func stop() async {
        if let process, process.isRunning {
            process.terminate()
            try? await Task.sleep(nanoseconds: 200_000_000)
            if process.isRunning {
                ProcessKiller.forceKill(process)
            }
        }

        process = nil
        connection = nil
        currentApiKey = nil
    }

    private func allocatePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw URLError(.cannotCreateFile)
        }

        defer {
            _ = close(fd)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        var sockAddr = addr
        let bindResult = withUnsafePointer(to: &sockAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }

        guard bindResult == 0 else {
            throw URLError(.cannotCreateFile)
        }

        var outAddr = sockaddr_in()
        var outLen = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &outAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                getsockname(fd, saPtr, &outLen)
            }
        }

        guard nameResult == 0 else {
            throw URLError(.cannotCreateFile)
        }

        return UInt16(bigEndian: outAddr.sin_port)
    }
}

final class LanguageServerClient: NSObject {
    private let baseURL: URL
    private let csrfToken: String

    private let session: URLSession

    init(port: UInt16, csrfToken: String) throws {
        self.baseURL = URL(string: "https://127.0.0.1:\(port)")!
        self.csrfToken = csrfToken

        let pinned = try PinnedCertificate()
        let delegate = PinnedCASessionDelegate(pinned: pinned)
        self.session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)

        super.init()
    }

    func getStatus() async throws -> Data {
        // Connect JSON requires a JSON object, even for empty messages.
        try await call(method: "GetStatus", jsonBody: Data("{}".utf8))
    }

    func saveOAuthTokenInfo(accessToken: AccessToken, refreshToken: String) async throws {
        // Connect JSON maps google.protobuf.Timestamp to RFC3339 string.
        let expiryString = Self.rfc3339(accessToken.expiryDate)

        let payload: [String: Any] = [
            "tokenInfo": [
                "accessToken": accessToken.token,
                "tokenType": accessToken.tokenType,
                "refreshToken": refreshToken,
                "expiry": expiryString,
            ],
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await call(method: "SaveOAuthTokenInfo", jsonBody: body)
    }

    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    func getUserStatus(accessToken: AccessToken) async throws -> Data {
        // Connect JSON mapping of exa.codeium_common_pb.Metadata.
        let payload: [String: Any] = [
            "metadata": [
                "ideName": "antigravity",
                "apiKey": accessToken.token,
                "locale": "en-US",
                "os": "macOS",
                "ideVersion": "0.0.0",
                "extensionName": "google.antigravity",
                "extensionPath": AntigravityConfig.extensionPath,
                "deviceFingerprint": "usagewatcher",
                "triggerId": "menubar",
            ],
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)
        return try await call(method: "GetUserStatus", jsonBody: body)
    }

    private func call(method: String, jsonBody: Data) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("/exa.language_server_pb.LanguageServerService/\(method)"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10

        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")

        if jsonBody.isEmpty {
            // Some LS endpoints (e.g. GetStatus) reject a zero-length body when using Connect JSON.
            request.httpBody = Data("{}".utf8)
        } else {
            request.httpBody = jsonBody
        }

        if AppLog.isVerboseEnabled, method != "GetStatus" {
            AppLog.network.debug("LS request \(method, privacy: .public) (bytes=\(jsonBody.count, privacy: .public))")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            if AppLog.isVerboseEnabled, method != "GetStatus" {
                AppLog.network.debug("LS response \(method, privacy: .public) (status=\(http.statusCode, privacy: .public), bytes=\(data.count, privacy: .public))")
            }

            guard http.statusCode == 200 else {
                if AppLog.isVerboseEnabled, method != "GetStatus" {
                    let prefix = String(decoding: data.prefix(600), as: UTF8.self)
                    AppLog.network.error("LS error body prefix: \(prefix, privacy: .public)")
                }
                throw URLError(.badServerResponse)
            }

            return data
        } catch {
            if method != "GetStatus" {
                AppLog.network.error("LS call \(method, privacy: .public) failed: \(AppLog.summarizeError(error), privacy: .public)")
            }
            throw error
        }
    }
}

// MARK: - TLS pinning

struct PinnedCertificate {
    let der: Data

    init() throws {
        let pem = try String(contentsOfFile: AntigravityConfig.languageServerCertPath, encoding: .utf8)
        self.der = try PEM.decodeFirstCertificate(pem)
    }
}

final class PinnedCASessionDelegate: NSObject, URLSessionDelegate {
    private let pinned: PinnedCertificate

    private static var didLogTrustFailure = false
    private static let trustFailureLock = NSLock()

    init(pinned: PinnedCertificate) {
        self.pinned = pinned
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // The Antigravity language server uses a localhost certificate and ships a corresponding PEM.
        // SecTrust evaluation fails with "certificate is not permitted for this usage" for this cert on some systems,
        // so we do strict certificate pinning by comparing the presented certificate(s) to the pinned DER.
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        for cert in chain {
            let presentedDER = SecCertificateCopyData(cert) as Data
            if presentedDER == pinned.der {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
        }

        if AppLog.isVerboseEnabled {
            Self.trustFailureLock.lock()
            let shouldLog = !Self.didLogTrustFailure
            Self.didLogTrustFailure = true
            Self.trustFailureLock.unlock()

            if shouldLog {
                let host = challenge.protectionSpace.host
                AppLog.network.error("TLS pin mismatch for \(host, privacy: .public) (chainCount=\(chain.count, privacy: .public))")
            }
        }

        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

enum PEM {
    static func decodeFirstCertificate(_ pem: String) throws -> Data {
        let lines = pem
            .split(separator: "\n")
            .map(String.init)

        var b64 = ""
        var inCert = false

        for line in lines {
            if line.contains("BEGIN CERTIFICATE") {
                inCert = true
                continue
            }
            if line.contains("END CERTIFICATE") {
                break
            }
            if inCert {
                b64 += line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let data = Data(base64Encoded: b64) else {
            throw URLError(.cannotDecodeContentData)
        }
        return data
    }
}

// MARK: - Protobuf handshake (stdin)

enum ProtobufBuilders {
    static func buildMetadata(apiKey: String) -> Data {
        // Field numbers inferred in scripts/antigravity_ls_probe.py
        var out = Data()
        out += Proto.string(field: 1, "antigravity")
        out += Proto.string(field: 3, apiKey)
        out += Proto.string(field: 4, "en-US")
        out += Proto.string(field: 5, "macOS")
        out += Proto.string(field: 7, "0.0.0")
        out += Proto.string(field: 12, "google.antigravity")
        out += Proto.string(field: 17, AntigravityConfig.extensionPath)
        out += Proto.string(field: 24, "usagewatcher")
        out += Proto.string(field: 25, "menubar")
        return out
    }
}

enum Proto {
    static func varint(_ value: UInt64) -> Data {
        var n = value
        var bytes = [UInt8]()
        while true {
            let b = UInt8(n & 0x7F)
            n >>= 7
            if n != 0 {
                bytes.append(b | 0x80)
            } else {
                bytes.append(b)
                break
            }
        }
        return Data(bytes)
    }

    static func key(field: Int, wire: Int) -> Data {
        varint(UInt64((field << 3) | wire))
    }

    static func lengthDelimited(field: Int, payload: Data) -> Data {
        key(field: field, wire: 2) + varint(UInt64(payload.count)) + payload
    }

    static func string(field: Int, _ value: String) -> Data {
        lengthDelimited(field: field, payload: Data(value.utf8))
    }
}

// MARK: - Quota parsing

struct ModelQuota: Identifiable {
    var id: String { modelId }

    let label: String
    let modelId: String
    let remainingPercent: Int
    let usedPercent: Int
    let isExhausted: Bool
    let resetTime: Date?
    let timeUntilReset: String?

    var shortName: String {
        QuotaFormatting.shortName(label)
    }
}

struct PromptCredits {
    let available: Int
    let monthly: Int
    let usedPercent: Int
    let remainingPercent: Int
}

struct QuotaSnapshot {
    let timestamp: Date
    let accountEmail: String?
    let planLabel: String?
    let promptCredits: PromptCredits?
    let models: [ModelQuota]

    let pinnedModelId: String?

    var primaryModel: ModelQuota? {
        modelsSortedForDisplay.first
    }

    var modelsSortedForDisplay: [ModelQuota] {
        guard let pinnedModelId else {
            return models.sorted { $0.remainingPercent < $1.remainingPercent }
        }

        return models.sorted { a, b in
            if a.modelId == pinnedModelId, b.modelId != pinnedModelId { return true }
            if a.modelId != pinnedModelId, b.modelId == pinnedModelId { return false }
            return a.remainingPercent < b.remainingPercent
        }
    }

    var promptCreditsLine: String? {
        guard let promptCredits else {
            return nil
        }

        return "Credits: \(promptCredits.available.formatted()) / \(promptCredits.monthly.formatted())"
    }

    var tooltipText: String {
        var lines = [String]()
        for model in modelsSortedForDisplay {
            let active = model.modelId == pinnedModelId ? "› " : "  "
            let reset = model.timeUntilReset.map { " · \($0)" } ?? ""
            lines.append("\(active)\(model.label): \(model.remainingPercent)%\(reset)")
        }

        if let promptCreditsLine {
            lines.append("")
            lines.append(promptCreditsLine)
        }

        return lines.joined(separator: "\n")
    }

    func withPinnedModelId(_ pinnedModelId: String?) -> QuotaSnapshot {
        QuotaSnapshot(
            timestamp: timestamp,
            accountEmail: accountEmail,
            planLabel: planLabel,
            promptCredits: promptCredits,
            models: models,
            pinnedModelId: pinnedModelId
        )
    }
}

enum QuotaParser {
    static func parseUserStatusJSON(_ data: Data) throws -> QuotaSnapshot {
        let obj = try JSONSerialization.jsonObject(with: data)

        let root = obj as? [String: Any] ?? [:]
        let userStatus = (root["userStatus"] as? [String: Any]) ?? root

        let planStatus = userStatus["planStatus"] as? [String: Any]
        let planInfo = (planStatus?["planInfo"] as? [String: Any])

        let userInfo = userStatus["userInfo"] as? [String: Any]
        let accountEmail = (userInfo?["email"] as? String)
            ?? (userStatus["email"] as? String)
            ?? (root["email"] as? String)

        let planLabel = (planInfo?["planName"] as? String)
            ?? (planInfo?["name"] as? String)
            ?? (planStatus?["planName"] as? String)
            ?? (planStatus?["tier"] as? String)

        let promptCredits: PromptCredits? = nil
        /* 
        // Flow/Flex credits logic removed as requested.
        // Prompt credits are also deemed meaningless for now, so we skip parsing them.
        if let planStatus {
            let available = Int(truncating: (planStatus["availablePromptCredits"] as? NSNumber) ?? 0)
            let monthly = Int(truncating: (planInfo?["monthlyPromptCredits"] as? NSNumber) ?? 0)
            
            if monthly > 0 {
                let used = max(0, monthly - available)
                promptCredits = PromptCredits(
                    available: available,
                    monthly: monthly,
                    usedPercent: Int((Double(used) / Double(monthly) * 100).rounded()),
                    remainingPercent: Int((Double(available) / Double(monthly) * 100).rounded())
                )
            }
        }
        */

        let cascade = userStatus["cascadeModelConfigData"] as? [String: Any]
        let rawModels = cascade?["clientModelConfigs"] as? [Any] ?? []

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var models: [ModelQuota] = []
        models.reserveCapacity(rawModels.count)

        for raw in rawModels {
            guard let dict = raw as? [String: Any] else { continue }
            guard let quotaInfo = dict["quotaInfo"] as? [String: Any] else { continue }

            let label = (dict["label"] as? String) ?? "Unknown Model"

            var modelId = "unknown"
            if let modelOrAlias = dict["modelOrAlias"] as? [String: Any] {
                if let model = modelOrAlias["model"] as? String {
                    modelId = model
                } else if let alias = modelOrAlias["alias"] as? String {
                    modelId = alias
                }
            }

            let remainingFraction = (quotaInfo["remainingFraction"] as? NSNumber)?.doubleValue ?? 1
            let remainingPercent = Int((remainingFraction * 100).rounded())
            let usedPercent = max(0, 100 - remainingPercent)
            let isExhausted = remainingFraction == 0

            var resetTime: Date? = nil
            var timeUntilReset: String? = nil

            if let resetString = quotaInfo["resetTime"] as? String {
                let parsed = iso.date(from: resetString) ?? ISO8601DateFormatter().date(from: resetString)
                resetTime = parsed
                if let resetTime {
                    timeUntilReset = QuotaFormatting.formatTimeUntilReset(resetTime)
                }
            }

            models.append(
                ModelQuota(
                    label: label,
                    modelId: modelId,
                    remainingPercent: remainingPercent,
                    usedPercent: usedPercent,
                    isExhausted: isExhausted,
                    resetTime: resetTime,
                    timeUntilReset: timeUntilReset
                )
            )
        }

        return QuotaSnapshot(
            timestamp: Date(),
            accountEmail: accountEmail,
            planLabel: planLabel,
            promptCredits: promptCredits,
            models: models,
            pinnedModelId: nil
        )
    }
}

enum QuotaFormatting {
    static func shortName(_ label: String) -> String {
        if label.contains("Claude") {
            if label.contains("Sonnet") { return "Sonnet" }
            if label.contains("Opus") { return "Opus" }
            if label.contains("Haiku") { return "Haiku" }
            return "Claude"
        }
        if label.contains("Gemini") {
            if label.contains("Pro") { return "Pro" }
            if label.contains("Flash") { return "Flash" }
            return "Gemini"
        }
        if label.contains("GPT") || label.contains("O3") || label.contains("O1") {
            return "GPT"
        }

        return label.split(separator: " ").first.map { String($0.prefix(6)) } ?? "AG"
    }

    static func formatTimeUntilReset(_ resetTime: Date) -> String {
        let ms = resetTime.timeIntervalSinceNow
        if ms <= 0 {
            return "Ready"
        }
        let mins = Int(ceil(ms / 60))
        if mins < 60 {
            return "\(mins)m"
        }
        let hours = mins / 60
        let remain = mins % 60
        return "\(hours)h \(remain)m"
    }
}

// MARK: - Keychain

enum KeychainStore {
    private static let service = "com.google.antigravity.usagewatcher"

    static func loadString(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveString(_ value: String, account: String) throws {
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let update: [String: Any] = [
            kSecValueData as String: data,
        ]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return
        }

        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecSuccess {
                return
            }
            throw KeychainError(status: addStatus)
        }

        throw KeychainError(status: status)
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw KeychainError(status: status)
    }

    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus

        var description: String {
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Keychain error (status=\(status))"
        }
    }
}

// MARK: - Configuration

enum AntigravityConfig {
    // From /Users/shady/github/shekohex/opencode-antigravity-auth/src/constants.ts
    static let clientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let clientSecret = "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"

    static let scopes: [String] = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs",
    ]

    static let cloudCodeEndpoint = "https://daily-cloudcode-pa.sandbox.googleapis.com"
    static let geminiDir = (FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini").path)
    static let appDataDir = "antigravity"

    static let languageServerPath = "/Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm"
    static let languageServerCertPath = "/Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/dist/languageServer/cert.pem"
    static let extensionPath = "/Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity"
}
