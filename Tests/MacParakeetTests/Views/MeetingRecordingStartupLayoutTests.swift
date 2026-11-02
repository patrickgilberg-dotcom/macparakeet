import AppKit
import MacParakeetCore
import MacParakeetViewModels
import SwiftUI
import XCTest
@testable import MacParakeet

/// Exercises the production panel without capture, account access or user data.
@MainActor
final class MeetingRecordingStartupLayoutTests: XCTestCase {
    func testLoadingOrganizationKeepsNotesFlowerAndTabPaneBoundaryInPlace() async throws {
        let database = try DatabaseManager()
        let companies = MeetingCompanyRepository(dbQueue: database.dbQueue)
        let projects = MeetingProjectRepository(dbQueue: database.dbQueue)
        let company = MeetingCompany(name: "Synthetic Cedar company with a long name")
        try companies.save(company)
        let project = MeetingProject(name: "Synthetic review project with a long name", companyID: company.id)
        try projects.save(project)

        for width in [360.0, 420.0] {
            let panel = MeetingRecordingPanelViewModel()
            panel.state = .starting
            panel.showsOrganizationControls = true
            let host = NSHostingView(
                rootView: MeetingRecordingPanelView(viewModel: panel).frame(width: width, height: 460))
            let window = mount(host, width: width)
            defer { window.orderOut(nil); window.close() }
            let flower = try XCTUnwrap(firstView(BreathingSeedOfLifeNSView.self, in: host))
            let editor = try XCTUnwrap(firstView(NSTextView.self, in: host)?.enclosingScrollView)
            let flowerBefore = flower.convert(flower.bounds, to: host)
            let editorBefore = editor.convert(editor.bounds, to: host)
            let wasRotating = flower.testHook_hasRotationAnimation
            let wasBreathing = flower.testHook_hasBreathingAnimation
            let organization = LiveMeetingOrganizationViewModel(
                companyRepository: companies, projectRepository: projects,
                companyID: company.id, projectID: project.id, onSave: { _, _ in })
            await organization.load()

            panel.organization = organization
            settle(host)
            // Give the ordinary control .task a turn to reload its local rows.
            try await Task.sleep(for: .milliseconds(20))
            settle(host)
            assertUnchanged(
                flower: flower, editor: editor, host: host,
                flowerBefore: flowerBefore, editorBefore: editorBefore,
                wasRotating: wasRotating, wasBreathing: wasBreathing)

            panel.state = .recording
            settle(host)
            assertUnchanged(
                flower: flower, editor: editor, host: host,
                flowerBefore: flowerBefore, editorBefore: editorBefore,
                wasRotating: wasRotating, wasBreathing: wasBreathing)
        }
    }

    func testPanelResetClearsOrganizationSlotCapability() {
        let panel = MeetingRecordingPanelViewModel()
        panel.showsOrganizationControls = true
        panel.reset()
        XCTAssertFalse(panel.showsOrganizationControls)
        XCTAssertNil(panel.organization)
    }

    private func assertUnchanged<Content: View>(
        flower: BreathingSeedOfLifeNSView, editor: NSScrollView, host: NSHostingView<Content>,
        flowerBefore: NSRect, editorBefore: NSRect, wasRotating: Bool, wasBreathing: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(firstView(BreathingSeedOfLifeNSView.self, in: host) === flower, file: file, line: line)
        XCTAssertTrue(firstView(NSTextView.self, in: host)?.enclosingScrollView === editor, file: file, line: line)
        let flowerAfter = flower.convert(flower.bounds, to: host)
        let editorAfter = editor.convert(editor.bounds, to: host)
        assertEqualRect(flowerAfter, flowerBefore, file: file, line: line)
        // The Notes editor fills the pane immediately beneath the tabs. Its
        // unchanged origin and height verify that the tab/pane boundary stayed put.
        assertEqualRect(editorAfter, editorBefore, file: file, line: line)
        XCTAssertEqual(flower.testHook_hasRotationAnimation, wasRotating, file: file, line: line)
        XCTAssertEqual(flower.testHook_hasBreathingAnimation, wasBreathing, file: file, line: line)
    }

    private func assertEqualRect(
        _ actual: NSRect, _ expected: NSRect, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, file: file, line: line)
    }

    private func mount<Content: View>(_ host: NSHostingView<Content>, width: Double) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 460),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.setFrameSize(NSSize(width: width, height: 460))
        window.orderFront(nil)
        settle(host)
        return window
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
    }

    private func firstView<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        return root.subviews.lazy.compactMap { self.firstView(type, in: $0) }.first
    }
}
