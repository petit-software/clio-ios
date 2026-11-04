import ClioMobileCore
import SwiftUI

/// The first run: what Clio is, in a sheet over the library. The icon and
/// name as in Settings, the handful of things worth knowing, Continue.
struct IntroView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 28) {
                    AppHeader()
                        .padding(.top, 36)
                    Text("Speech becomes text on this phone.")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    VStack(alignment: .leading, spacing: 22) {
                        point("waveform", "Record and transcribe",
                              "Whisper runs on this phone's Neural Engine. Audio and text never leave it.")
                        point("sparkles", "Titles and summaries",
                              "Written on the phone by Apple Intelligence, or by a model you download.")
                        point("hand.tap", "Tap a sentence",
                              "Playback jumps to the moment it was said.")
                        point("hand.point.up.left", "Hold to record",
                              "Turn it on in Settings and the button records while your finger is on it.")
                        point("arrow.down.circle", "Download a model first",
                              "Whisper Small is 217 MB, once. Larger ones are a tap away.")
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
        .presentationDragIndicator(.visible)
    }

    private func point(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    Text("Library").sheet(isPresented: .constant(true)) { IntroView {} }
}
