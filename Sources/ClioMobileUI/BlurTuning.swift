#if DEBUG
import ClioMobileCore
import SwiftUI

/// Live controls for the progressive blur under the wash, for tuning it
/// on a phone and reading the numbers off: Settings ▸ Developer ▸ Blur
/// controls puts a card of sliders over the list. Debug builds only; the
/// chosen values are then written into `WashBlur` by hand and this stays
/// out of the way. The values persist in UserDefaults so a relaunch keeps
/// the last tuning.
@MainActor
@Observable
final class BlurTuning {
    static let shared = BlurTuning()

    var showing: Bool { didSet { defaults.set(showing, forKey: "blur.showing") } }
    /// Radius at the screen edge, in points.
    var maximumRadius: Double { didSet { defaults.set(maximumRadius, forKey: "blur.max") } }
    /// Radius at the top of the blur, in points. Above zero keeps a haze
    /// the whole way up.
    var minimumRadius: Double { didSet { defaults.set(minimumRadius, forKey: "blur.min") } }
    /// Where, as a fraction of the height from the bottom, the full radius
    /// is reached; the rest stays at full blur.
    var radiusInset: Double { didSet { defaults.set(radiusInset, forKey: "blur.inset") } }
    /// The dimming tint's opacity at the bottom, light and dark.
    var dimmingLight: Double { didSet { defaults.set(dimmingLight, forKey: "blur.dimLight") } }
    var dimmingDark: Double { didSet { defaults.set(dimmingDark, forKey: "blur.dimDark") } }
    /// How far past the top the dimming's clear end is stretched, as a
    /// fraction of the height.
    var clearExtension: Double { didSet { defaults.set(clearExtension, forKey: "blur.clear") } }
    /// Where the dimming reaches full colour, as a fraction from the bottom.
    var fullColorInset: Double { didSet { defaults.set(fullColorInset, forKey: "blur.full") } }
    /// Points added above the wash's own height, so the blur can start
    /// higher than the colour does.
    var extraHeight: Double { didSet { defaults.set(extraHeight, forKey: "blur.extra") } }
    /// How much stronger everything is while a held recording runs.
    var heldBoost: Double { didSet { defaults.set(heldBoost, forKey: "blur.held") } }

    private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        func value(_ key: String, _ fallback: Double) -> Double {
            d.object(forKey: key) == nil ? fallback : d.double(forKey: key)
        }
        showing = d.bool(forKey: "blur.showing")
        maximumRadius = value("blur.max", 10)
        minimumRadius = value("blur.min", 0)
        radiusInset = value("blur.inset", 0)
        dimmingLight = value("blur.dimLight", 0.35)
        dimmingDark = value("blur.dimDark", 0.2)
        clearExtension = value("blur.clear", 0.25)
        fullColorInset = value("blur.full", 0)
        extraHeight = value("blur.extra", 0)
        heldBoost = value("blur.held", 1.6)
    }

    /// The numbers, one per line, to paste back.
    var summary: String {
        """
        maximumRadius \(f(maximumRadius))
        minimumRadius \(f(minimumRadius))
        radiusInset \(f(radiusInset))
        dimmingLight \(f(dimmingLight))
        dimmingDark \(f(dimmingDark))
        clearExtension \(f(clearExtension))
        fullColorInset \(f(fullColorInset))
        extraHeight \(f(extraHeight))
        heldBoost \(f(heldBoost))
        """
    }

    private func f(_ v: Double) -> String { String(format: "%.2f", v) }

    func reset() {
        maximumRadius = 10; minimumRadius = 0; radiusInset = 0
        dimmingLight = 0.35; dimmingDark = 0.2; clearExtension = 0.25; fullColorInset = 0
        extraHeight = 0; heldBoost = 1.6
    }
}

/// The card of sliders. Sits at the top of the screen over the list, so
/// the blur at the bottom is in view while it is tuned.
struct BlurTuningPanel: View {
    @Bindable private var tuning = BlurTuning.shared
    @State private var copied = false

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Blur").font(.headline)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    Clipboard.copy(tuning.summary)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                }
                Button("Reset") { tuning.reset() }
                Button("Close", systemImage: "xmark") { tuning.showing = false }
                    .labelStyle(.iconOnly)
            }
            .font(.footnote.weight(.medium))
            slider("Max radius", $tuning.maximumRadius, 0...40)
            slider("Min radius", $tuning.minimumRadius, 0...20)
            slider("Radius inset", $tuning.radiusInset, 0...1)
            slider("Dim light", $tuning.dimmingLight, 0...1)
            slider("Dim dark", $tuning.dimmingDark, 0...1)
            slider("Clear extension", $tuning.clearExtension, 0...1)
            slider("Full colour inset", $tuning.fullColorInset, 0...1)
            slider("Extra height", $tuning.extraHeight, 0...400)
            slider("Held boost", $tuning.heldBoost, 0.5...3)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
        .font(.caption)
    }

    private func slider(_ name: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(name).frame(width: 96, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }
}
#endif
