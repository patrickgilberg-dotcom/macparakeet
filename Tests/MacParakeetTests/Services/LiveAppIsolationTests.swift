import Foundation
import XCTest
@testable import MacParakeetCore

final class LiveAppIsolationTests: XCTestCase {
    func testIdentityAndEveryCredentialNamespaceAreSeparateFromUpstream() {
        XCTAssertEqual(LiveAppIdentity.displayName, "MacParakeet Live")
        XCTAssertEqual(AppPaths.preferencesSuiteName, "com.patrickgilberg.macparakeet-live")
        XCTAssertNotEqual(AppPaths.preferencesSuiteName, "com.macparakeet.MacParakeet")
        for component in ["llm", "chatgpt", "sharing", "licensing", "voice-control.jev"] {
            XCTAssertEqual(LiveAppIdentity.keychainService(component), AppPaths.preferencesSuiteName + "." + component)
            XCTAssertFalse(LiveAppIdentity.keychainService(component).hasPrefix("com.macparakeet."))
        }
        XCTAssertFalse(LiveAppIdentity.upstreamUpdatesEnabled)
        XCTAssertEqual(LiveAppIdentity.meetingURLScheme, "macparakeet-live")
    }

    func testFinderLaunchUsesLiveStorageWithoutEnvironment() {
        let live = AppPaths.resolvedAppSupportDir(environment: [:], bundleIdentifier: LiveAppIdentity.bundleIdentifier)
        XCTAssertTrue(live.hasSuffix("/MacParakeet-Live"))
        XCTAssertNotEqual(
            live,
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MacParakeet").path)
        XCTAssertTrue(AppPaths.tempDir.hasSuffix("macparakeet-live"))
    }

    @MainActor
    func testDefaultExportsDoNotUseUpstreamDocumentsFolder() {
        for scope in [AutoSaveScope.transcription, .meeting] {
            let destination = AutoSaveService.defaultFolder(for: scope)
            XCTAssertEqual(destination.deletingLastPathComponent().lastPathComponent, "MacParakeet-Live")
        }
    }
}
