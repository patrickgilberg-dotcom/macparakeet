import Foundation

/// Identity of this personal fork. Keep it independent of the enclosing bundle:
/// the bundled CLI and SwiftPM tools must never fall back to upstream storage.
public enum LiveAppIdentity {
    public static let isLive = true
    public static let displayName = "MacParakeet Live"
    public static let bundleIdentifier = "com.patrickgilberg.macparakeet-live"
    public static let preferencesSuiteName = bundleIdentifier
    public static let applicationSupportFolder = "MacParakeet-Live"
    public static let meetingURLScheme = "macparakeet-live"
    public static let upstreamUpdatesEnabled = false

    public static func keychainService(_ component: String) -> String {
        "\(bundleIdentifier).\(component)"
    }
}
