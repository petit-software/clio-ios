import Foundation
import Testing
import ClioMobileCore
import MLX
@testable import ClioMobileSummary

/// The MLX engine on a real downloaded model, on this Mac's GPU — the only
/// thing that proves a summary can be written without Apple Intelligence.
/// Off by default: it downloads the smallest catalog model (~350 MB) into
/// /tmp once and keeps it. Run deliberately:
///
///     CLIO_INTEGRATION=1 swift test --filter MLX
///     CLIO_INTEGRATION=1 CLIO_SUMMARY_MODEL=Qwen3-1.7B-4bit swift test --filter MLX
///
/// A Mac's GPU is not a phone's: the timings printed here say which model
/// is the better writer, not how long a phone takes. That number is a
/// device test, see AGENTS.md.
private let integrationEnabled =
    ProcessInfo.processInfo.environment["CLIO_INTEGRATION"] != nil

@Suite("MLX summaries", .enabled(if: integrationEnabled), .serialized)
struct MLXIntegrationTests {

    enum IntegrationError: Error { case downloadFailed(String) }

    private var modelID: String {
        ProcessInfo.processInfo.environment["CLIO_SUMMARY_MODEL"] ?? "Qwen3-0.6B-4bit"
    }

    private var sharedRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-ios-integration-language-models", isDirectory: true)
    }

    @MainActor
    private func installModel() async throws -> (InstalledModel, CatalogModel) {
        try FileManager.default.createDirectory(at: sharedRoot, withIntermediateDirectories: true)
        let entry = try #require(LanguageModelCatalog.builtIn.first { $0.id == modelID })
        let manager = ModelManager(transport: HuggingFaceTransport(), modelsDirectory: sharedRoot,
                                   layout: .languageModel)
        if !manager.isInstalled(entry.id) {
            manager.download(entry)
            let deadline = ContinuousClock.now + .seconds(1200)
            while !manager.isInstalled(entry.id) {
                if let failure = manager.failures[entry.id] { throw IntegrationError.downloadFailed(failure) }
                guard ContinuousClock.now < deadline else { throw IntegrationError.downloadFailed("timed out") }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        return (try #require(manager.installed.first { $0.id == entry.id }), entry)
    }

    private let transcript = """
        Quick note before I forget. The plumber can come Thursday morning \
        but only before ten, so someone has to be home. The estimate for the \
        boiler was eleven hundred, which is more than we said, so I want a \
        second quote before we commit. And the balcony door still sticks in \
        the heat, ask him about that too while he is here.
        """

    @Test("A downloaded model writes a title and notes with the shared prompt, in each shape")
    func summarizes() async throws {
        let (installed, entry) = try await installModel()
        print("[mlx] model \(entry.displayName), \(installed.sizeBytes / 1_000_000) MB on disk, "
              + "estimated \(entry.memoryBytes.map { $0 / 1_000_000 } ?? 0) MB to run")
        let engine = MLXSummaryEngine()
        #expect(engine.deviceSupport.isSupported)

        let shapes: [(String, SummaryPreferences)] = [
            ("notes, paragraphs, standard", SummaryPreferences()),
            ("to-dos, bullets, brief", SummaryPreferences(noteType: .todo, format: .bullets, length: .brief)),
            ("meeting, numbered, detailed", SummaryPreferences(noteType: .meeting, format: .numbered, length: .detailed)),
        ]
        for (name, preferences) in shapes {
            let started = ContinuousClock.now
            let summary = try await engine.summarize(
                SummaryRequest(transcript: transcript, language: "en", preferences: preferences),
                using: installed)
            let took = ContinuousClock.now - started
            print("[mlx] \(name) in \(took): title \"\(summary.title)\"")
            print("[mlx] \(summary.summary.replacingOccurrences(of: "\n", with: " ⏎ "))")
            print("[mlx] peak GPU memory \(MLX.GPU.peakMemory / 1_000_000) MB, "
                  + "process footprint \(Self.footprintMB()) MB")
            #expect(!summary.title.isEmpty)
            #expect(summary.title.split(separator: " ").count <= 5)
            #expect(!summary.summary.isEmpty)
            let text = summary.summary.lowercased()
            #expect(text.contains("plumber") || text.contains("boiler") || text.contains("thursday"))
            #expect(!summary.summary.contains("<think>"))
            #expect(!summary.summary.contains("<end_of_turn>"))
            // Told not to, the 1.7B model still writes "£1100" for "eleven
            // hundred" now and then. Reported, not asserted: it is the known
            // limit of a small model, documented in the plan.
            if summary.summary.contains("$") || summary.summary.contains("£") || summary.summary.contains("€") {
                print("[mlx] note: a currency sign the speaker did not say")
            }
            if preferences.format == .bullets {
                #expect(summary.summary.contains("- ") || summary.summary.contains("• "), "bullets, as asked")
            }
        }
    }

    @Test("Dutch comes back in Dutch, or at least about the right things")
    func dutch() async throws {
        let (installed, _) = try await installModel()
        let engine = MLXSummaryEngine()
        let dutch = """
            Even een notitie voor morgen. De loodgieter kan donderdagochtend komen, \
            maar alleen voor tienen, dus er moet iemand thuis zijn. De offerte voor \
            de ketel was elfhonderd euro, meer dan afgesproken, dus ik wil eerst een \
            tweede offerte. En de balkondeur klemt nog steeds als het warm is.
            """
        let summary = try await engine.summarize(
            SummaryRequest(transcript: dutch, language: "nl"), using: installed)
        print("[mlx] nl title: \(summary.title)")
        print("[mlx] nl summary: \(summary.summary.replacingOccurrences(of: "\n", with: " ⏎ "))")
        #expect(!summary.title.isEmpty)
        #expect(!summary.summary.isEmpty)
        let text = summary.summary.lowercased()
        #expect(text.contains("loodgieter") || text.contains("ketel") || text.contains("plumber"))
    }

    /// Resident memory of this process, which is what jetsam counts on a
    /// phone; the GPU figure alone is the weights and the cache.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_000_000) : -1
    }

    @Test("Thinking tags are stripped before the answer is read")
    func stripping() {
        let raw = "<think>\nLet me see.\n</think>\nTitle: Plumber Thursday\n\nThe plumber comes Thursday."
        let clean = MLXSummaryEngine.strippingThinking(raw)
        #expect(clean.hasPrefix("Title: Plumber Thursday"))
        #expect(SummaryPrompt.parse(clean).title == "Plumber Thursday")
        let runOn = "The plumber comes Thursday.<end_of_turn><end_of_turn>tained<end_of_turn>"
        #expect(MLXSummaryEngine.strippingThinking(runOn) == "The plumber comes Thursday.")
    }
}
