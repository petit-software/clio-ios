import ClioMobileCore
import SwiftUI

/// A page of Settings something elsewhere in the app can send the user
/// straight to, rather than to the list and a hunt for the row.
enum SettingsPage: Hashable {
    case model
}

/// Settings: a list of pages, one per topic, each row showing the value
/// that matters. Every control binds straight to the one `Settings`
/// struct; the store debounces the writes.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeleteAll = false
    /// A model that would not delete, shown once and dismissed.
    @State private var deleteError: String?
    /// The stack starts here, so opening on the Model page lands there
    /// rather than sliding there after the sheet is up — and Back still
    /// goes to Settings itself. A `navigationDestination(isPresented:)`
    /// that starts true does not push at all; the path does.
    @State private var path: [SettingsPage]

    init(initialPage: SettingsPage? = nil) {
        _path = State(initialValue: initialPage.map { [$0] } ?? [])
    }

    var body: some View {
        @Bindable var store = model.settings
        NavigationStack(path: $path) {
            Form {
                Section {
                    AppHeader()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section {
                    // By value, so the row and the library's banner both
                    // arrive through the same destination below.
                    NavigationLink(value: SettingsPage.model) {
                        LabeledContent("Model", value: activeModelName)
                    }
                } footer: {
                    Text("Which Whisper model transcribes, downloading and deleting "
                         + "models, and whether one stays loaded between recordings.")
                }
                Section {
                    page("Transcription",
                         value: TranscriptionLanguage.name(for: store.settings.language)) {
                        transcriptionSection(store)
                    }
                } footer: {
                    Text("The spoken language, translation to English, custom "
                         + "vocabulary, and word replacements.")
                }
                Section {
                    page("Text", value: textSummary(store)) {
                        textSection(store)
                    }
                } footer: {
                    Text("How a transcript is tidied: a capital at the start and "
                         + "trailing punctuation.")
                }
                Section {
                    Picker("Appearance", selection: Binding(
                        get: { store.settings.appearance },
                        set: { store.settings.appearance = $0 })) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text("Light, dark, or whatever the phone is set to.")
                }
                Section {
                    page("Recording",
                         value: RecordingLimit.label(seconds: store.settings.maxRecordingSeconds)) {
                        recordingSection(store)
                    }
                } footer: {
                    Text("The length cap, silence trimming, haptics, and hold to record.")
                }
                Section {
                    page("Intelligence", value: intelligenceSummary(store)) {
                        intelligenceSection(store)
                    }
                } footer: {
                    Text("Titles and summaries from the language model built into iOS, "
                         + "on the phone.")
                }
                Section {
                    page("About", value: Self.version) {
                        aboutSection
                    }
                    Link(destination: Self.macApp) {
                        HStack {
                            Text("Get Clio for macOS")
                            Spacer()
                            Text("GitHub")
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                    Link(destination: Self.follow) {
                        HStack {
                            Text("Follow")
                            Spacer()
                            Text("@bartbak_")
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                }
                if DeveloperAccess.isAvailable {
                    Section {
                        page("Developer", value: "\(model.library.recordings.count) recordings") {
                            DeveloperSettingsPage()
                        }
                    } footer: {
                        Text(DeveloperAccess.footer)
                    }
                }
            }
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .model: ModelSettingsPage()
                }
            }
            .navigationTitle("Settings")
            .inlineTitle()
            .softScrollEdges()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Rows and pages

    /// A row that opens a page holding one of the sections below.
    private func page<Content: View>(_ title: String, value: String,
                                     @ViewBuilder content: @escaping () -> Content) -> some View {
        NavigationLink {
            Form { content() }
                .navigationTitle(title)
        } label: {
            LabeledContent(title, value: value)
        }
    }

    private var activeModelName: String {
        model.capture.activeModel?.displayName ?? "None"
    }

    private func textSummary(_ store: SettingsStore) -> String {
        var on: [String] = []
        if store.settings.capitalizeFirstLetter { on.append("Capitalize") }
        if store.settings.trimTrailingPunctuation { on.append("Trim") }
        return on.isEmpty ? "As spoken" : on.joined(separator: ", ")
    }

    private func intelligenceSummary(_ store: SettingsStore) -> String {
        guard model.intelligence.availability.isAvailable else { return "Unavailable" }
        return store.settings.generateSummaries ? "On" : "Off"
    }

    // MARK: Sections

    private func transcriptionSection(_ store: SettingsStore) -> some View {
        Section {
            Picker("Language", selection: Binding(
                get: { store.settings.language ?? "auto" },
                set: { store.settings.language = $0 == "auto" ? nil : $0 })) {
                Text("Auto-detect").tag("auto")
                ForEach(TranscriptionLanguage.all) { language in
                    Text(language.name).tag(language.id)
                }
            }
            Toggle("Translate to English", isOn: Binding(
                get: { store.settings.translateToEnglish },
                set: { store.settings.translateToEnglish = $0 }))
            Toggle(isOn: Binding(
                get: { store.settings.autoCopyTranscript },
                set: { store.settings.autoCopyTranscript = $0 })) {
                Text("Auto Copy to Clipboard")
                Text("Every finished transcript is copied, ready to paste.")
            }
            NavigationLink {
                VocabularyEditor()
            } label: {
                LabeledContent("Custom Vocabulary",
                               value: countLabel(store.settings.customVocabulary.count, "term"))
            }
            NavigationLink {
                ReplacementsEditor()
            } label: {
                LabeledContent("Word Replacements",
                               value: countLabel(store.settings.wordReplacements.count, "rule"))
            }
        }
    }

    private func textSection(_ store: SettingsStore) -> some View {
        Section {
            Toggle("Capitalize first letter", isOn: Binding(
                get: { store.settings.capitalizeFirstLetter },
                set: { store.settings.capitalizeFirstLetter = $0 }))
            Toggle("Trim trailing punctuation", isOn: Binding(
                get: { store.settings.trimTrailingPunctuation },
                set: { store.settings.trimTrailingPunctuation = $0 }))
        }
    }

    private func recordingSection(_ store: SettingsStore) -> some View {
        Section {
            Stepper(value: Binding(
                get: { RecordingLimit.minutes(seconds: store.settings.maxRecordingSeconds) },
                set: { store.settings.maxRecordingSeconds = RecordingLimit.seconds(minutes: $0) }),
                    in: RecordingLimit.range, step: 1) {
                LabeledContent("Maximum length",
                               value: RecordingLimit.label(seconds: store.settings.maxRecordingSeconds))
            }
            Toggle("Trim silence", isOn: Binding(
                get: { store.settings.voiceActivityDetection },
                set: { store.settings.voiceActivityDetection = $0 }))
            if store.settings.voiceActivityDetection {
                VStack(alignment: .leading) {
                    Text("Sensitivity")
                    Slider(value: Binding(
                        get: { store.settings.vadSensitivity },
                        set: { store.settings.vadSensitivity = $0 }), in: 0...1) {
                        Text("Sensitivity")
                    } minimumValueLabel: {
                        Image(systemName: "speaker.wave.1")
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3")
                    }
                }
            }
            Toggle("Haptic feedback", isOn: Binding(
                get: { store.settings.hapticFeedback },
                set: { store.settings.hapticFeedback = $0 }))
            Toggle("Hold to record", isOn: Binding(
                get: { store.settings.holdToRecord },
                set: { store.settings.holdToRecord = $0 }))
            Toggle(isOn: Binding(
                get: { store.settings.includeLocation },
                set: { on in
                    store.settings.includeLocation = on
                    if on { model.capture.locations.requestAccess() }
                })) {
                Text("Include location")
                Text("Where a recording was made is kept with it, on this phone.")
            }
        } footer: {
            Text("Silence at the start and end of a recording is cut before "
                 + "transcription. Higher sensitivity keeps quieter speech. "
                 + "With Hold to record on, the button records while your finger "
                 + "is on it and stops when you let go.")
        }
    }

    private func intelligenceSection(_ store: SettingsStore) -> some View {
        let availability = model.intelligence.availability
        return Section {
            Toggle("Titles and summaries", isOn: Binding(
                get: { store.settings.generateSummaries },
                set: { store.settings.generateSummaries = $0 }))
            if availability.isAvailable {
                NavigationLink {
                    SummaryInstructionsEditor()
                } label: {
                    LabeledContent("Instructions",
                                   value: store.settings.summaryInstructions
                                       .trimmingCharacters(in: .whitespacesAndNewlines)
                                       .isEmpty ? "Default" : "Custom")
                }
            }
            if let reason = availability.reason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        } footer: {
            Text(availability.isAvailable
                 ? "After each transcription the language model built into iOS "
                   + "writes a title and a short summary. The transcript never "
                   + "leaves the phone."
                 : "Needs iOS 26 and Apple Intelligence. When it is on, the language "
                   + "model built into iOS writes a title and a short summary for "
                   + "each recording, on the phone.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.version)
            LabeledContent("Recordings",
                           value: "\(model.library.recordings.count) · \(Format.bytes(model.library.audioBytes))")
            LabeledContent("Models",
                           value: "\(model.models.installed.count) · \(Format.bytes(model.models.installedBytes))")
            LabeledContent("On this phone",
                           value: Format.bytes(model.library.audioBytes + model.models.installedBytes))
            if let error = model.settings.lastSaveError ?? model.library.lastSaveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            Button("Delete…", role: .destructive) {
                confirmingDeleteAll = true
            }
            .disabled(nothingToDelete)
        } footer: {
            Text("Everything Clio records and transcribes stays on this phone.")
        }
        // A sheet rather than an alert: there is a choice to make before
        // there is anything to confirm, and the two destructive rows are
        // the confirmation.
        .confirmationDialog("What should Clio delete?", isPresented: $confirmingDeleteAll,
                            titleVisibility: .visible) {
            Button("Delete Recordings", role: .destructive) {
                model.library.deleteAll()
            }
            .disabled(model.library.recordings.isEmpty)
            Button("Delete Everything", role: .destructive) {
                model.library.deleteAll()
                deleteInstalledModels()
            }
        } message: {
            Text("Recordings are the audio and the transcripts. Everything is those "
                 + "and the downloaded models too — \(Format.bytes(onThisPhone)) in all. "
                 + "Your settings are kept either way, and neither can be undone.")
        }
        .alert("Not everything could be deleted",
               isPresented: .constant(deleteError != nil)) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private var onThisPhone: Int64 {
        model.library.audioBytes + model.models.installedBytes
    }

    private var nothingToDelete: Bool {
        model.library.recordings.isEmpty && model.models.installed.isEmpty
    }

    /// Every model in Clio's own folder. A model that will not go is
    /// reported rather than swallowed: the row would otherwise stay on
    /// screen with no explanation.
    private func deleteInstalledModels() {
        for installed in model.models.installed {
            do {
                try model.models.delete(installed)
            } catch {
                deleteError = error.localizedDescription
                return
            }
        }
    }

    private func countLabel(_ count: Int, _ noun: String) -> String {
        count == 0 ? "None" : "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// Where the Follow row goes, and the Mac app's repository.
    private static let follow = URL(string: "https://x.com/bartbak_")!
    private static let macApp = URL(string: "https://github.com/petit-software/clio")!

    private static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        default: return "—"
        }
    }
}

// MARK: - Header

/// The app icon with the app's name under it, at the top of Settings.
///
/// The artwork is the Mac app's export, which carries its own rounded
/// corners and anti-aliased edge, so it is drawn as is — no clip. The
/// home-screen icon is that artwork with its corners filled for iOS's own
/// mask, and clipping that back leaves a seam.
struct AppHeader: View {
    var body: some View {
        VStack(spacing: 12) {
            Image("SettingsIcon")
                .resizable()
                .interpolation(.high)
                .frame(width: 88, height: 88)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            Text("Clio")
                .font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Clio")
    }
}

// MARK: - Vocabulary

/// One term per line. Fed to the model as an initial prompt so it spells
/// names and jargon the way the user does.
struct VocabularyEditor: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .frame(minHeight: 200)
                    .autocorrectionDisabled()
            } footer: {
                Text("One term per line. Names, products, jargon — whatever "
                     + "the model keeps getting wrong.")
            }
        }
        .navigationTitle("Custom Vocabulary")
        .onAppear { text = model.settings.settings.customVocabulary.joined(separator: "\n") }
        .onChange(of: text) { _, newValue in
            model.settings.settings.customVocabulary = newValue
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }
}

// MARK: - Summary instructions

/// The system prompt the on-device model is given before it is shown a
/// transcript.
///
/// Editable because what a good summary is depends on what the recordings
/// are: a standup note and a interview want different answers. Stored empty
/// while it matches the built-in text, so improving that default reaches
/// anyone who has not written their own — which is why Reset clears the
/// field rather than pasting the default into it.
struct SummaryInstructionsEditor: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    // Tall enough that the built-in instructions are on
                    // screen whole: a prompt read half at a time is a
                    // prompt nobody edits.
                    .frame(minHeight: 340)
                    .autocorrectionDisabled()
            } footer: {
                Text("What the model is told before it is shown a transcript. "
                     + "It answers with a title and a summary either way; this "
                     + "is what shapes them.")
            }
            Section {
                Button("Reset to Default") {
                    text = SummaryPrompt.defaultInstructions
                    model.settings.settings.summaryInstructions = ""
                }
                .disabled(isDefault)
            } footer: {
                Text(isDefault
                     ? "These are the built-in instructions. Edit them and yours "
                       + "are used instead."
                     : "Yours are used. Reset puts the built-in instructions back.")
            }
        }
        .navigationTitle("Instructions")
        .onAppear {
            text = SummaryPrompt.instructions(model.settings.settings.summaryInstructions)
            loaded = true
        }
        .onChange(of: text) { _, newValue in
            // Not while the field is being filled in on appear: that would
            // write the default back as if the user had typed it.
            guard loaded else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            model.settings.settings.summaryInstructions =
                trimmed == SummaryPrompt.defaultInstructions ? "" : newValue
        }
    }

    /// Nothing of the user's own stored: the field still shows the built-in
    /// text, which is what they would be editing.
    private var isDefault: Bool {
        model.settings.settings.summaryInstructions
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Replacements

/// Whole-word, case-insensitive rules applied to every transcript.
struct ReplacementsEditor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.settings
        List {
            Section {
                ForEach($store.settings.wordReplacements) { $rule in
                    HStack {
                        TextField("Find", text: $rule.find)
                            .autocorrectionDisabled()
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                        TextField("Replace", text: $rule.replace)
                            .autocorrectionDisabled()
                    }
                }
                .onDelete { offsets in
                    store.settings.wordReplacements.remove(atOffsets: offsets)
                }
                Button("Add Rule", systemImage: "plus") {
                    store.settings.wordReplacements.append(WordReplacement())
                }
            } footer: {
                Text("Matches whole words, ignoring case. \"clio\" → \"Clio\" fixes "
                     + "the name without touching \"Clioquinol\".")
            }
        }
        .navigationTitle("Word Replacements")
    }
}

#Preview("Settings") {
    SettingsView().environment(AppModel.simulating())
}

#Preview("No Apple Intelligence") {
    SettingsView().environment(AppModel.simulating(
        summarizer: StubSummaryEngine(
            availability: .unavailable(reason: "Apple Intelligence is off. Turn it on in "
                                       + "Settings ▸ Apple Intelligence & Siri."))))
}

#Preview("Replacements") {
    var settings = Settings()
    settings.wordReplacements = [WordReplacement(find: "clio", replace: "Clio"),
                                 WordReplacement(find: "gonna", replace: "going to")]
    return NavigationStack { ReplacementsEditor() }
        .environment(AppModel.simulating(settings: settings))
}

extension View {
    /// The bars fade the content under them instead of cutting it: iOS
    /// 26's soft scroll-edge effect, on every edge.
    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(iOS 26, macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}

private extension View {
    @ViewBuilder
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
