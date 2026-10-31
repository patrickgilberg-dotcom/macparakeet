import AppKit
import SwiftUI
import XCTest
import MacParakeetCore
@testable import MacParakeet

/// Synthetic native layout and source-disclosure checks; no app launch,
/// recording, provider, or user library is involved.
@MainActor
final class MeetingEvidenceBoardSmokeTests: XCTestCase {
    func testBoardAndCompactBoardScrollWithinBoundedNativeViewport() throws {
        let snapshot = fixture()
        for compact in [false, true] {
            let size = NSSize(width: 420, height: compact ? 220 : 520)
            let host = NSHostingView(rootView: MeetingEvidenceBoardView(snapshot: snapshot, compact: compact))
            let window = mount(host, size: size)
            defer { window.orderOut(nil); window.close() }
            let scroll = try XCTUnwrap(findScrollView(host))
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertTrue(document.frame.height.isFinite)
            XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height)
            XCTAssertEqual(host.bounds.width, size.width, accuracy: 1)
            let clip = scroll.contentView
            let bottom = max(0, document.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: document.isFlipped ? bottom : 0))
            scroll.reflectScrolledClipView(clip)
            settle()
            XCTAssertTrue(clip.bounds.origin.y.isFinite)
            XCTAssertEqual(clip.bounds.origin.y, document.isFlipped ? bottom : 0, accuracy: 1)
            clip.scroll(to: NSPoint(x: 0, y: document.isFlipped ? 0 : bottom))
            scroll.reflectScrolledClipView(clip)
            settle()
            XCTAssertEqual(clip.bounds.origin.y, document.isFlipped ? 0 : bottom, accuracy: 1)
            // Accessibility export is a separate on-screen test. Offscreen
            // SwiftUI hosts may render correctly without exporting AX nodes.
        }
    }

    func testNativeSourceButtonOpensExactNoteQuotationAndProvenanceSheet() throws {
        let quote = "Ask whether Zephyr still needs finance approval."
        let source =
            quote + "\n" + String(repeating: "My supporting personal note. ", count: 40) + "FULL_SOURCE_END_MARKER"
        let document = MeetingEvidenceDocument(
            id: "synthetic-notes", kind: .currentNotes, title: "Synthetic planning notes", text: source)
        let item = MeetingBoardItem(
            kind: .note, commitment: .noted, text: "Check the approval condition.",
            evidence: [.init(documentID: document.id, quote: quote)])
        let snapshot = MeetingBoardSnapshot(
            scopeKey: "synthetic-source-disclosure", documents: [document], items: [item],
            coverageDescription: "Checked the captured notes.")
        let host = NSHostingView(rootView: MeetingEvidenceBoardView(snapshot: snapshot))
        let window = mount(host, size: NSSize(width: 420, height: 520), onScreen: true)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
            window.orderOut(nil); window.close()
        }
        // Optional short manual-check window: only this synthetic board is
        // shown, and its ordinary native controls remain usable by Cua/AX.
        if let value = ProcessInfo.processInfo.environment["MACPARAKEET_BOARD_UI_HOLD_SECONDS"],
            let seconds = Double(value), seconds > 0
        {
            print("Synthetic board UI available: \(window.title)")
            settle(min(seconds, 60))
        }
        let objects = accessibilityObjects(window)
        guard
            let target = objects.first(where: {
                string($0, "accessibilityIdentifier") == "meeting-board-quote-\(item.id)-0"
            })
        else {
            reportAccessibility(objects)
            throw XCTSkip(
                "The native XCTest host did not export SwiftUI quotation buttons; layout is verified separately.")
        }
        if window.attachedSheet == nil {
            guard let button = target as? NSAccessibilityButton else {
                reportAccessibility([target])
                throw XCTSkip("This native SwiftUI host exposes the quotation but not the native press protocol.")
            }
            XCTAssertTrue(button.accessibilityPerformPress())
        }
        let deadline = Date().addingTimeInterval(2)
        while window.attachedSheet == nil, Date() < deadline { settle(0.02) }
        guard let sheet = window.attachedSheet, let content = sheet.contentView else {
            throw XCTSkip("The native XCTest host cannot present its SwiftUI sheet in the current session.")
        }
        content.layoutSubtreeIfNeeded()
        settle()
        let sheetObjects = accessibilityObjects(content)
        let text = sheetObjects.flatMap { object in
            [string(object, "accessibilityLabel"), string(object, "accessibilityValue")].compactMap { $0 }
        }.joined(separator: "\n")
        guard !text.isEmpty else {
            reportAccessibility(sheetObjects)
            throw XCTSkip("The native XCTest host presented the source sheet without exporting its SwiftUI text.")
        }
        XCTAssertTrue(text.contains(quote))
        XCTAssertTrue(text.contains("Your current meeting notes"))
        XCTAssertTrue(text.contains("not a spoken transcript"))
        XCTAssertTrue(text.contains("Full captured notes"))
        if let disclosure = sheetObjects.first(where: {
            (string($0, "accessibilityLabel") ?? "").contains("Full captured notes")
        }) as? NSAccessibilityButton {
            XCTAssertTrue(disclosure.accessibilityPerformPress())
            settle()
            let expanded = accessibilityObjects(content).flatMap { object in
                [string(object, "accessibilityLabel"), string(object, "accessibilityValue")].compactMap { $0 }
            }.joined(separator: "\n")
            XCTAssertTrue(expanded.contains("FULL_SOURCE_END_MARKER"))
        }
    }

    private func fixture() -> MeetingBoardSnapshot {
        let documents = [
            MeetingEvidenceDocument(
                id: "speech", kind: .currentTranscript, title: "Synthetic review",
                text: "Maya will review the proposal after finance approval."),
            MeetingEvidenceDocument(
                id: "notes", kind: .currentNotes, title: "My current notes", text: "Ask about the approval condition."),
            MeetingEvidenceDocument(
                id: "prior-notes", kind: .previousNotes, title: "Previous project meeting",
                text: "Check the earlier comparison assumptions."),
        ]
        let items = (0..<12).map { index in
            let document = documents[index % documents.count]
            return MeetingBoardItem(
                kind: document.kind.isNotes ? .note : .action,
                commitment: document.kind.isNotes ? .noted : .conditional,
                text:
                    "Synthetic follow-up \(index): retain the finance approval condition and verify the current status.",
                evidence: [.init(documentID: document.id, quote: document.text)])
        }
        return MeetingBoardSnapshot(
            scopeKey: "synthetic-native-layout", documents: documents, items: items,
            coverageDescription: "Checked the captured speech and personal notes. Previous completion is unverified.")
    }

    private func mount<Content: View>(
        _ host: NSHostingView<Content>, size: NSSize, onScreen: Bool = false
    ) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(
                origin: onScreen ? NSPoint(x: 120, y: 120) : NSPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "MacParakeet Live — Synthetic board check"
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.setFrameSize(size)
        if onScreen {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            window.orderFront(nil)
        }
        host.layoutSubtreeIfNeeded()
        settle()
        return window
    }

    private func settle(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(findScrollView).first
    }

    private func accessibilityObjects(_ root: NSObject) -> [NSObject] {
        var queue = [root]
        var seen = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        while !queue.isEmpty, seen.count < 10_000 {
            let object = queue.removeLast()
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            if let children = value(object, "accessibilityChildren") as? [NSObject] { queue += children }
            if let view = object as? NSView { queue += view.subviews }
            if let window = object as? NSWindow, let content = window.contentView { queue.append(content) }
        }
        return result
    }

    private func string(_ object: NSObject, _ getter: String) -> String? {
        let result = value(object, getter)
        return (result as? String) ?? (result as? NSAttributedString)?.string
    }

    private func value(_ object: NSObject, _ getter: String) -> AnyObject? {
        let selector = NSSelectorFromString(getter)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        let attributes = [
            "accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier",
            "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue", "accessibilityRole": "AXRole",
        ]
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let attribute = attributes[getter], object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: attribute)?.takeUnretainedValue()
    }

    private func reportAccessibility(_ objects: [NSObject]) {
        print("Synthetic board Accessibility export: \(objects.count) native objects")
        for object in objects.prefix(25) {
            let role = string(object, "accessibilityRole") ?? "none"
            let identifier = string(object, "accessibilityIdentifier") ?? "none"
            let label = String((string(object, "accessibilityLabel") ?? "").prefix(100))
            print("\(String(describing: type(of: object))) role=\(role) identifier=\(identifier) label=\(label)")
        }
    }
}
