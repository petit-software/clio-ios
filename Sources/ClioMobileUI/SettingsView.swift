import AppIntents
import ClioMobileActivity
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
    /// Which minus was pressed; nil is no alert up.
    @State private var deleting: DeleteScope?
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
                    NavigationLink("Models", value: SettingsPage.model)
                } footer: {
                    Text("Which Whisper model transcribes and which language model writes "
                         + "summaries; downloading and deleting them.")
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
                    page("Recording",
                         value: RecordingLimit.label(seconds: store.settings.maxRecordingSeconds)) {
                        recordingSection(store)
                    }
                } footer: {
                    Text("The length cap, silence detection, haptics, and location.")
                }
                Section {
                    page("Intelligence", value: intelligenceSummary(store)) {
                        intelligenceSection(store)
                    }
                } footer: {
                    Text("Titles and summaries, written on the phone by Apple Intelligence "
                         + "or a downloaded model, and how they read.")
                }
                Section {
                    page("Siri & Action Button", value: "Record") {
                        shortcutsSection
                    }
                } footer: {
                    Text("Start a recording by voice, from the Shortcuts app, or with "
                         + "the Action button.")
                }
                Section {
                    Picker("Appearance", selection: Binding(
                        get: { store.settings.appearance },
                        set: { store.settings.appearance = $0 })) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .greyMenu()
                } footer: {
                    Text("Light, dark, or whatever the phone is set to.")
                }
                Section {
                    page("Storage", value: Format.bytes(onThisPhone)) {
                        storageSection
                    }
                } footer: {
                    Text("What Clio is keeping on this phone, and how to remove it.")
                }
                Section {
                    LabeledContent("Version", value: Self.version)
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
                    // Neutral: the glyph in the text colour, no tint at all.
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.primary)
                    }
                    .buttonStyle(.plain)
                    .tint(.primary)
                    .accessibilityLabel("Close")
                }
            }
        }
        // Every toggle, slider and stepper on these pages in the app's
        // colour: the lime, darker on light.  Explicit, not left to the
        // catalog's global accent.
        .tint(Color.accentColor)
    }

    // MARK: Rows and pages

    /// A row that opens a page holding one of the sections below.
    private func page<Content: View>(_ title: String, value: String,
                                     @ViewBuilder content: @escaping () -> Content) -> some View {
        NavigationLink {
            Form { content() }
                .navigationTitle(title)
                .softScrollEdges()
        } label: {
            LabeledContent(title, value: value)
        }
    }

    private func textSummary(_ store: SettingsStore) -> String {
        var on: [String] = []
        if store.settings.capitalizeFirstLetter { on.append("Capitalize") }
        if store.settings.trimTrailingPunctuation { on.append("Trim") }
        return on.isEmpty ? "As spoken" : on.joined(separator: ", ")
    }

    private func intelligenceSummary(_ store: SettingsStore) -> String {
        guard model.intelligence.availability.isAvailable else { return "Unavailable" }
        guard store.settings.generateSummaries else { return "Off" }
        switch store.settings.summaryModel {
        case .apple: return "Apple Intelligence"
        case .local(let id): return model.languageModels.displayName(for: id)
        }
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
            .greyMenu()
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
            Toggle("Skip silent recordings", isOn: Binding(
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
            // Hold to record and its live preview stay in Settings and in
            // the code, but are not offered here for now.
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
            Text("A recording with no speech in it is marked as nothing heard "
                 + "instead of transcribed. Higher sensitivity counts quieter sounds "
                 + "as speech.")
        }
    }

    @ViewBuilder
    private func intelligenceSection(_ store: SettingsStore) -> some View {
        let availability = model.intelligence.availability
        Section {
            Toggle("Titles and summaries", isOn: Binding(
                get: { store.settings.generateSummaries },
                set: { store.settings.generateSummaries = $0 }))
            if let reason = availability.reason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        } footer: {
            Text(availability.isAvailable
                 ? "After each transcription a language model on this phone writes a "
                   + "title and a summary. Which one is chosen in Settings ▸ Models. "
                   + "The transcript never leaves the phone."
                 : "A title and a summary for each recording, written on the phone by "
                   + "Apple Intelligence or by a model downloaded in Settings ▸ Models.")
        }
        // How the summary reads. Read by every path that writes one — the
        // first summary and Summarize Again alike — at the moment it runs.
        Section {
            Picker("Note type", selection: Binding(
                get: { store.settings.summaryPreferences.noteType },
                set: { store.settings.summaryPreferences.noteType = $0 })) {
                ForEach(NoteType.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .greyMenu()
            Picker("Format", selection: Binding(
                get: { store.settings.summaryPreferences.format },
                set: { store.settings.summaryPreferences.format = $0 })) {
                ForEach(SummaryFormat.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .greyMenu()
            Picker("Length", selection: Binding(
                get: { store.settings.summaryPreferences.length },
                set: { store.settings.summaryPreferences.length = $0 })) {
                ForEach(SummaryLength.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .greyMenu()
        } header: {
            Text("Summaries")
        } footer: {
            Text("Applies to the next summary, and to Summarize Again on an existing "
                 + "recording. The transcript is not changed.")
        }
        // The user's additions to the prompt: "name who spoke", "answer in
        // Dutch", "skip the small talk". Bound straight to the setting, so
        // what is typed here is what the next summary — or Summarize Again
        // — is asked for, the moment it is asked.
        Section {
            TextEditor(text: Binding(
                get: { store.settings.summaryPreferences.instructions },
                set: { store.settings.summaryPreferences.instructions = $0 }))
                .frame(minHeight: 120)
        } header: {
            Text("Custom instructions")
        } footer: {
            Text("Added to every summary, and to Summarize Again. The summary still "
                 + "sticks to what was said. Leave it empty for none.")
        }
    }

    /// What is on disk and how to get rid of it. Its own page: deleting
    /// every recording is not a thing anybody goes to About looking for,
    /// and neither are the sizes it used to sit under.
    /// The one shortcut, and how to put it where the user wants it. The
    /// tip and the link are Apple's own views; the Action button has no
    /// URL an app may open, so that part is directions.
    @ViewBuilder
    private var shortcutsSection: some View {
        #if os(iOS)
        Section {
            SiriTipView(intent: StartRecordingIntent())
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        } footer: {
            Text("Say it to Siri. Clio opens and starts recording.")
        }
        Section {
            ShortcutsLink()
                .shortcutsLinkStyle(.automaticOutline)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        } footer: {
            Text("\"Record\" is in the Shortcuts app under Clio, to run on its own "
                 + "or inside a shortcut of your own.")
        }
        #endif
        Section("Action button") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Open Settings ▸ Action Button, choose Shortcut, then Clio ▸ Record.")
                Text("Pressing and holding the Action button then opens Clio and "
                     + "starts recording. The phone asks for its unlock first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var storageSection: some View {
        Section {
            storageRow(.recordings,
                       "\(model.library.recordings.count) · \(Format.bytes(model.library.audioBytes))",
                       enabled: !model.library.recordings.isEmpty)
            storageRow(.models,
                       "\(model.models.installed.count + model.languageModels.installed.count) · "
                       + Format.bytes(model.models.installedBytes + model.languageModels.installedBytes),
                       enabled: !(model.models.installed.isEmpty && model.languageModels.installed.isEmpty))
            storageRow(.everything, Format.bytes(onThisPhone), enabled: !nothingToDelete)
            if let error = model.settings.lastSaveError ?? model.library.lastSaveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
        } header: {
            Text("Usage")
        } footer: {
            Text("Everything Clio records and transcribes stays on this phone. "
                 + "The minus on a row removes what that row counts; your settings "
                 + "are kept whichever one you use.")
        }
        // One plain alert, whatever the row: the row has already said what
        // is going, so there is a single thing to say yes or no to.
        .alert(deleting?.prompt ?? "", isPresented: deletingIsPresented, presenting: deleting) { scope in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { delete(scope) }
        } message: { scope in
            Text(scope.message(size: Format.bytes(size(of: scope))))
        }
        .alert("Not everything could be deleted",
               isPresented: .constant(deleteError != nil)) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    /// A count on the left, its size on the right, and a minus that takes
    /// it away — the copy button's shape, in the place the eye already
    /// goes for a value.
    private func storageRow(_ scope: DeleteScope, _ value: String,
                            enabled: Bool) -> some View {
        HStack {
            Text(scope.title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
            Button(scope.prompt, systemImage: "minus.circle.fill") {
                deleting = scope
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.25)
        }
    }

    /// What a minus takes away. Three scopes, one per row, rather than one
    /// button and a sheet asking which — the row is the answer.
    enum DeleteScope: Identifiable {
        case recordings, models, everything

        var id: Self { self }

        var title: String {
            switch self {
            case .recordings: "Recordings"
            case .models: "Models"
            case .everything: "Everything"
            }
        }

        var prompt: String {
            switch self {
            case .recordings: "Delete every recording?"
            case .models: "Delete the downloaded models?"
            case .everything: "Delete everything on this phone?"
            }
        }

        func message(size: String) -> String {
            switch self {
            case .recordings:
                "The audio and the transcripts, \(size) in all. This cannot be undone."
            case .models:
                "\(size) of downloaded models, Whisper and language models alike. Nothing "
                + "is transcribed or summarized until one is downloaded again; your "
                + "recordings are kept."
            case .everything:
                "Every recording and every downloaded model, \(size) in all. Your "
                + "settings are kept. This cannot be undone."
            }
        }
    }

    private var deletingIsPresented: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func size(of scope: DeleteScope) -> Int64 {
        switch scope {
        case .recordings: model.library.audioBytes
        case .models: model.models.installedBytes + model.languageModels.installedBytes
        case .everything: onThisPhone
        }
    }

    private func delete(_ scope: DeleteScope) {
        switch scope {
        case .recordings:
            model.library.deleteAll()
        case .models:
            deleteInstalledModels()
        case .everything:
            model.library.deleteAll()
            deleteInstalledModels()
        }
        deleting = nil
    }

    private var onThisPhone: Int64 {
        model.library.audioBytes + model.models.installedBytes + model.languageModels.installedBytes
    }

    private var nothingToDelete: Bool {
        model.library.recordings.isEmpty && model.models.installed.isEmpty
            && model.languageModels.installed.isEmpty
    }

    /// Every model in Clio's own folder. A model that will not go is
    /// reported rather than swallowed: the row would otherwise stay on
    /// screen with no explanation.
    private func deleteInstalledModels() {
        for manager in [model.models, model.languageModels] {
            for installed in manager.installed {
                do {
                    try manager.delete(installed)
                } catch {
                    deleteError = error.localizedDescription
                    return
                }
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
        // The mark, light grey, as on the intro and the empty library.
        Image("IntroMark")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 44)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
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
        .softScrollEdges()
        .onAppear { text = model.settings.settings.customVocabulary.joined(separator: "\n") }
        .onChange(of: text) { _, newValue in
            model.settings.settings.customVocabulary = newValue
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
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
        .softScrollEdges()
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
    /// A menu picker's value and chevrons in grey, not the accent blue:
    /// a setting's current value is information, not a link.
    func greyMenu() -> some View {
        tint(.secondary)
    }

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
