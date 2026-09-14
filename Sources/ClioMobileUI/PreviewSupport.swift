import ClioMobileCore
import Foundation

/// Fixed recordings and models for previews. Dates are relative to now so
/// the list's "Today / Yesterday" grouping shows every band.
public enum PreviewData {
    public static let recordings: [Recording] = {
        let now = Date()
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        return [
            Recording(createdAt: ago(600), duration: 47,
                      title: "",
                      transcript: "Remember to move the dentist appointment to Thursday, "
                        + "and ask whether the invoice for March was ever sent. "
                        + "Also the balcony door still sticks in the heat.",
                      language: "en", modelID: "openai_whisper-small_216MB",
                      summary: "Move the dentist appointment to Thursday and check whether "
                        + "the March invoice was sent. The balcony door still sticks in the heat.",
                      generatedTitle: "Dentist, invoice, balcony door"),
            Recording(createdAt: ago(3 * 3600), duration: 312,
                      title: "Standup notes",
                      transcript: "The migration ran clean on staging. Two flaky tests "
                        + "in the payment suite, both timing. Nobody has looked at the "
                        + "onboarding copy yet; that's on me for tomorrow.",
                      language: "en", modelID: "openai_whisper-small_216MB"),
            Recording(createdAt: ago(26 * 3600), duration: 4,
                      status: .nothingHeard),
            Recording(createdAt: ago(30 * 3600), duration: 128,
                      title: "Idee voor de tuin",
                      transcript: "Als we de schutting een meter naar achteren zetten "
                        + "past er een kleine kas naast de schuur.",
                      language: "nl", modelID: "openai_whisper-small_216MB"),
            Recording(createdAt: ago(5 * 86_400), duration: 91,
                      status: .failed("The transcription model is not loaded yet.")),
        ]
    }()

    /// Small installed, Tiny half-downloaded, the large one failed once —
    /// every row state the Model section has, in one screen.
    @MainActor
    public static func models(installed: [InstalledModel] = [ModelManager.simulatedInstalled()],
                              downloads: [String: DownloadProgress] = [
                                "openai_whisper-tiny": DownloadProgress(
                                    receivedBytes: 31_000_000, totalBytes: 77_000_000,
                                    completedFiles: 3, totalFiles: 9),
                              ],
                              failures: [String: String] = [
                                "openai_whisper-large-v3_turbo_954MB":
                                    "The network connection was lost.",
                              ]) -> ModelManager {
        ModelManager.simulating(installed: installed, downloads: downloads, failures: failures)
    }
}
