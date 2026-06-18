import Foundation
@_exported import GhosttyKit

/// Entry point for the Ghostty Swift package. Provides one bootstrap call
/// and accessors for the bundled resource paths.
///
/// Usage from a consumer app:
///
///     import Ghostty
///
///     /// In AppDelegate.applicationDidFinishLaunching, BEFORE any libghostty call:
///     Ghostty.bootstrap()
///
///     /// Then use libghostty as normal:
///     ghostty_init(0, nil)
///     let cfg = ghostty_config_new()
///     /// ... wire callbacks per the consumer's NSView wrapper ...
///
/// The package is plumbing only: it does not provide an NSView, an
/// NSViewRepresentable, a SwiftUI surface, or any opinionated runtime API
/// beyond resource locating. That layer belongs to the consumer.
public enum Ghostty {

    /// Configures libghostty's resource discovery for this process.
    ///
    /// Sets `GHOSTTY_RESOURCES_DIR` to the package's bundled `ghostty/`
    /// directory. libghostty derives shell-integration, themes, and
    /// terminfo lookup from this single path.
    ///
    /// Idempotent. Safe to call multiple times. Must be called before
    /// `ghostty_init()` so spawned shells inherit the right environment.
    public static func bootstrap() {
        setenv("GHOSTTY_RESOURCES_DIR", ghosttyResourcesPath, 1)
    }

    /// URL for the bundled resource root. Contains `ghostty/` and
    /// `terminfo/` as siblings.
    public static var resourcesRootURL: URL {
        guard let url = Bundle.module.resourceURL?.appendingPathComponent("Resources") else {
            fatalError("Ghostty package missing Resources directory; this is a packaging bug.")
        }
        return url
    }

    /// Path to the bundled `ghostty/` directory. This is what libghostty
    /// expects in `GHOSTTY_RESOURCES_DIR` and what `bootstrap()` sets.
    public static var ghosttyResourcesPath: String {
        resourcesRootURL.appendingPathComponent("ghostty").path
    }

    /// URL for the bundled `terminfo` directory. Provided for diagnostics
    /// and for consumers that need to inject `TERMINFO_DIRS` into spawned
    /// processes outside libghostty's control.
    public static var terminfoURL: URL {
        resourcesRootURL.appendingPathComponent("terminfo")
    }

    /// URL for the bundled shell-integration scripts. Mostly diagnostic.
    public static var shellIntegrationURL: URL {
        resourcesRootURL.appendingPathComponent("ghostty/shell-integration")
    }

    /// URL for the bundled themes. Mostly diagnostic.
    public static var themesURL: URL {
        resourcesRootURL.appendingPathComponent("ghostty/themes")
    }
}
