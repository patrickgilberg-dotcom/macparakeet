import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import MacParakeetCore

/// Opt-in storage stress using generated PCM, never native audio capture.
/// Two hours of encoded media are accelerated; this is not a wall-clock soak.
final class MeetingLongWriterDurabilityTests: XCTestCase {
    private static let enabledKey = "MACPARAKEET_LONG_WRITER_TESTS"
    private static let helperRootKey = "MACPARAKEET_LONG_WRITER_HELPER_ROOT"
    private static let seconds = 7_200
    private static let sampleRate = 48_000

    func testAcceleratedTwoHourFragmentsSurviveAbruptProcessExit() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.enabledKey] == "1",
            "Set MACPARAKEET_LONG_WRITER_TESTS=1 to run the accelerated two-hour storage test.")
        let ffmpegPath = try XCTUnwrap(ProcessInfo.processInfo.environment["MACPARAKEET_FFMPEG_PATH"])
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: ffmpegPath),
            "Set MACPARAKEET_FFMPEG_PATH to a supported local FFmpeg helper for full fragmented-media decoding.")
        let started = ContinuousClock.now
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingLongWriterDurability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("helper.log")
        try Data().write(to: logURL)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        helper.arguments = [
            "xctest", "-XCTest",
            "MacParakeetTests.MeetingLongWriterDurabilityTests/testAcceleratedWriterHelper",
            Bundle(for: Self.self).bundleURL.path,
        ]
        helper.environment = ProcessInfo.processInfo.environment.merging([
            Self.helperRootKey: root.path
        ]) { _, new in new }
        helper.standardOutput = log
        helper.standardError = log
        try helper.run()
        defer {
            if helper.isRunning {
                kill(helper.processIdentifier, SIGKILL)
            }
        }

        let source = root.appendingPathComponent("media/microphone-raw.m4a")
        try await waitForMarker("one-hour", root: root, helper: helper)
        XCTAssertEqual(try acceptedFrames("one-hour", root: root), Int64(Self.seconds / 2 * Self.sampleRate))
        print("long_writer_checkpoint stage=one_hour_written")
        // The generated producer is much faster than the AAC encoder. Accepted
        // PCM is not proof that its last fragments have reached the file yet.
        try await waitForDurableDuration(3_598, source: source)
        let checkpoint = root.appendingPathComponent("one-hour.m4a")
        try FileManager.default.copyItem(at: source, to: checkpoint)
        let checkpointDuration = try await AVURLAsset(url: checkpoint).load(.duration).seconds
        print("long_writer_checkpoint stage=one_hour_opened duration=\(checkpointDuration)")
        XCTAssertGreaterThanOrEqual(
            checkpointDuration, 3_598, "Earlier fragments must already be independently readable")
        let checkpointDecoded = try await fullDecode(
            source: checkpoint, root: root, ffmpegPath: ffmpegPath, label: "one-hour")
        XCTAssertGreaterThanOrEqual(checkpointDecoded, 3_598)
        try Data().write(to: root.appendingPathComponent("continue"))
        try await waitForMarker("two-hours", root: root, helper: helper)
        XCTAssertEqual(try acceptedFrames("two-hours", root: root), Int64(Self.seconds * Self.sampleRate))
        print("long_writer_checkpoint stage=two_hours_written")
        try await waitForDurableDuration(Double(Self.seconds - 2), source: source)
        XCTAssertEqual(kill(helper.processIdentifier, SIGKILL), 0)
        let exitDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while helper.isRunning {
            guard ContinuousClock.now < exitDeadline else { throw FixtureError.deadline }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(helper.terminationReason, .uncaughtSignal)
        XCTAssertEqual(helper.terminationStatus, SIGKILL)
        print("long_writer_checkpoint stage=writer_killed")

        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber
        ).int64Value
        XCTAssertGreaterThan(size, 0)
        XCTAssertLessThan(size, 100 * 1_024 * 1_024, "Keep this opt-in fixture's disk footprint bounded")
        // AVAudioFile's PCM reader may reject an intentionally unfinished M4A
        // at EOF. Recovery uses FFmpeg, so verify every retained fragment with
        // that same decoder, to a null sink, without materializing a huge WAV.
        let decodedSeconds = try await fullDecode(
            source: source, root: root, ffmpegPath: ffmpegPath, label: "two-hours")
        XCTAssertGreaterThanOrEqual(decodedSeconds, Double(Self.seconds - 2))
        XCTAssertLessThanOrEqual(decodedSeconds, Double(Self.seconds + 1))
        XCTAssertLessThan(started.duration(to: .now), .seconds(180))
        print(
            "long_writer_durability simulated_seconds=\(Self.seconds) decoded_seconds=\(decodedSeconds) bytes=\(size) wall=\(started.duration(to: .now))"
        )
    }

    func testAcceleratedWriterHelper() async throws {
        guard let path = ProcessInfo.processInfo.environment[Self.helperRootKey] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let writer = try MeetingAudioStorageWriter(folderURL: root.appendingPathComponent("media", isDirectory: true))
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.sampleRate), channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.sampleRate)))
        buffer.frameLength = AVAudioFrameCount(Self.sampleRate)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Self.sampleRate {
            samples[frame] = Float(sin(2 * Double.pi * 220 * Double(frame) / Double(Self.sampleRate))) * 0.1
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(150))
        for second in 0..<Self.seconds {
            while true {
                guard ContinuousClock.now < deadline else { throw FixtureError.deadline }
                do {
                    try writer.write(buffer, source: .microphone)
                    break
                } catch MeetingAudioError.storageFailed(let reason) where reason == "audio writer backpressure" {
                    // A generated producer outruns real-time capture. Throttle
                    // before retrying the same unaccepted buffer; no frames drop.
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            if second + 1 == Self.seconds / 2 {
                try writeFrameMarker(
                    "one-hour", expected: Int64(Self.seconds / 2 * Self.sampleRate), writer: writer, root: root)
                while !FileManager.default.fileExists(atPath: root.appendingPathComponent("continue").path) {
                    guard ContinuousClock.now < deadline else { throw FixtureError.deadline }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        }
        try writeFrameMarker("two-hours", expected: Int64(Self.seconds * Self.sampleRate), writer: writer, root: root)
        // Keep writer ownership live. The parent must kill this child instead
        // of giving AVAssetWriter a clean finishWriting or deinitialization.
        while true { try await Task.sleep(for: .seconds(1)) }
    }

    private func waitForMarker(_ name: String, root: URL, helper: Process) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(155))
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            guard helper.isRunning, ContinuousClock.now < deadline else {
                let details =
                    (try? String(contentsOf: root.appendingPathComponent("helper.log"), encoding: .utf8)) ?? ""
                XCTFail("Accelerated writer did not reach \(name): \(details.suffix(2_000))")
                throw FixtureError.deadline
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func waitForDurableDuration(_ minimum: Double, source: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let duration = try? await AVURLAsset(url: source).load(.duration).seconds, duration >= minimum {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw FixtureError.fragmentsNotFlushed
    }

    private func acceptedFrames(_ marker: String, root: URL) throws -> Int64 {
        try XCTUnwrap(Int64(String(contentsOf: root.appendingPathComponent(marker), encoding: .utf8)))
    }

    private func writeFrameMarker(
        _ marker: String, expected: Int64, writer: MeetingAudioStorageWriter, root: URL
    ) throws {
        let frames = writer.metrics(for: .microphone).writtenFrameCount
        guard frames == expected else { throw FixtureError.frameCountMismatch }
        try Data(String(frames).utf8).write(to: root.appendingPathComponent(marker), options: .atomic)
    }

    private func fullDecode(source: URL, root: URL, ffmpegPath: String, label: String) async throws -> Double {
        let progressURL = root.appendingPathComponent("\(label)-decode-progress.txt")
        let diagnosticURL = root.appendingPathComponent("\(label)-decode-diagnostics.txt")
        try Data().write(to: diagnosticURL)
        let diagnostics = try FileHandle(forWritingTo: diagnosticURL)
        defer { try? diagnostics.close() }
        let decoder = Process()
        decoder.executableURL = URL(fileURLWithPath: ffmpegPath)
        decoder.arguments = [
            "-nostdin", "-hide_banner", "-nostats", "-xerror", "-err_detect", "explode",
            "-threads", "1", "-filter_threads", "1",
            "-progress", progressURL.path, "-i", source.path, "-map", "0:a:0",
            "-af", "astats=metadata=0:reset=0", "-f", "null", "-",
        ]
        decoder.standardOutput = FileHandle.nullDevice
        decoder.standardError = diagnostics
        try decoder.run()
        defer {
            if decoder.isRunning {
                kill(decoder.processIdentifier, SIGKILL)
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while decoder.isRunning {
            guard ContinuousClock.now < deadline else { throw FixtureError.deadline }
            try await Task.sleep(for: .milliseconds(50))
        }
        // isRunning already became false. A redundant waitUntilExit can enter
        // a different executor thread's run loop and hang on macOS Foundation.
        let details = try String(contentsOf: diagnosticURL, encoding: .utf8)
        XCTAssertEqual(decoder.terminationStatus, 0, String(details.suffix(2_000)))
        let rmsLevels = details.components(separatedBy: .newlines).compactMap { line -> Double? in
            guard let marker = line.range(of: "RMS level dB:") else { return nil }
            return Double(line[marker.upperBound...].trimmingCharacters(in: .whitespaces))
        }
        XCTAssertTrue(rmsLevels.contains { $0.isFinite && $0 > -60 }, "Retained decoded media must contain signal")
        let decodedCounts = details.components(separatedBy: .newlines).compactMap { line -> Double? in
            guard let marker = line.range(of: "Number of samples:") else { return nil }
            return Double(line[marker.upperBound...].trimmingCharacters(in: .whitespaces))
        }
        let decodedCount = try XCTUnwrap(decodedCounts.max())
        let progress = try String(contentsOf: progressURL, encoding: .utf8)
        let microseconds = progress.components(separatedBy: .newlines).compactMap { line -> Int64? in
            guard line.hasPrefix("out_time_us=") else { return nil }
            return Int64(line.dropFirst("out_time_us=".count))
        }
        let timestampSeconds = Double(try XCTUnwrap(microseconds.last)) / 1_000_000
        let decodedSeconds = decodedCount / Double(Self.sampleRate)
        XCTAssertEqual(
            timestampSeconds, decodedSeconds, accuracy: 0.1, "Timestamps cannot substitute for decoded frames")
        return decodedSeconds
    }

    private enum FixtureError: Error {
        case deadline
        case fragmentsNotFlushed
        case frameCountMismatch
    }
}
