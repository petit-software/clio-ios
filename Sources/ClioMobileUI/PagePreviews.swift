import ClioMobileCore
import SwiftUI

/// Whether Settings shows its Developer page.
///
/// Debug builds always. A TestFlight build too: a beta tester on a phone
/// has no Xcode and no previews, and the states that are awkward to reach
/// by hand — a full library, no model installed, a transcript that failed —
/// are exactly the ones worth looking at on real hardware. An App Store
/// build has a real receipt and never shows it.
enum DeveloperAccess {
    static var isAvailable: Bool {
        #if DEBUG
        return true
        #else
        return isTestFlight
        #endif
    }

    /// TestFlight installs carry a `sandboxReceipt` in the bundle's StoreKit
    /// folder where the App Store puts a plain `receipt`.
    ///
    /// The path is read rather than `Bundle.appStoreReceiptURL`, which is
    /// deprecated from iOS 18 in favour of `AppTransaction`. The same
    /// heuristic either way — and `AppTransaction.shared` is async and can
    /// reach the network or ask the user to sign in, which is far too much
    /// for deciding whether to draw a row in Settings.
    static var isTestFlight: Bool {
        let receipt = Bundle.main.bundleURL
            .appendingPathComponent("StoreKit", isDirectory: true)
            .appendingPathComponent("sandboxReceipt")
        return FileManager.default.fileExists(atPath: receipt.path)
    }

    static var footer: String {
        #if DEBUG
        return "Sample data and every state of every screen. Debug and TestFlight builds."
        #else
        return "Sample data and every state of every screen. TestFlight builds."
        #endif
    }
}

// MARK: - The section

/// Settings ▸ Developer ▸ Page previews: one row per screen, each opening
/// a list of the states that screen can be in, each of those opening the
/// real screen staged in that state.
struct PagePreviewsSection: View {
    var body: some View {
        Section {
            NavigationLink("Home") {
                PreviewCaseList(title: "Home", cases: PreviewCase.home)
            }
            NavigationLink("Recording Details") {
                PreviewCaseList(title: "Recording Details", cases: PreviewCase.detail)
            }
        } header: {
            Text("Page previews")
        } footer: {
            Text("Every state each screen can be in, on the phone rather than in Xcode. "
                 + "Each one is the real screen on a library of its own; nothing here "
                 + "touches your recordings.")
        }
    }
}

/// The states of one screen.
private struct PreviewCaseList: View {
    let title: String
    let cases: [PreviewCase]

    var body: some View {
        List(cases) { item in
            NavigationLink {
                // No title of its own: what is pushed is a whole screen,
                // navigation bar and all.
                item.screen()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                    Text(item.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(title)
        .softScrollEdges()
    }
}

// MARK: - The cases

/// One staged screen: a name, a line saying what is being looked at, and
/// the screen itself on a model built for it.
struct PreviewCase: Identifiable {
    let id: String
    let note: String
    let make: @MainActor () -> AnyView

    var name: String { id }

    @MainActor
    func screen() -> AnyView { make() }

    init(_ name: String, _ note: String,
         @ViewBuilder make: @MainActor @escaping () -> some View) {
        self.id = name
        self.note = note
        self.make = { AnyView(make()) }
    }
}

extension PreviewCase {

    /// Settings a staged screen always wants: the intro sheet has been
    /// seen, or every preview opens behind it.
    @MainActor
    private static func settings(
        _ change: (inout ClioMobileCore.Settings) -> Void = { _ in }
    ) -> ClioMobileCore.Settings {
        var settings = ClioMobileCore.Settings()
        settings.introShown = true
        change(&settings)
        return settings
    }

    // MARK: Home

    static var home: [PreviewCase] {
        [
            PreviewCase("Library", "Five recordings, a model installed.") {
                RootView().environment(AppModel.simulating(settings: settings()))
            },
            PreviewCase("A month of recordings", "Twenty-four, every status, both languages.") {
                RootView().environment(
                    AppModel.simulating(recordings: SampleRecordings.varied(count: 24),
                                        settings: settings()))
            },
            PreviewCase("Nothing yet", "A fresh install: no recordings and no model.") {
                RootView().environment(
                    AppModel.simulating(recordings: [], settings: settings(),
                                        models: PreviewData.models(installed: [])))
            },
            PreviewCase("No recordings", "A model is installed; nothing has been recorded.") {
                RootView().environment(
                    AppModel.simulating(recordings: [], settings: settings()))
            },
            PreviewCase("No transcription model", "Recordings, but nothing to transcribe with.") {
                RootView().environment(
                    AppModel.simulating(settings: settings(),
                                        models: PreviewData.models(installed: [])))
            },
            PreviewCase("Hold to record, running", "The screen receded, the clock, the wash at height.") {
                StagedHome(settings: settings { $0.holdToRecord = true }, stage: .recording)
            },
            PreviewCase("Transcribing", "Stopped, waiting for the transcript.") {
                StagedHome(settings: settings(), stage: .transcribing)
            },
            PreviewCase("Pane style", "The other home: the button as a strip under the list.") {
                RootView(homeStyle: .pane).environment(AppModel.simulating(settings: settings()))
            },
        ]
    }

    // MARK: Recording details

    static var detail: [PreviewCase] {
        [
            PreviewCase("Everything", "Transcript, summary, segments, a location.") {
                StagedDetail(recordings: PreviewData.recordings, index: 0)
            },
            PreviewCase("Transcript only", "No summary, no segments, a typed title.") {
                StagedDetail(recordings: PreviewData.recordings, index: 1)
            },
            PreviewCase("Nothing was heard", "A recording with no speech in it.") {
                StagedDetail(recordings: PreviewData.recordings, index: 2)
            },
            PreviewCase("Another language", "Dutch, so the language row has something to say.") {
                StagedDetail(recordings: PreviewData.recordings, index: 3)
            },
            PreviewCase("Failed", "The transcript did not happen, and the audio is still there.") {
                StagedDetail(recordings: PreviewData.recordings, index: 4)
            },
            PreviewCase("Still pending", "Recorded, not yet transcribed.") {
                StagedDetail(recordings: [pending], index: 0)
            },
            PreviewCase("Summarizing", "The language model is writing, and the row says so.") {
                StagedDetail(recordings: PreviewData.recordings, index: 1, summarizing: true)
            },
            PreviewCase("No Apple Intelligence", "The menu without Summarize in it.") {
                StagedDetail(recordings: PreviewData.recordings, index: 0,
                             summarizer: StubSummaryEngine(
                                availability: .unavailable(
                                    reason: "This phone does not support Apple Intelligence.")))
            },
        ]
    }

    private static var pending: Recording {
        Recording(createdAt: Date().addingTimeInterval(-90), duration: 38, status: .pending)
    }
}

// MARK: - Staging

/// The home screen with the capture loop already in a particular state.
/// Driven rather than faked: the simulated recorder and the stub engine
/// are real enough to put the controller where it needs to be, which is
/// the only way in — the state is `private(set)`.
private struct StagedHome: View {
    let settings: ClioMobileCore.Settings
    let stage: Stage
    @State private var model: AppModel?

    enum Stage { case recording, transcribing }

    var body: some View {
        Group {
            if let model {
                RootView().environment(model)
            } else {
                ProgressView()
            }
        }
        .task {
            guard model == nil else { return }
            // A latency nobody outruns: the point is to stand in the state
            // and look at it, not to watch it pass.
            let built = AppModel.simulating(
                settings: settings,
                engine: StubTranscriptionEngine(latency: .seconds(600)))
            model = built
            await built.capture.start(discardingSilence: false)
            if stage == .transcribing { await built.capture.stop() }
        }
    }
}

/// One recording's detail view on a library holding only what it needs.
private struct StagedDetail: View {
    let recordings: [Recording]
    let index: Int
    var summarizing = false
    var summarizer: (any SummaryEngine)?
    @State private var model: AppModel?

    var body: some View {
        Group {
            if let model, let recording = model.library.recordings[safe: index] {
                NavigationStack {
                    RecordingDetailView(id: recording.id)
                }
                .environment(model)
            } else {
                ProgressView()
            }
        }
        .task {
            guard model == nil else { return }
            var settings = ClioMobileCore.Settings()
            settings.introShown = true
            // Audio on disk, so the player has something to load and the
            // file size row is not empty.
            let built = AppModel.simulating(
                recordings: recordings,
                audio: true,
                settings: settings,
                summarizer: summarizer ?? StubSummaryEngine(latency: .seconds(600)))
            model = built
            await built.intelligence.refreshAvailability()
            if summarizing, let recording = built.library.recordings[safe: index] {
                built.intelligence.summarize(recording.id)
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
