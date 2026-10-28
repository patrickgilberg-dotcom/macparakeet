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
        let client = ChatGPTLiveClient.shared
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
                model: selected.model, effort: nil, condition: "first-process-cold")
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
            for model in shortlist {
                print("Testing \(model.displayName) [\(model.slug)]")
                var accepted: ChatGPTModelSelection?
                // This is an explicit capability experiment. Unsupported attempts
                // stay in the report. Live requests do not repeat these probes.
                for effort: String? in ["none", "minimal", "low", nil] {
                    try Task.checkCancellation()
                    let result = await ChatGPTLiveBenchmark.trial(
                        model: model.slug, effort: effort,
                        condition:
                            "\(trials.isEmpty ? "first-inference-this-process-" : "")capability-probe-\(effort ?? "default")"
                    )
                    trials.append(result)
                    printTrial(result)
                    try save(trials, to: outputPath)
                    if result.completed, result.firstSentenceMs != nil {
                        accepted = ChatGPTModelSelection(model: model.slug, reasoningEffort: effort); break
                    }
                    // Only invalid-request errors warrant trying another effort.
                    guard result.error?.contains("HTTP 400") == true else { break }
                }
                guard let accepted else { continue }
                for condition in ["warm-recent", "warm-long-meeting"] {
                    for _ in 0..<trialsCount {
                        try Task.checkCancellation()
                        let result = await ChatGPTLiveBenchmark.trial(
                            model: model.slug, effort: accepted.reasoningEffort, condition: condition)
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
                "chatgpt-live-benchmark login|status|models|benchmark|disconnect\nbenchmark options: --trials 5 --models 3 [--model slug] --output /absolute/report.json"
            )
        }
    }

    static func save(_ trials: [ChatGPTBenchmarkTrial], to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ChatGPTLiveBenchmark.report(trials)).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func printTrial(_ trial: ChatGPTBenchmarkTrial) {
        print(
            "  \(trial.condition): \(trial.completed ? "completed" : "FAILED"); text \(trial.firstTextMs.map { String(Int($0)) } ?? "—")ms; sentence \(trial.firstSentenceMs.map { String(Int($0)) } ?? "—")ms; total \(Int(trial.completionMs))ms\(trial.error.map { "; \($0)" } ?? "")"
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
