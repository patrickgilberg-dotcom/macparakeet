import AppKit
import MacParakeetViewModels
import QuartzCore
import XCTest
@testable import MacParakeet

/// Opt-in inspection of the production floating flower only. No recording
/// service, calendar, account, repository, microphone or audio file is used.
@MainActor
final class MeetingRecordingPillStartupTests: XCTestCase {
    func testNativeFloatingFlowerStartupAndBackToBackGeometryWithoutCapture() async throws {
        guard let raw = ProcessInfo.processInfo.environment["MACPARAKEET_PILL_STARTUP_HOLD_SECONDS"],
            let requested = Double(raw), requested > 0
        else {
            throw XCTSkip("Opt-in floating-flower check requires the private interactive XCTest host.")
        }
        let duration = min(60, max(40, requested))
        let application = NSApplication.shared
        let originalPolicy = application.activationPolicy()
        application.setActivationPolicy(.regular)
        application.finishLaunching()

        let model = MeetingRecordingPillViewModel()
        let controller = MeetingRecordingPillController(viewModel: model)
        var tapCount = 0
        var completionCount = 0
        controller.onClick = { tapCount += 1 }
        controller.onStopRecording = {}
        controller.onOpenApp = {}
        controller.onCancelRecording = {}
        controller.onPauseToggle = {}
        model.onCompletionAnimationFinished = { completionCount += 1 }
        defer {
            controller.hide()
            application.setActivationPolicy(originalPolicy)
        }

        let phases: [(String, Double, MeetingRecordingPillViewModel.PillState)] = [
            ("fresh-starting", 0, .starting),
            ("first-recording", 0.15, .recording),
            ("preserved-reshow-starting", 0.35, .starting),
            ("second-recording", 0.47, .recording),
            ("completion-interruption", 0.61, .completing),
            ("back-to-back-starting", 0.62, .starting),
            ("back-to-back-recording", 0.76, .recording),
            ("direct-recording-baseline", 0.88, .recording),
        ]
        let started = ContinuousClock.now
        var phaseIndex = -1
        var phaseStarted = started
        var initialWindowFrame: NSRect?
        var samples: [[String: Any]] = []
        var maximumDelta: [String: Double] = [:]
        var maximumIconPositionDelta: [String: Double] = [:]
        var presentedSampleCounts: [String: Int] = [:]
        var lastSampleAt = -Double.infinity

        while true {
            try Task.checkCancellation()
            let elapsed = milliseconds(started.duration(to: .now)) / 1_000
            if elapsed >= duration { break }
            let nextPhase = phases.lastIndex { elapsed >= $0.1 * duration } ?? 0
            if nextPhase != phaseIndex {
                phaseIndex = nextPhase
                phaseStarted = .now
                model.state = phases[nextPhase].2
                model.elapsedSeconds = 0
                switch nextPhase {
                case 0:
                    controller.show()
                case 2:
                    controller.hide(preserveFrameForNextShow: true)
                    controller.show()
                case 5:
                    // Exercise reuse while the previous explicit completion
                    // animation is still in flight, without calling capture.
                    controller.show()
                case 7:
                    // A fresh view entering directly in recording state is
                    // the control for the quiet starting-state transition.
                    controller.hide()
                    controller.show()
                default:
                    controller.refreshState()
                }
                let panel = try pillPanel()
                panel.title = "Synthetic floating flower — " + phases[nextPhase].0
                application.activate(ignoringOtherApps: true)
                if initialWindowFrame == nil { initialWindowFrame = panel.frame }
                samples.append(try geometrySample(phase: phases[nextPhase].0, elapsed: elapsed, immediate: true))
                print("PILL_STARTUP_PHASE \(phases[nextPhase].0)")
            }

            if application.isRunning {
                try await Task.sleep(for: .milliseconds(100))
            } else {
                runNativePreviewSlice(seconds: 0.08)
                try await Task.sleep(for: .milliseconds(20))
            }
            let phase = phases[phaseIndex].0
            let nowElapsed = milliseconds(started.duration(to: .now)) / 1_000
            let age = milliseconds(phaseStarted.duration(to: .now)) / 1_000
            model.elapsedSeconds = phases[phaseIndex].2 == .recording ? max(1, Int(age)) : 0
            if phases[phaseIndex].2 == .recording {
                controller.updateLiveAudioLevel(Float(0.2 + 0.15 * sin(age * 2)))
            }
            let panel = try pillPanel()
            XCTAssertEqual(panel.frame.size.width, 118, accuracy: 0.5)
            XCTAssertEqual(panel.frame.size.height, 150, accuracy: 0.5)
            if let initialWindowFrame {
                XCTAssertEqual(panel.frame.origin.x, initialWindowFrame.origin.x, accuracy: 0.5)
                XCTAssertEqual(panel.frame.origin.y, initialWindowFrame.origin.y, accuracy: 0.5)
            }
            XCTAssertEqual(visiblePillPanels.count, 1, "Re-show must not leave duplicate floating flowers.")
            let sample = try geometrySample(phase: phase, elapsed: nowElapsed, immediate: false)
            if age < 0.7 || nowElapsed - lastSampleAt >= 0.4 {
                samples.append(sample)
                lastSampleAt = nowElapsed
            }
            if phase != "completion-interruption", let delta = sample["backgroundPresentationDelta"] as? Double {
                maximumDelta[phase] = max(maximumDelta[phase] ?? 0, delta)
                presentedSampleCounts[phase, default: 0] += 1
            }
            if phase != "completion-interruption", let delta = sample["iconPresentationPositionDelta"] as? Double {
                maximumIconPositionDelta[phase] = max(maximumIconPositionDelta[phase] ?? 0, delta)
            }
        }

        let report: [String: Any] = [
            "syntheticOnly": true, "captureServiceCreated": false,
            "durationSeconds": duration, "tapCallbacks": tapCount, "completionCallbacks": completionCount,
            "maximumBackgroundPresentationDelta": maximumDelta,
            "maximumIconPresentationPositionDelta": maximumIconPositionDelta,
            "presentationSampleCounts": presentedSampleCounts, "samples": samples,
        ]
        if let path = ProcessInfo.processInfo.environment["MACPARAKEET_PILL_STARTUP_REPORT_PATH"] {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("PILL_STARTUP_GEOMETRY_MAXIMUM_DELTA \(maximumDelta)")
        for (phase, delta) in maximumDelta {
            XCTAssertLessThanOrEqual(delta, 1, "Unexpected implicit background geometry animation in \(phase).")
        }
        for (phase, delta) in maximumIconPositionDelta {
            XCTAssertLessThanOrEqual(delta, 1, "Unexpected implicit flower position animation in \(phase).")
        }
        XCTAssertTrue(controller.isVisible)
        controller.hide()
        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(visiblePillPanels.isEmpty)
    }

    private var visiblePillPanels: [NSWindow] {
        NSApplication.shared.windows.filter { window in
            window.isVisible && window.contentView?.subviews.contains { $0 is MeetingRecordingAppKitPillView } == true
        }
    }

    private func pillPanel() throws -> NSWindow {
        try XCTUnwrap(visiblePillPanels.first, "The real floating-pill controller must show one native panel.")
    }

    private func geometrySample(phase: String, elapsed: Double, immediate: Bool) throws -> [String: Any] {
        let panel = try pillPanel()
        let pill = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? MeetingRecordingAppKitPillView }.first)
        let icon = try XCTUnwrap(pill.subviews.compactMap { $0 as? MerkabaPillIconView }.first)
        let background = try XCTUnwrap(pill.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        let modelPath = background.path?.boundingBoxOfPath
        let presentedPath = background.presentation()?.path?.boundingBoxOfPath
        let iconLayers = (icon.layer?.sublayers ?? []).enumerated().map { index, layer -> [String: Any] in
            var sample: [String: Any] = [
                "index": index, "hidden": layer.isHidden, "opacity": layer.opacity,
                "frame": rectangle(layer.frame), "animationKeys": layer.animationKeys() ?? [],
                "position": ["x": Double(layer.position.x), "y": Double(layer.position.y)],
            ]
            if let presented = layer.presentation() {
                sample["presentationPosition"] = ["x": Double(presented.position.x), "y": Double(presented.position.y)]
            }
            return sample
        }
        var result: [String: Any] = [
            "phase": phase, "elapsedSeconds": elapsed, "immediateAfterShowOrRefresh": immediate,
            "windowFrame": rectangle(panel.frame), "pillBounds": rectangle(pill.bounds),
            "iconFrame": rectangle(icon.frame), "iconAlpha": icon.alphaValue,
            "backgroundModelPath": modelPath.map(rectangle) ?? [:],
            "backgroundPresentationPath": presentedPath.map(rectangle) ?? [:],
            "backgroundAnimationKeys": background.animationKeys() ?? [],
            "iconLayerAnimationKeys": icon.layer?.animationKeys() ?? [],
            "rosetteCompletionAnimationKeys": icon.testHook_rosetteCompletionAnimationKeys,
            "hasRecordingRotationAnimation": icon.testHook_hasRecordingRotationAnimation,
            "iconLayers": iconLayers,
            "pillLayerTree": pill.layer.map { layerSample($0, depth: 3) } ?? [:],
            "visibleAppWindows": visibleApplicationWindows(),
        ]
        if let modelPath, let presentedPath, !presentedPath.isEmpty {
            result["backgroundPresentationDelta"] =
                [
                    abs(modelPath.minX - presentedPath.minX), abs(modelPath.minY - presentedPath.minY),
                    abs(modelPath.width - presentedPath.width), abs(modelPath.height - presentedPath.height),
                ].map { Double($0) }.max() ?? 0
        }
        let positionDeltas = (icon.layer?.sublayers ?? []).compactMap { layer -> Double? in
            guard !layer.isHidden, layer.opacity > 0.01, let presented = layer.presentation() else { return nil }
            return Double(
                max(abs(layer.position.x - presented.position.x), abs(layer.position.y - presented.position.y)))
        }
        result["iconPresentationPositionDelta"] = positionDeltas.max()
        return result
    }

    private func layerSample(_ layer: CALayer, depth: Int) -> [String: Any] {
        var sample: [String: Any] = [
            "type": String(describing: type(of: layer)), "frame": rectangle(layer.frame),
            "bounds": rectangle(layer.bounds),
            "position": ["x": Double(layer.position.x), "y": Double(layer.position.y)],
            "opacity": layer.opacity, "hidden": layer.isHidden,
            "animationKeys": layer.animationKeys() ?? [], "masksToBounds": layer.masksToBounds,
            "backgroundColor": layer.backgroundColor?.components?.map { Double($0) } ?? [],
            "contentsType": layer.contents.map { String(describing: type(of: $0)) } ?? "nil",
        ]
        if let shape = layer as? CAShapeLayer {
            sample["fillColor"] = shape.fillColor?.components?.map { Double($0) } ?? []
            sample["strokeColor"] = shape.strokeColor?.components?.map { Double($0) } ?? []
            if let path = shape.path, !path.boundingBoxOfPath.isNull {
                sample["pathBounds"] = rectangle(path.boundingBoxOfPath)
            }
        }
        if let presented = layer.presentation() {
            sample["presentationFrame"] = rectangle(presented.frame)
            sample["presentationOpacity"] = presented.opacity
            sample["presentationPosition"] = ["x": Double(presented.position.x), "y": Double(presented.position.y)]
        }
        if depth > 0 { sample["sublayers"] = (layer.sublayers ?? []).map { layerSample($0, depth: depth - 1) } }
        return sample
    }

    /// Window-server metadata only: owner, bounds, alpha and stacking layer.
    /// No window titles, screen pixels or unrelated application's records are
    /// retained. This distinguishes a second app's overlaid compact pill from
    /// a second layer in this controller's single native window.
    private func visibleApplicationWindows() -> [[String: Any]] {
        let windows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.compactMap { window in
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let pid = window[kCGWindowOwnerPID as String] as? Int ?? 0
            guard
                owner.localizedCaseInsensitiveContains("MacParakeet")
                    || pid == Int(ProcessInfo.processInfo.processIdentifier)
            else { return nil }
            return [
                "owner": owner, "pid": pid,
                "bounds": window[kCGWindowBounds as String] as? [String: Any] ?? [:],
                "alpha": window[kCGWindowAlpha as String] as? Double ?? 0,
                "stackingLayer": window[kCGWindowLayer as String] as? Int ?? 0,
                "windowNumber": window[kCGWindowNumber as String] as? Int ?? 0,
            ]
        }
    }

    private func rectangle(_ value: CGRect) -> [String: Double] {
        [
            "x": Double(value.minX), "y": Double(value.minY), "width": Double(value.width),
            "height": Double(value.height),
        ]
    }

    private func milliseconds(_ value: Duration) -> Double {
        let components = value.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
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
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        application.run()
    }
}
