import Foundation
import GRDB

/// Private durable work. The source FK removes snapshots when their meeting is
/// deleted; completed rows remain receipts when only the minutes are deleted.
public final class MeetingMinutesJobRepository: @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private static let statusColumns =
        "id, transcriptionID, state, skillRevision, sourceHash, coveredCharacters, totalCharacters, resultID, errorMessage, createdAt, updatedAt"

    public init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    public func allJobs() throws -> [MeetingMinutesJob] {
        try dbQueue.read { db in
            try MeetingMinutesJob.fetchAll(
                db, sql: "SELECT \(Self.statusColumns) FROM meeting_minutes_jobs ORDER BY createdAt, id")
        }
    }

    public func pendingJobs() throws -> [MeetingMinutesJob] {
        try dbQueue.read { db in
            try MeetingMinutesJob.fetchAll(
                db,
                sql:
                    "SELECT \(Self.statusColumns) FROM meeting_minutes_jobs WHERE state = 'pending' ORDER BY createdAt, id"
            )
        }
    }

    public func jobsFor(transcriptionID: UUID) throws -> [MeetingMinutesJob] {
        try dbQueue.read { db in
            try MeetingMinutesJob.fetchAll(
                db,
                sql:
                    "SELECT \(Self.statusColumns) FROM meeting_minutes_jobs WHERE transcriptionID = ? ORDER BY createdAt DESC, id DESC",
                arguments: [transcriptionID])
        }
    }

    public func job(for transcriptionID: UUID) throws -> MeetingMinutesJob? {
        try jobsFor(transcriptionID: transcriptionID).first
    }

    public func fetch(id: UUID) throws -> MeetingMinutesJob? {
        try dbQueue.read { db in
            try MeetingMinutesJob.fetchOne(
                db, sql: "SELECT \(Self.statusColumns) FROM meeting_minutes_jobs WHERE id = ?", arguments: [id])
        }
    }

    public func result(jobID: UUID) throws -> PromptResult? {
        try dbQueue.read { db in
            guard let work = try MeetingMinutesWork.fetchOne(db, key: jobID), let resultID = work.resultID else {
                return nil
            }
            return try PromptResult.fetchOne(db, key: resultID)
        }
    }

    /// Closes the completion/enqueue crash window without uploading old history.
    public func candidateIDs(createdAtOrAfter date: Date) throws -> [UUID] {
        try dbQueue.read { db in
            let identifiers = try UUID.fetchAll(
                db,
                sql: """
                    SELECT t.id FROM transcriptions t
                    WHERE t.sourceType = 'meeting' AND t.status = 'completed' AND t.createdAt >= ?
                      AND t.splitProvenance IS NULL
                      AND NOT EXISTS (SELECT 1 FROM meeting_minutes_jobs j WHERE j.transcriptionID = t.id)
                    ORDER BY t.createdAt, t.id
                    """, arguments: [date])
            var eligible: [UUID] = []
            for identifier in identifiers {
                do {
                    _ = try Self.captureSource(transcriptionID: identifier, in: db)
                    eligible.append(identifier)
                } catch MeetingMinutesError.sourceUnavailable {
                    // An empty completed row must not prevent later eligible
                    // meetings from entering the completion/enqueue scan.
                    continue
                }
            }
            return eligible
        }
    }

    public func captureSource(transcriptionID: UUID) throws -> MeetingMinutesSourceSnapshot {
        try dbQueue.read { try Self.captureSource(transcriptionID: transcriptionID, in: $0) }
    }

    public func sourceIsCurrent(_ source: MeetingMinutesSourceSnapshot) throws -> Bool {
        try dbQueue.read { db in
            guard let current = try? Self.captureSource(transcriptionID: source.transcriptionID, in: db) else {
                return false
            }
            return source.matches(current)
        }
    }

    @discardableResult
    public func enqueue(source: MeetingMinutesSourceSnapshot, skill: MeetingMinutesSkillSnapshot) throws
        -> MeetingMinutesJob
    {
        try dbQueue.write { db in try Self.enqueue(source: source, skill: skill, in: db).summary }
    }

    @discardableResult
    public func retry(
        jobID: UUID, source: MeetingMinutesSourceSnapshot? = nil,
        skill: MeetingMinutesSkillSnapshot? = nil
    ) throws -> MeetingMinutesJob {
        try dbQueue.write { db in
            guard var work = try MeetingMinutesWork.fetchOne(db, key: jobID) else {
                throw MeetingMinutesError.jobUnavailable
            }
            guard work.state == .failed else { throw MeetingMinutesError.jobBusy }
            let nextSource = try source ?? work.source
            let nextSkill = try skill ?? work.skill
            if MeetingMinutesIdentity.key(source: nextSource, skill: nextSkill) != work.identityKey {
                return try Self.enqueue(source: nextSource, skill: nextSkill, in: db).summary
            }
            try Self.requireCurrent(nextSource, in: db)
            work.state = .pending; work.attemptID = nil; work.errorMessage = nil
            work.allowsProviderRebind = true; work.updatedAt = Date()
            try work.update(db)
            return work.summary
        }
    }

    public func recoverInterruptedJobs() throws {
        try dbQueue.write { db in
            try db.execute(
                sql:
                    "UPDATE meeting_minutes_jobs SET state = 'failed', attemptID = NULL, errorMessage = ?, updatedAt = ? WHERE state = 'running'",
                arguments: [MeetingMinutesError.interrupted.localizedDescription, Date()])
        }
    }

    public func failPendingJob(jobID: UUID, message: String) throws {
        try dbQueue.write { db in
            guard var work = try MeetingMinutesWork.fetchOne(db, key: jobID), work.state == .pending else { return }
            work.state = .failed; work.errorMessage = String(message.prefix(500)); work.updatedAt = Date()
            try work.update(db)
        }
    }

    func claim(jobID: UUID, providerIdentity: String, provider: String, model: String?) throws -> MeetingMinutesWork {
        try dbQueue.write { db in
            guard var work = try MeetingMinutesWork.fetchOne(db, key: jobID) else {
                throw MeetingMinutesError.jobUnavailable
            }
            guard work.state == .pending else { throw MeetingMinutesError.jobBusy }
            try Self.requireCurrent(work.source, in: db)
            if let oldIdentity = work.providerIdentity, oldIdentity != providerIdentity {
                guard work.allowsProviderRebind else { throw MeetingMinutesError.providerChanged }
                work.progressJSON = try MeetingMinutesWork.encode(MeetingMinutesProgress())
                work.coveredCharacters = 0
            }
            work.state = .running; work.attemptID = UUID(); work.errorMessage = nil
            work.providerIdentity = providerIdentity; work.providerSnapshot = provider; work.modelSnapshot = model
            work.allowsProviderRebind = false; work.updatedAt = Date()
            try work.update(db)
            return work
        }
    }

    func checkpoint(jobID: UUID, attemptID: UUID, progress: MeetingMinutesProgress) throws {
        try dbQueue.write { db in
            var work = try Self.owned(jobID, attemptID: attemptID, in: db)
            try Self.requireCurrent(work.source, in: db)
            try Self.validateCoverage(progress, total: work.totalCharacters, complete: false)
            guard progress.coveredCharacters >= work.coveredCharacters else {
                throw MeetingMinutesError.incompleteCoverage
            }
            work.progressJSON = try MeetingMinutesWork.encode(progress)
            work.coveredCharacters = progress.coveredCharacters; work.updatedAt = Date()
            try work.update(db)
        }
    }

    func yield(jobID: UUID, attemptID: UUID) throws {
        try dbQueue.write { db in
            var work = try Self.owned(jobID, attemptID: attemptID, in: db)
            work.state = .pending; work.attemptID = nil; work.updatedAt = Date()
            try work.update(db)
        }
    }

    func fail(jobID: UUID, attemptID: UUID, error: MeetingMinutesError) throws {
        try dbQueue.write { db in
            guard var work = try MeetingMinutesWork.fetchOne(db, key: jobID), work.state == .running,
                work.attemptID == attemptID
            else { return }
            work.state = .failed; work.attemptID = nil; work.errorMessage = error.localizedDescription;
            work.updatedAt = Date()
            try work.update(db)
        }
    }

    func complete(jobID: UUID, attemptID: UUID, markdown: String) throws -> PromptResult {
        try dbQueue.write { db in
            var work = try Self.owned(jobID, attemptID: attemptID, in: db)
            let source = try work.source
            try Self.requireCurrent(source, in: db)
            try Self.validateCoverage(work.progress, total: work.totalCharacters, complete: true)
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingMinutesError.invalidResponse
            }
            let result = PromptResult(
                transcriptionId: work.transcriptionID, promptName: "Meeting Minutes",
                promptContent: try work.skill.markdown, content: markdown,
                providerSnapshot: work.providerSnapshot, modelSnapshot: work.modelSnapshot,
                sourceCorrectionRevision: source.correctionRevision,
                sourceTranscriptHash: source.canonicalTranscriptHash)
            // Fresh insert only. A bad replacement never deletes or overwrites a
            // valid result, and source/job/result publication is one transaction.
            try result.insert(db)
            work.resultID = result.id; work.state = .completed; work.attemptID = nil
            work.errorMessage = nil; work.updatedAt = Date()
            try work.update(db)
            return result
        }
    }

    private static func enqueue(
        source: MeetingMinutesSourceSnapshot, skill: MeetingMinutesSkillSnapshot, in db: Database
    ) throws -> MeetingMinutesWork {
        guard !skill.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            MeetingMinutesIdentity.hash(skill.markdown) == skill.revision
        else { throw MeetingMinutesError.invalidSkill }
        try requireCurrent(source, in: db)
        let identity = MeetingMinutesIdentity.key(source: source, skill: skill)
        if let existing = try MeetingMinutesWork.filter(Column("identityKey") == identity).fetchOne(db) {
            return existing
        }
        let now = Date()
        let work = MeetingMinutesWork(
            id: UUID(), transcriptionID: source.transcriptionID, identityKey: identity,
            state: .pending, skillRevision: skill.revision, sourceHash: source.sourceHash,
            coveredCharacters: 0, totalCharacters: source.transcript.count, resultID: nil, errorMessage: nil,
            createdAt: now, updatedAt: now, sourceJSON: try MeetingMinutesWork.encode(source),
            skillJSON: try MeetingMinutesWork.encode(skill),
            progressJSON: try MeetingMinutesWork.encode(MeetingMinutesProgress()),
            attemptID: nil, providerIdentity: nil, providerSnapshot: nil, modelSnapshot: nil,
            allowsProviderRebind: false)
        try work.insert(db)
        return work
    }

    private static func captureSource(transcriptionID: UUID, in db: Database) throws -> MeetingMinutesSourceSnapshot {
        guard let row = try Transcription.fetchOne(db, key: transcriptionID), row.sourceType == .meeting,
            row.status == .completed
        else { throw MeetingMinutesError.sourceUnavailable }
        let projection = try SpeakerAttributionReadService.resolve(transcription: row, in: db)
        let text = TranscriptAIContextFormatter.format(projection: projection, mode: .richTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MeetingMinutesError.sourceUnavailable }
        return MeetingMinutesSourceSnapshot(
            transcriptionID: row.id, transcript: text,
            sourceHash: MeetingMinutesIdentity.hash(text),
            canonicalTranscriptHash: PromptResultFreshness.sourceTranscriptHash(for: projection.effectiveTranscription),
            correctionRevision: projection.correctionRevision,
            attributionFingerprint: projection.attribution.fingerprint.rawValue,
            title: row.effectiveDisplayTitle)
    }

    private static func requireCurrent(_ source: MeetingMinutesSourceSnapshot, in db: Database) throws {
        guard let current = try? captureSource(transcriptionID: source.transcriptionID, in: db),
            source.matches(current)
        else { throw MeetingMinutesError.sourceChanged }
    }

    private static func owned(_ id: UUID, attemptID: UUID, in db: Database) throws -> MeetingMinutesWork {
        guard let work = try MeetingMinutesWork.fetchOne(db, key: id), work.state == .running,
            work.attemptID == attemptID
        else { throw MeetingMinutesError.jobUnavailable }
        return work
    }

    private static func validateCoverage(_ progress: MeetingMinutesProgress, total: Int, complete: Bool) throws {
        var frontier = 0
        for chunk in progress.chunks {
            guard chunk.start == frontier, chunk.end > chunk.start, chunk.end <= total,
                chunk.requestStart >= 0, chunk.requestStart <= chunk.start
            else { throw MeetingMinutesError.incompleteCoverage }
            frontier = chunk.end
        }
        guard !complete || frontier == total else { throw MeetingMinutesError.incompleteCoverage }
    }
}
