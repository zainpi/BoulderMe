import Foundation

/// Build-time settings, read from Info.plist keys filled by Config/*.xcconfig.
/// Holds no secrets: everything here ships inside the app.
struct AppConfig: Sendable {
    enum Environment: String, Sendable {
        case debug, staging, production
    }

    let environment: Environment
    let apiBaseURL: URL
    var privacyURL = URL(string: "https://boulderme.app/privacy")!
    var termsURL = URL(string: "https://boulderme.app/terms")!
    var supportURL = URL(string: "https://boulderme.app/support")!
    let version: String
    let build: String
    /// Launch argument `-BMDemo YES` opens straight into demo mode (screenshots, UI tests).
    let startInDemo: Bool

    static func load(bundle: Bundle = .main, arguments: UserDefaults = .standard) -> AppConfig {
        let info = bundle.infoDictionary ?? [:]
        let environment = (info["BMEnvironment"] as? String).flatMap(Environment.init(rawValue:)) ?? .production
        let fallback = URL(string: "https://api.boulderme.app")!
        let apiBaseURL = (info["BMAPIBaseURL"] as? String).flatMap(URL.init(string:)) ?? fallback
        var config = AppConfig(
            environment: environment,
            apiBaseURL: apiBaseURL,
            version: info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0",
            startInDemo: arguments.bool(forKey: "BMDemo"))
        func url(_ key: String) -> URL? { (info[key] as? String).flatMap(URL.init(string:)) }
        if let value = url("BMPrivacyURL") { config.privacyURL = value }
        if let value = url("BMTermsURL") { config.termsURL = value }
        if let value = url("BMSupportURL") { config.supportURL = value }
        return config
    }

    static let preview = AppConfig(
        environment: .debug, apiBaseURL: URL(string: "http://localhost:8787")!,
        version: "0.1.0", build: "1", startInDemo: true)
}
