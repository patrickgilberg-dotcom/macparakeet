import Foundation
import MacParakeetCore

@main
struct ChatGPTBenchmarkCommand {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data(("\(error.localizedDescription)\n").utf8))
            Foundation.exit(1)
        }
    }

    static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"
        let auth = ChatGPTAuth.shared
        let transportName = stringOption("--transport", in: arguments) ?? ChatGPTTransport.webSocket.rawValue
        guard let transport = ChatGPTTransport(rawValue: transportName) else {
            throw CommandError.message("Use --transport websocket or --transport http-sse.")
        }
        let client = transport == .webSocket ? ChatGPTLiveClient.shared : ChatGPTLiveClient(transport: transport)
        switch command {
        case "unlock":
            try await auth.unlockCredentialAccess()
            print("ChatGPT credential access approved for this benchmark executable.")
        case "login":
            print(
                "Opening Continue with ChatGPT for MacParakeet Live. Complete sign-in and allow ChatGPT plan usage in the browser."
            )
            let account = try await auth.signIn()
            print(
                "Connected: \(account.email ?? account.subject). ChatGPT plan usage: \(account.planUsageEnabled ? "enabled" : "disabled")."
            )
            let models = try await client.models(refresh: true)
            print("Available models: \(models.map(\.slug).joined(separator: ", "))")
            // Login alone is never reported as completed inference.
            let selected = try await client.selection()
            let trial = await ChatGPTLiveBenchmark.trial(
                client: client, model: selected.model, effort: selected.reasoningEffort,
                condition: "first-inference-this-process")
            try save([trial], to: "/tmp/macparakeet-live-first-inference.json")
            guard trial.completed, !trial.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CommandError.message(trial.error ?? "Subscription inference returned no completed text.")
            }
            let firstText = trial.firstTextMs.map { "\(Int($0))ms" } ?? "not observed"
            let firstSentence = trial.firstSentenceMs.map { "\(Int($0))ms" } ?? "not observed"
            print("Completed subscription inference. First text: \(firstText); first sentence: \(firstSentence).")
            print(trial.output)
        case "models":
            for model in try await client.models(refresh: true) { print("\(model.slug)\t\(model.displayName)") }
        case "websocket":
            try WebSocketProbe.contractChecks()
            let selected = try await client.selection()
            try await WebSocketProbe.run(
                model: stringOption("--model", in: arguments) ?? selected.model,
                trials: intOption("--trials", in: arguments) ?? 3)
        case "idlecheck":
            guard transport == .webSocket else {
                throw CommandError.message("Idle qualification uses --transport websocket.")
            }
            let secondsValue = stringOption("--seconds", in: arguments)
            guard !arguments.contains("--seconds") || secondsValue != nil,
                let seconds = Int(secondsValue ?? "180"), (30...600).contains(seconds)
            else { throw CommandError.message("Use --seconds with a whole number from 30 through 600.") }
            let outputPath = stringOption("--output", in: arguments) ?? "/tmp/macparakeet-live-idlecheck.json"
            let selected = try await client.selection()
            var warmupCompleted = false
            var trials: [ChatGPTBenchmarkTrial] = []
            do {
                try await client.warmUp()
                warmupCompleted = true
                print(
                    "Production WebSocket warm-up started without a model request. Waiting \(seconds) seconds unused.")
                try await Task.sleep(for: .seconds(seconds))
                try Task.checkCancellation()
                let trial = await ChatGPTLiveBenchmark.trial(
                    client: client, model: selected.model, effort: selected.reasoningEffort,
                    condition: "unused-warmup-idle-\(seconds)s")
                trials = [trial]
                printTrial(trial)
                guard trial.completed, !trial.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CommandError.message(
                        trial.error ?? "The first request after unused warm-up did not complete.")
                }
                try saveIdleCheck(
                    trials, seconds: seconds, selection: selected, warmupCompleted: warmupCompleted,
                    error: nil, to: outputPath)
                print("Idle qualification completed. Report: \(outputPath)")
            } catch {
                try saveIdleCheck(
                    trials, seconds: seconds, selection: selected, warmupCompleted: warmupCompleted,
                    error: error.localizedDescription, to: outputPath)
                throw error
            }
        case "status":
            if let account = await auth.activeAccount() {
                print(
                    "\(account.email ?? account.subject) — plan usage \(account.planUsageEnabled ? "enabled" : "disabled")"
                )
            } else {
                print("Disconnected")
            }
        case "benchmark":
            let trialsCount = intOption("--trials", in: arguments) ?? 5
            let modelCount = intOption("--models", in: arguments) ?? 3
            let outputPath = stringOption("--output", in: arguments) ?? "/tmp/macparakeet-live-benchmark.json"
            guard (1...50).contains(trialsCount), (1...10).contains(modelCount) else {
                throw CommandError.message("Use 1–50 trials and 1–10 models.")
            }
            let available = try await client.models(refresh: true)
            let explicit = stringOption("--model", in: arguments)
            let shortlist =
                explicit.map { slug in available.filter { $0.slug == slug } } ?? Array(available.prefix(modelCount))
            guard !shortlist.isEmpty else { throw ChatGPTLiveError.noModels }
            var trials: [ChatGPTBenchmarkTrial] = []
            var choices: [(ChatGPTModelSelection, Double)] = []
            print("Transport: \(transport.rawValue)")
            for model in shortlist {
                print("Testing \(model.displayName) [\(model.slug)]")
                var accepted: ChatGPTModelSelection?
                // This is an explicit capability experiment. Unsupported attempts
                // stay in the report. Live requests do not repeat these probes.
                for effort: String? in ["none", "minimal", "low", nil] {
                    try Task.checkCancellation()
                    let result = await ChatGPTLiveBenchmark.trial(
                        client: client, model: model.slug, effort: effort,
                        condition:
                            "\(trials.isEmpty ? "first-inference-this-process-" : "")capability-probe-\(effort ?? "default")"
                    )
                    trials.append(result)
                    printTrial(result)
                    try save(trials, to: outputPath)
                    if result.completed, result.firstSentenceMs != nil {
                        accepted = ChatGPTModelSelection(model: model.slug, reasoningEffort: effort); break
                    }
                    // Capability experiments may advance after a structured
                    // unsupported-effort error even when WS omits HTTP status.
                    let unsupported = [
                        "unsupported_value", "unsupported_reasoning_effort",
                        "subscription_sharing_unsupported_capability",
                    ]
                    guard result.errorStatus == 400 || result.errorCode.map(unsupported.contains) == true else { break }
                }
                guard let accepted else { continue }
                for condition in ["warm-recent", "warm-long-meeting"] {
                    for _ in 0..<trialsCount {
                        try Task.checkCancellation()
                        let result = await ChatGPTLiveBenchmark.trial(
                            client: client, model: model.slug, effort: accepted.reasoningEffort, condition: condition)
                        trials.append(result)
                        printTrial(result)
                        try save(trials, to: outputPath)
                    }
                }
                let warm = trials.filter { $0.model == model.slug && $0.condition.hasPrefix("warm-") }
                let summary = ChatGPTLiveBenchmark.report(warm).summaries
                if warm.allSatisfy({ $0.completed && $0.firstSentenceMs != nil }),
                    summary.count == 2, let worstP95 = summary.compactMap(\.p95FirstSentenceMs).max()
                {
                    choices.append((accepted, worstP95))
                }
            }
            if let best = choices.min(by: { $0.1 < $1.1 }) {
                try await client.selectModel(best.0)
                print(
                    "Selected \(best.0.model), effort \(best.0.reasoningEffort ?? "provider default"), using lowest measured worst-context p95 first-sentence latency."
                )
            }
            try save(trials, to: outputPath)
            print("Report: \(outputPath)")
            guard trials.contains(where: \.completed) else {
                throw CommandError.message("No subscription inference completed; see the failure report.")
            }
        case "disconnect": try await auth.disconnect(); print("Disconnected locally.")
        default:
            print(
                "chatgpt-live-benchmark login|unlock|status|models|benchmark|websocket|idlecheck|disconnect\nbenchmark options: --transport websocket|http-sse --trials 5 --models 3 [--model slug] --output /absolute/report.json\nwebsocket options: [--model selected-slug] --trials 5 (isolated socket versus explicit HTTP comparison)\nidlecheck options: --seconds 180 (30–600) --output /absolute/report.json; production warmUp, unused idle, then one synthetic request"
            )
        }
    }

    static func save(_ trials: [ChatGPTBenchmarkTrial], to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ChatGPTLiveBenchmark.report(trials)).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func saveIdleCheck(
        _ trials: [ChatGPTBenchmarkTrial], seconds: Int, selection: ChatGPTModelSelection,
        warmupCompleted: Bool, error: String?, to path: String
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ChatGPTLiveBenchmark.report(trials))
        var report = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var qualification: [String: Any] = [
            "idleSeconds": seconds, "model": selection.model,
            "reasoningEffort": selection.reasoningEffort ?? "provider-default",
            "warmupCallCompleted": warmupCompleted,
        ]
        if let error { qualification["error"] = error }
        report["idleCheck"] = qualification
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func printTrial(_ trial: ChatGPTBenchmarkTrial) {
        print(
            "  \(trial.transport.rawValue) \(trial.condition): \(trial.completed ? "completed" : "FAILED"); text \(trial.firstTextMs.map { String(Int($0)) } ?? "—")ms; sentence \(trial.firstSentenceMs.map { String(Int($0)) } ?? "—")ms; total \(Int(trial.completionMs))ms\(trial.error.map { "; \($0)" } ?? "")"
        )
    }
    static func stringOption(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    static func intOption(_ name: String, in arguments: [String]) -> Int? {
        stringOption(name, in: arguments).flatMap(Int.init)
    }
    enum CommandError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
    }
}
