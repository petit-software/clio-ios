import ClioMobileCore
import SwiftUI

/// Settings, as a grouped form. Every control binds straight to the one
/// `Settings` struct; the store debounces the writes.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeleteAll = false

    var body: some View {
        @Bindable var store = model.settings
        NavigationStack {
            Form {
                modelSection
                transcriptionSection(store)
                textSection(store)
                recordingSection(store)
                intelligenceSection(store)
                aboutSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Sections

    private var modelSection: some View {
        ModelSection()
    }

    private func transcriptionSection(_ store: SettingsStore) -> some View {
        Section("Transcription") {
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
        Section("Text") {
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
        } header: {
            Text("Recording")
        } footer: {
            Text("Silence at the start and end of a recording is cut before "
                 + "transcription. Higher sensitivity keeps quieter speech.")
        }
    }

    private func intelligenceSection(_ store: SettingsStore) -> some View {
        let availability = model.intelligence.availability
        return Section {
            Toggle("Titles and summaries", isOn: Binding(
                get: { store.settings.generateSummaries },
                set: { store.settings.generateSummaries = $0 }))
            if let reason = availability.reason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        } header: {
            Text("Intelligence")
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
            if let error = model.settings.lastSaveError ?? model.library.lastSaveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            Button("Delete All Recordings", role: .destructive) {
                confirmingDeleteAll = true
            }
            .disabled(model.library.recordings.isEmpty)
        } header: {
            Text("About")
        } footer: {
            Text("Everything Clio records and transcribes stays on this phone.")
        }
        .confirmationDialog("Delete every recording?", isPresented: $confirmingDeleteAll,
                            titleVisibility: .visible) {
            Button("Delete All Recordings", role: .destructive) {
                model.library.deleteAll()
            }
        } message: {
            Text("This removes all audio and transcripts from this phone. It cannot be undone.")
        }
    }

    private func countLabel(_ count: Int, _ noun: String) -> String {
        count == 0 ? "None" : "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

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
