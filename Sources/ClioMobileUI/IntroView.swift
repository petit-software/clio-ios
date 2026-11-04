import ClioMobileCore
import SwiftUI

/// The first run: what Clio is, in a sheet over the library. The icon and
/// name as in Settings, three things worth knowing, and Whisper Small to
/// download — the same row as on Settings ▸ Models. Continue waits for a
/// model: nothing can be transcribed without one, so the sheet does not
/// go until one is installed, and it cannot be swiped away.
struct IntroView: View {
    var onContinue: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    /// Any Whisper model on the phone will do; Small is the one offered.
    private var hasModel: Bool { !model.models.installed.isEmpty }
    private var whisperSmall: CatalogModel? {
        model.models.catalog.first { $0.id == ModelCatalog.defaultModelID }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 28) {
                    AppHeader(hairline: true)
                        .padding(.top, 64)
                    Text("Record, transcribe, and summarize what matters.")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    VStack(alignment: .leading, spacing: 22) {
                        point("Record with ease",
                              "Capture thoughts, meetings, and conversations.")
                        point("Turn speech into text",
                              "Get readable transcripts from your recordings.")
                        point("Summarize your way",
                              "Create summaries with your preferred format.")
                    }
                    .padding(.horizontal, 8)
                    if let whisperSmall {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Download a model to start")
                                .font(.headline)
                            ModelRow(entry: whisperSmall, manager: model.models,
                                     isActive: model.capture.activeModel?.id == whisperSmall.id,
                                     busy: model.capture.state.isBusy) {}
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(Color.secondary.opacity(0.1),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            Text("Transcription runs on this phone. Audio and text never leave it.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            // Black in light mode, white in dark, like the record button.
            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .background(colorScheme == .dark ? Color.white : Color.black,
                        in: Capsule(style: .continuous))
            .disabled(!hasModel)
            .opacity(hasModel ? 1 : 0.4)
            .animation(.default, value: hasModel)
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(!hasModel)
    }

    private func point(_ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("No model yet") {
    Text("Library").sheet(isPresented: .constant(true)) { IntroView {} }
        .environment(AppModel.simulating(models: .simulating(layout: .whisper)))
}

#Preview("Model installed") {
    Text("Library").sheet(isPresented: .constant(true)) { IntroView {} }
        .environment(AppModel.simulating())
}
