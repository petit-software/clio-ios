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
    /// The points' glyphs: the given 24-point drawings, six points up.
    static let glyphSize: CGFloat = 30
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
                              "Capture thoughts, meetings, and conversations.") {
                            RecordGlyph()
                        }
                        point("Turn speech into text",
                              "Get readable transcripts from your recordings.") {
                            Image("IntroChat")
                                .resizable()
                                .frame(width: Self.glyphSize, height: Self.glyphSize)
                        }
                        point("Summarize your way",
                              "Create summaries with your preferred format.") {
                            // The thinking head, as given, from the catalog.
                            Image("IntroThink")
                                .resizable()
                                .frame(width: Self.glyphSize, height: Self.glyphSize)
                        }
                        point("Everything stays private on your device",
                              "Audio, transcripts, and summaries never leave it.") {
                            Image("IntroLock")
                                .resizable()
                                .frame(width: Self.glyphSize, height: Self.glyphSize)
                        }
                        // The one thing to do before the first recording,
                        // with the Models page's own control at the end.
                        if let whisperSmall {
                            HStack(alignment: .center, spacing: 16) {
                                point("Download a model",
                                      "Whisper Small, \(Format.bytes(whisperSmall.approximateBytes)), once.") {
                                    Image("IntroModel")
                                        .resizable()
                                        .frame(width: Self.glyphSize, height: Self.glyphSize)
                                }
                                Spacer(minLength: 8)
                                ModelActionSlot(entry: whisperSmall, manager: model.models,
                                                isActive: model.capture.activeModel?.id == whisperSmall.id)
                                    .frame(width: ModelRow.slot, height: ModelRow.slot)
                            }
                            .padding(16)
                            .background(Color.secondary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            // Out past the list's edges by its own inset, so
                            // the glyph inside lines up with the ones above.
                            .padding(.horizontal, -16)
                        }
                    }
                    .padding(.horizontal, 8)
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

    private func point<Glyph: View>(_ title: LocalizedStringKey, _ text: LocalizedStringKey,
                                    @ViewBuilder glyph: () -> Glyph) -> some View {
        HStack(alignment: .top, spacing: 16) {
            glyph()
                .font(.system(size: Self.glyphSize - 2))
                .foregroundStyle(.tint)
                .frame(width: Self.glyphSize + 12, height: Self.glyphSize + 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// The record glyph as given: a ring with a dot, on a 24-point grid — the
/// ring's stroke a twelfth of the box, the dot a third of it. Drawn, not
/// an asset, so it takes the tint like the symbols beside it.
struct RecordGlyph: View {
    var size: CGFloat = IntroView.glyphSize

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .strokeBorder(lineWidth: side / 12)
                    .frame(width: side * 20 / 24, height: side * 20 / 24)
                Circle()
                    .frame(width: side / 3, height: side / 3)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(width: size, height: size)
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
