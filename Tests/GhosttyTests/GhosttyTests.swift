import Foundation
import XCTest
@testable import Ghostty

/// Tests for the Ghostty SwiftPM package wrapper.
///
/// These tests will FAIL on `main` because `Vendor/GhosttyKit.xcframework/`
/// and `Sources/Ghostty/Resources/` are empty placeholders on main. They
/// pass only against tagged release commits where those directories are
/// populated. This is intentional — see `docs/known-quirks.md`.
final class GhosttyTests: XCTestCase {

    /// `resourcesRootURL` resolves to a real directory inside Bundle.module.
    func testResourcesRootURLResolves() throws {
        let url = Ghostty.resourcesRootURL
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
            "resourcesRootURL does not exist at \(url.path)"
        )
        XCTAssertTrue(isDir.boolValue, "resourcesRootURL is not a directory: \(url.path)")
    }

    /// The bundled xterm-ghostty terminfo entry exists where libghostty expects.
    /// Hashed under bucket "78" because ncurses hashes by first character: 'x' → 0x78.
    func testTerminfoXtermGhosttyEntryExists() throws {
        let entry = Ghostty.terminfoURL
            .appendingPathComponent("78")
            .appendingPathComponent("xterm-ghostty")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: entry.path),
            "xterm-ghostty terminfo entry missing at \(entry.path)"
        )
    }

    /// The zsh shell-integration script exists.
    func testShellIntegrationZshExists() throws {
        let script = Ghostty.shellIntegrationURL
            .appendingPathComponent("zsh")
            .appendingPathComponent("ghostty-integration")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: script.path),
            "zsh ghostty-integration script missing at \(script.path)"
        )
    }

    /// `bootstrap()` sets GHOSTTY_RESOURCES_DIR to the bundled ghostty/ path.
    func testBootstrapSetsResourcesEnvVar() throws {
        unsetenv("GHOSTTY_RESOURCES_DIR")
        Ghostty.bootstrap()
        guard let raw = getenv("GHOSTTY_RESOURCES_DIR") else {
            XCTFail("GHOSTTY_RESOURCES_DIR was not set by bootstrap()")
            return
        }
        let value = String(cString: raw)
        XCTAssertTrue(
            value.hasSuffix("/Resources/ghostty"),
            "Expected env to end with /Resources/ghostty, got: \(value)"
        )
        XCTAssertEqual(value, Ghostty.ghosttyResourcesPath)
    }

    /// End-to-end smoke test: spawn zsh with TERMINFO_DIRS pointing at the
    /// bundled terminfo, set TERM=xterm-ghostty, and `tput colors` should
    /// return 256. This proves the bundled terminfo is functional and the
    /// hash bucket layout is correct.
    func testShellTputColorsAgainstBundledTerminfo() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "TERM=xterm-ghostty tput colors"]
        var env = ProcessInfo.processInfo.environment
        env["TERMINFO_DIRS"] = Ghostty.terminfoURL.path
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertEqual(
            output, "256",
            "tput colors against bundled xterm-ghostty terminfo expected 256, got: \(output)"
        )
    }

    /// Symbol-resolution smoke test: `ghostty_info()` from the linked
    /// libghostty C API returns sensible build info. Proves the binary
    /// target loaded correctly and symbols are reachable.
    func testGhosttyInfoSymbolReachable() throws {
        let info = ghostty_info()
        XCTAssertNotEqual(
            info.build_mode.rawValue, UInt32.max,
            "ghostty_info() returned an absurd build_mode; symbol may not be wired correctly"
        )
        XCTAssertNotNil(info.version, "ghostty_info().version is null")
        let version = String(cString: info.version)
        XCTAssertFalse(version.isEmpty, "ghostty_info().version is an empty string")
    }
}
