import ClioMobileCore
import SwiftUI

#if DEBUG
/// Settings ▸ Developer: sample data for looking at the app on a phone or
/// a simulator without recording anything. Debug builds only.
struct DeveloperSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var message: String?

    /// Sections only: the Settings list's `page` puts them in its own Form.
    var body: some View {
        Group {
            Section {
                LabeledContent("Recordings", value: "\(model.library.recordings.count)")
                LabeledContent("Audio on disk", value: Format.bytes(model.library.audioBytes))
            }
            Section {
                Button("Add the 5 Sample Recordings") { add(SampleRecordings.fixed()) }
                Button("Add 24 Varied Recordings") { add(SampleRecordings.varied(count: 24)) }
                Button("Add 1 Recording, Just Now") { add(SampleRecordings.varied(count: 1)) }
            } header: {
                Text("Samples")
            } footer: {
                Text("The five are the ones the previews use. The varied set covers every "
                     + "status, both languages, typed and generated titles, summaries, "
                     + "locations, and lengths from seconds to minutes over the past month. "
                     + "Audio is a synthesized tone. Delete them in About.")
            }
            Section {
                Button("Show Intro") { AppActions.shared.pending = .showIntro }
            } footer: {
                Text("The sheet a first run gets.")
            }
            if let message {
                Section {
                    Text(message).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func add(_ recordings: [Recording]) {
        var added = 0
        for recording in recordings {
            do {
                try model.library.addSample(recording)
                added += 1
            } catch {
                message = error.localizedDescription
                return
            }
        }
        message = "Added \(added) recording\(added == 1 ? "" : "s")."
    }
}

/// Sample recordings for the Developer page. Deterministic where it
/// matters — the same button gives the same spread — with fresh ids and
/// file names each time, so nothing collides with what is there.
enum SampleRecordings {
    /// The previews' five, as new recordings.
    static func fixed() -> [Recording] {
        PreviewData.recordings.map { sample in
            var recording = sample
            recording.id = UUID()
            recording.audioFileName = "\(recording.id.uuidString).wav"
            return recording
        }
    }

    /// `count` recordings over the past month: mostly transcribed, some
    /// silent, a few failed, one still pending; English and Dutch; short
    /// and long; with and without titles, summaries and locations.
    static func varied(count: Int) -> [Recording] {
        var rng = SeededGenerator(seed: UInt64(count) &* 2_654_435_761)
        let now = Date()
        return (0..<count).map { i in
            // Spread over 30 days, newest first, a few minutes to a day apart.
            let ago = Double(i) * Double.random(in: 1_800...86_400, using: &rng)
            let createdAt = now.addingTimeInterval(-min(ago, 30 * 86_400))
            // Lengths skew short: a tone of Float32 at 16 kHz is 64 KB a second.
            let duration = [4.0, 9, 17, 31, 46, 58, 75, 102, 128, 184][Int.random(in: 0..<10, using: &rng)]
            let english = Int.random(in: 0..<4, using: &rng) != 0
            let text = english ? englishTexts[i % englishTexts.count] : dutchTexts[i % dutchTexts.count]
            let roll = Int.random(in: 0..<12, using: &rng)
            var recording = Recording(createdAt: createdAt, duration: duration)
            switch roll {
            case 0:
                recording.status = .nothingHeard
                recording.duration = min(duration, 6)
            case 1:
                recording.status = .failed("The transcription model is not loaded yet.")
            case 2 where i == 0:
                recording.status = .pending
            default:
                recording.status = .transcribed
                recording.transcript = text.body
                recording.language = english ? "en" : "nl"
                recording.modelID = "openai_whisper-small_216MB"
                recording.segments = segments(for: text.body, duration: duration)
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: recording.title = text.title
                case 1: recording.generatedTitle = text.title
                default: break
                }
                if Bool.random(using: &rng) { recording.summary = text.summary }
                if Int.random(in: 0..<3, using: &rng) == 0 {
                    recording.location = places[Int.random(in: 0..<places.count, using: &rng)]
                }
            }
            return recording
        }
    }

    /// The transcript cut into sentences, spread evenly over the clip.
    private static func segments(for text: String, duration: TimeInterval) -> [TranscriptSegment] {
        let sentences = text.split(separator: ". ").map(String.init)
        guard !sentences.isEmpty else { return [] }
        let each = duration / Double(sentences.count)
        return sentences.enumerated().map { index, sentence in
            let body = sentence.hasSuffix(".") ? sentence : sentence + "."
            return TranscriptSegment(start: Double(index) * each,
                                     end: Double(index + 1) * each - 0.2,
                                     text: body)
        }
    }

    private struct Text { let title: String; let summary: String; let body: String }

    private static let englishTexts: [Text] = [
        Text(title: "Groceries and the plumber",
             summary: "Buy milk, eggs and coffee; the plumber comes Tuesday at nine.",
             body: "Milk, eggs, coffee, and the good bread from the place on the corner. "
               + "The plumber said Tuesday at nine, so somebody has to be home. "
               + "Ask him about the pressure in the upstairs shower while he is here."),
        Text(title: "Book idea",
             summary: "A novel told through voice memos left for a sister who never listens to them.",
             body: "What if the whole thing is voice memos. She leaves them for her sister "
               + "and the sister never plays them, and we only find that out at the end. "
               + "The reader has heard everything the sister has not."),
        Text(title: "Feedback for the team",
             summary: "The demo went well; the onboarding copy and the empty states need work before Friday.",
             body: "The demo went better than I expected. Two things before Friday. "
               + "The onboarding copy still reads like a spec, and the empty states are "
               + "blank white screens. Both are a day's work if we start tomorrow."),
        Text(title: "Directions to the cabin",
             summary: "Take the second left after the bridge, then the gravel road to the red gate.",
             body: "After the bridge take the second left, not the first, the first is a "
               + "driveway. Follow the gravel road for about two kilometres until you see "
               + "a red gate on the right. The key is under the third pot."),
        Text(title: "Dentist and the invoice",
             summary: "Move the dentist to Thursday and check whether the March invoice was sent.",
             body: "Remember to move the dentist appointment to Thursday, and ask whether "
               + "the invoice for March was ever sent. Also the balcony door still sticks "
               + "in the heat."),
    ]

    private static let dutchTexts: [Text] = [
        Text(title: "Idee voor de tuin",
             summary: "Met de schutting een meter naar achteren past er een kleine kas naast de schuur.",
             body: "Als we de schutting een meter naar achteren zetten past er een kleine "
               + "kas naast de schuur. Dan kunnen de tomaten eindelijk buiten de keuken."),
        Text(title: "Boodschap voor Jan",
             summary: "Jan moet de sleutel van de garage terugbrengen voor zaterdag.",
             body: "Jan, vergeet niet de sleutel van de garage terug te brengen voor "
               + "zaterdag. We hebben hem nodig voor de verhuizing van de kast."),
        Text(title: "Wat ik tegen de huisarts wil zeggen",
             summary: "Sinds drie weken hoofdpijn in de ochtend, meestal weg na de koffie.",
             body: "Sinds een week of drie heb ik hoofdpijn in de ochtend. Meestal is het "
               + "weg na de koffie, maar niet altijd. Ik slaap wel gewoon goed."),
    ]

    private static let places: [RecordingLocation] = [
        RecordingLocation(latitude: 52.3702, longitude: 4.8912, placeName: "Prinsengracht, Amsterdam"),
        RecordingLocation(latitude: 52.0907, longitude: 5.1214, placeName: "Oudegracht, Utrecht"),
        RecordingLocation(latitude: 51.9244, longitude: 4.4777, placeName: "Witte de Withstraat, Rotterdam"),
        RecordingLocation(latitude: 52.3676, longitude: 4.9041),
    ]
}

/// A small deterministic generator, so the varied set is the same each
/// time and a screenshot can be repeated.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
#endif
