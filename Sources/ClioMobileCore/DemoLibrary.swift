import Foundation

/// Sample recordings for showing the app: a dozen memos that read as real,
/// with transcripts, titles the model would write, summaries in the shape
/// the prompt asks for, places, and segments so the transcript is a
/// paragraph of tappable sentences — and no audio, so nothing plays.
/// Dates are relative to now so the list groups them as Today, Yesterday
/// and the days before. `Settings.demoMode` puts them in place of the
/// library; see `RecordingStore.useDemo`.
public enum DemoLibrary {

    public static var recordings: [Recording] {
        let now = Date()
        return entries.enumerated().map { index, entry in
            let createdAt = now.addingTimeInterval(-entry.ago)
            let words = entry.transcript.split(whereSeparator: { $0.isWhitespace }).count
            // Spoken at about 150 words a minute, with the pauses people leave.
            let duration = max(8, Double(words) / 2.4 + 3)
            var recording = Recording(
                id: UUID(uuidString: String(format: "D0000000-0000-4000-8000-%012d", index + 1))!,
                createdAt: createdAt,
                duration: duration,
                title: entry.typedTitle ?? "",
                transcript: entry.transcript,
                language: entry.language,
                modelID: "openai_whisper-small_216MB",
                summary: entry.summary,
                generatedTitle: entry.generatedTitle,
                segments: segments(entry.transcript, duration: duration),
                location: entry.place)
            recording.audioFileName = "demo-\(index + 1).wav"
            return recording
        }
    }

    /// The transcript cut at its sentences, spread over the clip.
    static func segments(_ text: String, duration: TimeInterval) -> [TranscriptSegment] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?".contains(character) {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            sentences.append(current.trimmingCharacters(in: .whitespaces))
        }
        let total = sentences.reduce(0) { $0 + $1.count }
        var start = 0.6
        return sentences.map { sentence in
            let share = (duration - 1.2) * Double(sentence.count) / Double(max(total, 1))
            let segment = TranscriptSegment(start: start, end: start + share - 0.15, text: sentence)
            start += share
            return segment
        }
    }

    struct Entry {
        var ago: TimeInterval
        var transcript: String
        var summary: String?
        var generatedTitle: String?
        var typedTitle: String?
        var language: String = "en"
        var place: RecordingLocation?
    }

    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400

    static let entries: [Entry] = [
        Entry(ago: 40 * 60,
              transcript: "Okay, notes from the call with Priya. She's fine with moving the launch to the twenty-third as long as the pricing page is ready a week before. She asked whether we'd keep the annual plan at the old price for existing customers, and I said I'd check with Tom, so that's open. She also wants a short video for the announcement, under a minute. Action for me, send her the pricing draft by Thursday.",
              summary: "Priya agrees to move the launch to the 23rd if the pricing page is ready a week before. Whether existing customers keep the annual plan at the old price is open; the speaker will check with Tom. Priya wants an announcement video under a minute. The speaker will send her the pricing draft by Thursday.",
              generatedTitle: "Launch call with Priya",
              place: RecordingLocation(latitude: 52.3730, longitude: 4.8924, placeName: "Herengracht, Amsterdam")),
        Entry(ago: 3 * hour,
              transcript: "Shopping for tonight. Two chicken thighs, the skin-on ones. Lemons, three. A bunch of parsley, garlic, we have rice. And something for breakfast, yoghurt and the granola from the corner place. Oh and candles, the thin ones.",
              summary: "Groceries for tonight: two skin-on chicken thighs, three lemons, parsley, garlic. Rice is at home. For breakfast, yoghurt and granola from the corner place. Also thin candles.",
              generatedTitle: "Groceries for tonight"),
        Entry(ago: 6 * hour,
              transcript: "Idea for the book. What if chapter four opens in the hospital, not the house, and we only learn later that the house burned. The reader would think the fire is the ending when it's actually the beginning. That means cutting the long scene with the neighbour, which I like, but it slows everything down. Try it on paper before deciding.",
              summary: "Open chapter four in the hospital rather than the house, revealing the fire later so it reads as the beginning rather than the ending. That would mean cutting the neighbour scene, which the speaker likes but finds slow. Try the change on paper before deciding.",
              generatedTitle: "Chapter four opening idea"),
        Entry(ago: day + 2 * hour,
              transcript: "Standup. Migration ran clean on staging overnight. Two flaky tests in the payment suite, both timing, Ines is looking at them. Nobody has touched the onboarding copy yet, that's on me for tomorrow before the review. Deploy is still planned for Friday afternoon unless the tests keep failing.",
              summary: "The migration ran clean on staging overnight. Two flaky, timing-related tests in the payment suite; Ines is on them. The onboarding copy is untouched and the speaker will do it tomorrow before the review. Deploy stays planned for Friday afternoon unless the tests keep failing.",
              generatedTitle: "Standup notes",
              typedTitle: "Standup, Tuesday"),
        Entry(ago: day + 9 * hour,
              transcript: "Note to self after the dentist. Next appointment in six months, she said the back left molar is fine for now but to come in sooner if it gets sensitive to cold again. Floss, apparently I'm not doing it enough. Ask the insurance whether the night guard is covered before ordering it.",
              summary: "Next dentist appointment in six months. The back left molar is fine for now; come in sooner if it gets sensitive to cold again. Floss more. Check with the insurance whether the night guard is covered before ordering it.",
              generatedTitle: "After the dentist"),
        Entry(ago: 2 * day + 5 * hour,
              transcript: "Even een notitie over het huis. De makelaar belde, de bezichtiging is zaterdag om elf uur, niet tien. We moeten de sleutel van de schuur nog vinden, die lag volgens mij in de la bij de voordeur. En vraag of de wasmachine bij de koop zit, dat stond niet in de brochure.",
              summary: "De bezichtiging is zaterdag om elf uur, niet tien. De sleutel van de schuur moet nog gevonden worden, vermoedelijk in de la bij de voordeur. Vragen of de wasmachine bij de koop zit; dat stond niet in de brochure.",
              generatedTitle: "Bezichtiging zaterdag",
              language: "nl",
              place: RecordingLocation(latitude: 52.0907, longitude: 5.1214, placeName: "Oudegracht, Utrecht")),
        Entry(ago: 3 * day + hour,
              transcript: "Thinking about the talk. The point isn't that local models are good, it's that they're good enough for the boring tasks, and the boring tasks are most of the work. Open with the demo, not the slides. Three examples max. If there's time, the bit about the phone transcribing in a tunnel with no signal, people like that.",
              summary: "The talk's point: local models are good enough for the boring tasks, which are most of the work. Open with the demo rather than slides, keep to three examples, and if time allows include the example of the phone transcribing in a tunnel with no signal.",
              generatedTitle: "Talk outline"),
        Entry(ago: 3 * day + 7 * hour,
              transcript: "Feedback for Marco on the draft. The intro is strong, keep it. Section two repeats the problem statement from section one, cut one of them. The chart on page four needs the axis labelled, I couldn't tell if that was weeks or months. And the conclusion promises a follow-up study we haven't agreed to, so soften that or take it out.",
              summary: "Keep the strong intro. Section two repeats section one's problem statement; cut one. The chart on page four needs its axis labelled. The conclusion promises a follow-up study that has not been agreed; soften or remove it.",
              generatedTitle: "Feedback on Marco's draft"),
        Entry(ago: 5 * day + 3 * hour,
              transcript: "Directions for Saturday. Take the exit after the bridge, then the second left, not the first, the first is somebody's driveway. Follow the gravel road about two kilometres until the red gate on the right. The key is under the third pot from the door. Phone signal is bad there so screenshot this.",
              summary: "Take the exit after the bridge, then the second left. Follow the gravel road about two kilometres to the red gate on the right. The key is under the third pot from the door. Phone signal is bad there, so keep a screenshot.",
              generatedTitle: "Directions to the cabin",
              typedTitle: "Cabin directions"),
        Entry(ago: 6 * day + 4 * hour,
              transcript: "Quick one. Renew the passport, it expires in March and the trip is in April. The photo place on the high street does them in ten minutes. Also the car, the inspection letter said before the end of the month, so book that this week.",
              summary: "Renew the passport before the April trip; it expires in March, and the high street photo place does photos in ten minutes. Book the car inspection this week, before the end of the month.",
              generatedTitle: "Passport and car inspection"),
        Entry(ago: 9 * day + 6 * hour,
              transcript: "Interview notes, candidate two. Strong on the systems side, walked through the caching problem well and asked good questions about the on-call setup. Less clear on how she'd handle a disagreement with a product lead, the answer was general. I'd move her forward to the team round. Compare with candidate one on Friday.",
              summary: "Candidate two is strong on systems, handled the caching problem well and asked good questions about on-call. Her answer on handling a disagreement with a product lead was general. The speaker would move her to the team round and compare with candidate one on Friday.",
              generatedTitle: "Interview, candidate two",
              place: RecordingLocation(latitude: 52.3340, longitude: 4.8732, placeName: "Zuidas, Amsterdam")),
        Entry(ago: 12 * day + 2 * hour,
              transcript: "Garden. The fence can go back a metre, the neighbour's fine with it, so a small greenhouse fits next to the shed. Tomatoes outside the kitchen at last. Needs a base, gravel probably, and the tap moved. Ask Jan what he paid for his.",
              summary: "The fence can go back a metre with the neighbour's agreement, so a small greenhouse fits next to the shed. It needs a gravel base and the tap moved. Ask Jan what he paid for his.",
              generatedTitle: "Greenhouse by the shed"),
    ]
}
