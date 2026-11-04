import AppIntents
import ClioMobileActivity

/// What Siri, Spotlight, the Shortcuts app and the Action button offer
/// without setup: one shortcut, "Record with Clio". The phrases must name
/// the app, which is what `applicationName` stands for.
///
/// This has to be in the app target. It once lived in ClioMobileUI, built
/// without a word, and the app's intent metadata came out with no
/// shortcuts at all: the metadata extractor only reads a provider from
/// the app itself. The intent it names, `StartRecordingIntent`, stays in
/// ClioMobileActivity so the widget's control can share it.
struct ClioShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Record with \(.applicationName)",
                "Start a \(.applicationName) recording",
                "New \(.applicationName) recording",
            ],
            shortTitle: "Record",
            systemImageName: "mic.fill")
    }

    static let shortcutTileColor: ShortcutTileColor = .lime
}
