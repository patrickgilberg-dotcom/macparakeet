import Foundation
import XCTest
@testable import MacParakeetCore

final class MeetingMinutesArtifactRefresherTests: XCTestCase {
    func testMissingOrDeletedSourceDoesNotRecreateItsSessionFolder() async throws {
        let fixture = try Fixture(createSessionFolder: false)
        defer { fixture.removeTemporaryFiles() }
        let refresher = fixture.refresher()

        try await refresher.refresh(transcriptionID: UUID())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.path))
        XCTAssertTrue(try fixture.rows.delete(id: fixture.row.id))
        try await refresher.refresh(transcriptionID: fixture.row.id)

        XCTAssertNil(try fixture.rows.fetch(id: fixture.row.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    func testPresentSourceWithMissingSessionFolderSurfacesVisibleError() async throws {
        let fixture = try Fixture(createSessionFolder: false)
        defer { fixture.removeTemporaryFiles() }
        let minutes = try fixture.saveResult(name: "Meeting minutes", content: "Saved synthetic minutes.")

        do {
            try await fixture.refresher().refresh(transcriptionID: fixture.row.id)
            XCTFail("Missing portable files were reported as a successful refresh")
        } catch MeetingMinutesArtifactRefreshError.folderUnavailable {
            XCTAssertTrue(
                MeetingMinutesArtifactRefreshError.folderUnavailable.localizedDescription.contains("saved minutes"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.path))
        XCTAssertNotNil(try fixture.rows.fetch(id: fixture.row.id))
        XCTAssertEqual(try fixture.results.fetchAll(transcriptionId: fixture.row.id).map(\.id), [minutes.id])
    }

    func testSuccessfulRefreshIncludesSavedMinutesCurrentNotesAndEveryResult() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryFiles() }
        let minutes = try fixture.saveResult(name: "Meeting minutes", content: "Verified synthetic minutes.")
        let additional = try fixture.saveResult(name: "Earlier saved result", content: "Keep this other saved result.")
        XCTAssertTrue(try fixture.rows.updateUserNotes(id: fixture.row.id, userNotes: "Current edited meeting notes."))

        try await fixture.refresher().refresh(transcriptionID: fixture.row.id)

        let markdown = try String(
            contentsOf: fixture.folder.appendingPathComponent(MeetingArtifactStore.markdownFileName), encoding: .utf8)
        XCTAssertTrue(markdown.contains("Current edited meeting notes."))
        XCTAssertFalse(markdown.contains("Old synthetic meeting notes."))
        for result in [minutes, additional] {
            let resultURL = try fixture.resultMarkdownURL(for: result.id)
            XCTAssertTrue(markdown.contains(result.promptName))
            XCTAssertTrue(markdown.contains(resultURL.path))
            let resultMarkdown = try String(contentsOf: resultURL, encoding: .utf8)
            XCTAssertTrue(resultMarkdown.contains(result.content))
        }
        let notes = try String(contentsOf: MeetingNotesFile.fileURL(for: fixture.folder), encoding: .utf8)
        XCTAssertTrue(notes.contains("Current edited meeting notes."))
        let data = try Data(
            contentsOf: fixture.folder.appendingPathComponent(MeetingArtifactStore.promptResultsFileName))
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(exported.count, 2)
        XCTAssertEqual(
            Set(exported.compactMap { $0["content"] as? String }), Set([minutes.content, additional.content]))
        let manifestData = try Data(
            contentsOf: fixture.folder.appendingPathComponent(MeetingArtifactStore.manifestFileName))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual((manifest["promptResults"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(try fixture.results.fetchAll(transcriptionId: fixture.row.id).count, 2)
    }

    func testPortableFileFailureKeepsDatabaseMinutesAndRetryDoesNotDuplicateThem() async throws {
        let fixture = try Fixture()
        defer { fixture.removeTemporaryFiles() }
        let minutes = try fixture.saveResult(name: "Meeting minutes", content: "Durable synthetic minutes.")
        let blockedManifest = fixture.folder.appendingPathComponent(MeetingArtifactStore.manifestFileName)
        try FileManager.default.createDirectory(at: blockedManifest, withIntermediateDirectories: false)

        do {
            try await fixture.refresher().refresh(transcriptionID: fixture.row.id)
            XCTFail("The portable-file write failure was hidden")
        } catch {
            XCTAssertNotNil(error as? CocoaError)
        }
        let retained = try fixture.results.fetchAll(transcriptionId: fixture.row.id)
        XCTAssertEqual(retained.map(\.id), [minutes.id])
        XCTAssertEqual(retained.first?.content, minutes.content)
        XCTAssertNotNil(try fixture.rows.fetch(id: fixture.row.id))

        try FileManager.default.removeItem(at: blockedManifest)
        try await fixture.refresher().refresh(transcriptionID: fixture.row.id)

        XCTAssertEqual(try fixture.results.fetchAll(transcriptionId: fixture.row.id).map(\.id), [minutes.id])
        let markdown = try String(
            contentsOf: fixture.folder.appendingPathComponent(MeetingArtifactStore.markdownFileName), encoding: .utf8)
        let resultURL = try fixture.resultMarkdownURL(for: minutes.id)
        XCTAssertTrue(markdown.contains(minutes.promptName))
        XCTAssertTrue(markdown.contains(resultURL.path))
        let resultMarkdown = try String(contentsOf: resultURL, encoding: .utf8)
        XCTAssertTrue(resultMarkdown.contains(minutes.content))
    }
}

private struct Fixture {
    let root: URL
    let folder: URL
    let database: DatabaseManager
    let rows: TranscriptionRepository
    let results: PromptResultRepository
    let row: Transcription

    init(createSessionFolder: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingMinutesArtifactRefresherTests-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("synthetic-session", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if createSessionFolder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        database = try DatabaseManager()
        rows = TranscriptionRepository(dbQueue: database.dbQueue)
        results = PromptResultRepository(dbQueue: database.dbQueue)
        row = Transcription(
            fileName: "Synthetic artifact meeting", filePath: nil, meetingArtifactFolderPath: folder.path,
            rawTranscript: "Synthetic finalized meeting transcript.", status: .completed,
            sourceType: .meeting, userNotes: "Old synthetic meeting notes.")
        try rows.save(row)
    }

    func refresher() -> MeetingMinutesArtifactRefresher {
        .init(
            transcriptionRepository: rows, promptResultRepository: results,
            speakerAttributionReader: SpeakerAttributionReadService(dbQueue: database.dbQueue),
            artifactStore: MeetingArtifactStore())
    }

    func saveResult(name: String, content: String) throws -> PromptResult {
        let result = PromptResult(
            transcriptionId: row.id, promptName: name, promptContent: "Synthetic skill snapshot.", content: content)
        try results.save(result)
        return result
    }

    func resultMarkdownURL(for id: UUID) throws -> URL {
        let data = try Data(contentsOf: folder.appendingPathComponent(MeetingArtifactStore.manifestFileName))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let files = try XCTUnwrap(manifest["promptResults"] as? [[String: Any]])
        let record = try XCTUnwrap(files.first { ($0["id"] as? String) == id.uuidString })
        return URL(fileURLWithPath: try XCTUnwrap(record["path"] as? String))
    }

    func removeTemporaryFiles() { try? FileManager.default.removeItem(at: root) }
}
