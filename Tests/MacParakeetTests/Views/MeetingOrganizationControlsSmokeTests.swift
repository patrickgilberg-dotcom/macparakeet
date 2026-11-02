import AppKit
import MacParakeetCore
import MacParakeetViewModels
import SwiftUI
import XCTest
@testable import MacParakeet

/// Production company/project controls with in-memory data only. These checks
/// never launch capture, read the user's library or contact an AI provider.
@MainActor
final class MeetingOrganizationControlsSmokeTests: XCTestCase {
    func testOrganizationControlsFitCompactNativeViewports() async throws {
        for longNames in [false, true] {
            let fixture = try await fixture(longNames: longNames)
            for width in [360.0, 420.0] {
                let host = NSHostingView(
                    rootView: LiveMeetingOrganizationControls(viewModel: fixture.viewModel).frame(width: width))
                let window = mount(host, width: width, onScreen: false)
                defer { window.orderOut(nil); window.close() }
                XCTAssertEqual(host.bounds.width, width, accuracy: 1)
                XCTAssertTrue(host.fittingSize.height.isFinite)
                XCTAssertGreaterThan(host.fittingSize.height, 0)
                XCTAssertLessThan(host.fittingSize.height, 220)
            }
        }
    }

    func testNativeCompanyProjectSelectionAndCreationWithoutRecording() async throws {
        guard let value = ProcessInfo.processInfo.environment["MACPARAKEET_ORGANIZATION_UI_HOLD_SECONDS"],
            let seconds = Double(value), seconds > 0
        else {
            throw XCTSkip("Opt-in native company/project acceptance requires the private interactive XCTest host.")
        }
        let fixture = try await fixture()
        let host = NSHostingView(
            rootView: LiveMeetingOrganizationControls(viewModel: fixture.viewModel).frame(width: 420))
        let originalPolicy = NSApplication.shared.activationPolicy()
        let window = mount(host, width: 420, onScreen: true)
        defer {
            window.orderOut(nil); window.close()
            NSApplication.shared.setActivationPolicy(originalPolicy)
        }
        try await holdNativePreview(seconds: min(seconds, 60))
        await fixture.viewModel.waitForPendingSave()
        XCTAssertNil(fixture.viewModel.errorMessage)
        XCTAssertEqual(fixture.viewModel.companyID, fixture.second.id)
        XCTAssertEqual(fixture.viewModel.projectID, fixture.secondProject.id)
        XCTAssertTrue(fixture.selections.values.contains { $0.0 == fixture.second.id && $0.1 == nil })
        XCTAssertEqual(fixture.selections.values.last?.0, fixture.second.id)
        XCTAssertEqual(fixture.selections.values.last?.1, fixture.secondProject.id)
        let created = try fixture.projects.fetchAll().first { $0.name == "Pilot follow-up" }
        XCTAssertEqual(created?.companyID, fixture.first.id)
        XCTAssertEqual(try fixture.projects.fetchAll().count, 3)
    }

    private final class Selections {
        var values: [(UUID?, UUID?)] = []
    }

    private struct Fixture {
        let manager: DatabaseManager
        let projects: MeetingProjectRepository
        let first: MeetingCompany
        let second: MeetingCompany
        let secondProject: MeetingProject
        let selections: Selections
        let viewModel: LiveMeetingOrganizationViewModel
    }

    private func fixture(longNames: Bool = false) async throws -> Fixture {
        let manager = try DatabaseManager()
        let companies = MeetingCompanyRepository(dbQueue: manager.dbQueue)
        let projects = MeetingProjectRepository(dbQueue: manager.dbQueue)
        let prefix = longNames ? String(repeating: "Long synthetic organization name ", count: 5) : "Synthetic "
        let first = MeetingCompany(name: prefix + "Cedar", attendeeDomains: ["cedar.example"])
        let second = MeetingCompany(name: prefix + "Zephyr", attendeeDomains: ["zephyr.example"])
        try companies.save(first); try companies.save(second)
        let projectPrefix = longNames ? String(repeating: "Long workstream name ", count: 8) : ""
        try projects.save(MeetingProject(name: projectPrefix + "Cedar review", companyID: first.id))
        let secondProject = MeetingProject(name: projectPrefix + "Zephyr renewal", companyID: second.id)
        try projects.save(secondProject)
        let selections = Selections()
        let viewModel = LiveMeetingOrganizationViewModel(
            companyRepository: companies, projectRepository: projects, companyID: first.id
        ) { companyID, projectID in
            selections.values.append((companyID, projectID))
        }
        await viewModel.load()
        return Fixture(
            manager: manager, projects: projects, first: first, second: second,
            secondProject: secondProject, selections: selections, viewModel: viewModel)
    }

    private func mount<Content: View>(
        _ host: NSHostingView<Content>, width: Double, onScreen: Bool
    ) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: onScreen ? 120 : -20_000, y: onScreen ? 120 : -20_000, width: width, height: 220),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "MacParakeet Live — Synthetic company/project check"
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.setFrameSize(NSSize(width: width, height: 220))
        if onScreen {
            NSApplication.shared.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            window.orderFront(nil)
        }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return window
    }

    private func holdNativePreview(seconds: TimeInterval) async throws {
        let application = NSApplication.shared
        if application.isRunning {
            try await Task.sleep(for: .seconds(seconds))
            return
        }
        application.finishLaunching()
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            runNativePreviewSlice(seconds: 0.08)
            // A continuous nested NSApp.run() prevents XCTest's MainActor
            // job from suspending. Yield between event-dispatch slices so
            // the production view model can finish its awaited repository
            // work and publish enabled controls normally.
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func runNativePreviewSlice(seconds: TimeInterval) {
        let application = NSApplication.shared
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                let application = NSApplication.shared
                application.stop(nil)
                if let event = NSEvent.otherEvent(
                    with: .applicationDefined, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                    subtype: 0, data1: 0, data2: 0)
                {
                    application.postEvent(event, atStart: true)
                }
            }
        }
        // Native pop-up menus track in their own mode. Do not stop AppKit
        // while that menu is open; resume the bounded slice and actor yield
        // after the user selects an item or dismisses the menu.
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        application.run()
    }
}
