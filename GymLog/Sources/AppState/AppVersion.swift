import Foundation

/// The running build's marketing version and build number, read from the
/// app bundle.
///
/// Exists so "did the update actually install?" is answerable from inside
/// the app. TestFlight installs silently replace the binary, and with no
/// version shown anywhere there was no way to tell a fixed build from the
/// one before it -- which matters here because the InBody scanner's
/// behaviour has changed between builds, and "it still doesn't work" and
/// "the update hasn't landed yet" look identical from the outside.
///
/// Reads `Bundle.main`, NOT the framework's own bundle: `CFBundleVersion`
/// exists in both, and the framework's copy is not what TestFlight shows.
public enum AppVersion {
    public static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    /// e.g. `1.0 (5)`.
    public static var displayString: String {
        "\(marketing) (\(build))"
    }
}
