# Working on Clio for iOS

Orientation for picking this up cold. [`README.md`](README.md) says what
Clio is and how to build it; [`docs/plan.md`](docs/plan.md) is the plan,
milestone by milestone, with the decisions and their reasons. This file is
the index: how the pieces fit, what is proven versus merely written, and the
mistakes already made so they are not made twice. Keep it current; move
anything that turns out to be a task, a guess or a debugging note to
`.ultra/todo.md` (gitignored) or a scratch file, not here.

The promise everything serves: **speech becomes text on this phone, and
nothing leaves it.** Audio, transcripts, titles and summaries are made on
the device by models the user downloaded or iOS ships. There is no cloud
fallback and none is to be added. The only network use is downloading
models from Hugging Face, through `ModelManager`.

## The loop

One recording, end to end, with the file that owns each step.

| | | |
|---|---|---|
| 1 | tap Record (sheet) or hold the button (hold to record), or arrive by `clio://record` from Siri, the Action button or the Lock Screen control | `ClioMobileUI/RootView`, `RecordView`, `RecordingsListView` (hold buttons), `ClioMobileActivity/StartRecordingIntent` |
| 2 | microphone starts: `AVAudioEngine` tap at `format: nil`, converter built from the buffers, 16 kHz mono Float32 in memory | `ClioMobileCore/AudioRecorder` |
| 3 | state machine: idle → starting → recording ⇄ paused/interrupted → transcribing → idle; levels polled 60×/s; the Whisper model loads while the user talks | `ClioMobileCore/CaptureController` |
| 4 | optional, hold to record only: every 2 s the last 30 s through the model into `livePreview` | `CaptureController.startPreview` |
| 5 | stop: the recorder removes its tap, then lowers its flag, and hands back every sample | `AudioRecorder.stop` |
| 6 | is there a word in it at all — length, peak, voice gate — without loading anything | `ClioMobileCore/SilenceGate` |
| 7 | the WAV is written, and the part goes into the library **as pending** | `AudioFiles.write`, `CaptureController.finish`, `RecordingStore` |
| 8 | silence trimmed at both ends, edges walked through quiet speech, a second of pad kept after | `ClioMobileCore/VoiceActivityTrimmer` |
| 9 | Whisper via WhisperKit, timestamps on, segments kept | `ClioMobileCore/WhisperKitEngine` |
| 10 | replacements, capitalisation, trailing punctuation | `ClioMobileCore/TranscriptFormatter` |
| 11 | the part is written over with its words; the recording opens | `RecordingStore.replace`, `RootView.onChange(lastRecordingID)` |
| 12 | a title and summary follow, beside the loop, from whichever model Settings names | `ClioMobileCore/IntelligenceController`, `SummaryRouter` |

Every capturing state is cancellable (the X on the sheet asks first).
Cancelling while transcribing keeps the row and its audio as "Not
transcribed yet"; so does a failure; so does the app being killed mid-way.
Step 7 is why. "Transcribe Again" on the detail picks any of them up.

## Summaries

| | | |
|---|---|---|
| 1 | every path — after a transcript, Summarize Again, a retry, after a merge or a part recorded into a recording — builds one `SummaryRequest` from `Settings.summaryPreferences` **as they are at that moment** | `IntelligenceController.perform` |
| 2 | the router reads `Settings.summaryModel` and sends the request whole to Apple's engine or the MLX one; it also corrects a choice that cannot run | `ClioMobileCore/SummaryRouter` |
| 3 | one prompt: fixed rules, a line each for note type, format and length, the user's additions last, and (text models only) the answer form | `ClioMobileCore/SummaryPrompt` |
| 4a | Apple Intelligence: guided generation into two fields; the guides say nothing about shape, so the instructions decide | `ClioMobileCore/FoundationModelsSummarizer` |
| 4b | a downloaded model: MLX on the GPU, two answers — the notes, then a title for them — Qwen3's thinking and stray turn markers stripped, the model released after | `ClioMobileSummary/MLXSummaryEngine` |
| 5 | a result writes the title and summary; a failure writes nothing and is shown above the old summary with a retry | `IntelligenceController.perform`, `RecordingDetailView.summarySection` |

The transcript is read by this, never written. Titles are at most five
words, enforced by `SummaryPrompt.cleanTitle` whatever the model does.

## Targets, and why

- **`ClioMobileCore`** — no SwiftUI. Settings, the library, audio capture,
  the model managers, both engine seams (`TranscriptionEngine`,
  `SummaryEngine` / `LocalSummaryEngine`), the prompt, the router, the
  formatter. Builds for macOS too, so `swift test` runs on the host.
- **`ClioMobileObjC`** — one function: run a block and catch the
  NSException `AVAudioEngine` may raise.
- **`ClioMobileActivity`** — what the app and the widget extension both
  need and nothing more: the Live Activity attributes, the
  `StartRecordingIntent` and the `clio://` URLs. Must not pull in
  WhisperKit or MLX.
- **`ClioMobileSummary`** — MLX and the engine on it, and nothing else, so
  the core, the tests and every preview build without MLX.
- **`ClioMobileUI`** — every view and `AppModel`, the wiring. A library so
  `#Preview` renders dependably.
- **`ClioMobileApp`** — `@main`, the app delegate for background downloads.
- **`ClioWidget`** (Xcode target) — the Live Activity and the
  `RecordControl` control. Links `ClioMobileActivity` only.

## Commands

```sh
swift build                   # every library, on the host
swift test                    # 130 tests, 23 suites, no network, under a second
xcodegen generate             # Clio.xcodeproj from project.yml (not tracked)
xcodebuild -project Clio.xcodeproj -scheme Clio \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' \
  -derivedDataPath .build/DerivedData build          # app + widget for the simulator
xcrun simctl privacy booted grant microphone com.bartbak.clio.ios   # then:
xcodebuild -project Clio.xcodeproj -scheme Clio -only-testing:ClioUITests \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' test
```

Gated, off by default, all on the host:

```sh
CLIO_INTEGRATION=1 swift test --filter Integration      # Whisper Tiny (~81 MB, cached in /tmp) and
                                                        # Apple's model if this Mac has Apple Intelligence
TEST_RUNNER_CLIO_INTEGRATION=1 xcodebuild \
  -workspace .swiftpm/xcode/package.xcworkspace -scheme ClioMobile-Package \
  -destination 'platform=macOS' -only-testing:ClioMobileSummaryTests test
                                                        # the MLX engine on Qwen3 0.6B (~350 MB, cached)
TEST_RUNNER_CLIO_SUMMARY_MODEL=Qwen3-1.7B-4bit …        # …or another catalog id
```

**MLX must go through `xcodebuild`.** SwiftPM has no Metal step, so
`swift test` builds `ClioMobileSummary` fine and then fails at the first
array with "Failed to load the default metallib". That is why the MLX tests
are a target of their own and run through the package workspace. The
simulator cannot run MLX at all (no Metal of the family it needs); the
engine says so in its availability and the simulator app shows that reason.

Looking at a screen without tapping to it: `CLIO_SIMULATE=1 CLIO_SHOW=…`
and friends, documented in `docs/plan.md` ▸ "Looking at it" and in
`RootView.swift` (`LaunchOptions`). Settings ▸ Developer (debug and
TestFlight builds) fills the library and stages every screen on a phone.

## Patterns to keep to

- **Logic in the core, behind a protocol, with a stub.** `AudioCapturing`,
  `TranscriptionEngine`, `SummaryEngine`, `LocalSummaryEngine`,
  `LocationProviding`, `ModelTransport` each have a simulated twin that
  says what it is in its output (`[Clio stub] …`), so a broken real path
  can never look like a working one. Tests drive the real controllers on
  the stubs.
- **`@MainActor @Observable` controllers; nothing on the audio thread
  touches an actor.** The tap writes under a lock; the controller polls.
- **Settings and the recording index decode field by field.** A new field
  goes in the struct *and* in `init(from:)`, else every existing file is
  unreadable. Nested preference structs (`SummaryPreferences`) do the same.
  Old keys are read through a `LegacyKeys` enum and never written.
- **One `ModelManager` per model kind** (`ModelLayout.whisper`,
  `.languageModel`), same download path: list, stage in `<id>.partial`,
  verify by size and SHA-256 in the background session, rename into place.
  A folder counts as installed only when the layout says it is complete.
- **A stored choice follows what is there.** `reconcileActiveModel` for
  Whisper, `SummaryRouter.resolve` for summaries. Settings never shows a
  selection that cannot run.
- **Native first.** System sheets, `Form`, `Picker`, `Toggle`, alerts and
  confirmation dialogs, `Label`, SF Symbols, `ContentUnavailableView`. The
  record sheet's capsule controls and the lime wash are the custom parts,
  on purpose; do not add others, and do not restyle those into system
  buttons — that was tried and reverted.
- **One deletion confirmation** (`RecordingDeletion` for the words,
  `View.confirmDeletion` for the alert, `RecordingStore.delete` for the
  deed) from the list bar, a swipe and the detail menu alike.
- **Copy is short and literal.** Say what happens; no promises about
  quality; the preview is called a preview.
- **Reduce Motion** is read where there is motion: the wash goes flat, the
  dots stop pulsing, the recede only fades, the clock does not roll.
- Commit by explicit path. Another session may be editing the tree.

## Traps

**The transcript ended a sentence early while the audio did not.** Two
causes, both fixed, both easy to reintroduce. The trimmer cut at the last
frame over the energy gate plus 120 ms, and the end of a sentence is ten
decibels under its start, so a voice trailing off was cut with the silence
after it. The edge is now walked through frames above a second, lower gate
and padded by a second (`VoiceActivityTrimmer`; `TrimmerEdgeTests`, and
`IntegrationTests/quietTailIsTranscribed` shows the real model losing
"and bring the signed contract" with the old cut). And the recorder lowered
its running flag before removing the tap, so the buffer in flight at Stop
was dropped. Trailing silence costs nothing inside a window Whisper pads to
30 s; do not tighten the pad for speed.

**WhisperKit never decodes the last second after a seek.**
`DecodingOptions.windowClipTime` is 1.0 s: the window loop stops when the
seek is within a second of the end. For a clip of one window this is
moot (seek is 0). For a longer one, speech in the last second after the
final seek is dropped by design, to avoid hallucinating over the tail. The
trimmer's pad keeps real speech out of that second.

**A WAV with no row is a lost recording.** The part goes into the library
before the model is asked (`CaptureController.finish` → `place`). Keep it
that way: cancel, failure and a kill all leave a pending row. The list and
detail read `capture.isTranscribing(_:)` to say "Transcribing…" on it;
`TranscriptStatus` has no transcribing case on purpose, so a kill leaves
"pending" on disk, which is the truth.

**iOS suspends the app seconds after the screen locks once the microphone
has stopped.** `UIBackgroundModes: audio` keeps it alive only while
capturing. `BackgroundWork.begin` asks for the standard grace (tens of
seconds) around transcription; it is not forever. A long transcription
resumes when the app comes back; a kill leaves the pending row.

**Guided generation guides are part of the prompt.** The `@Guide`
descriptions on `FoundationModelsSummarizer.Draft` once said "one to three
sentences" and overrode every preference. They describe the fields and
nothing else now; the instructions carry the shape.

**Summarize Again was never a different path.** It goes through
`IntelligenceController.summarize` like the first summary. What looked like
a bypass was the guide text above and the absence of any shape settings.
`IntelligenceTests/preferencesReachTheModel` pins this.

**The tap takes `format: nil`, the converter is built from the buffers,
and every engine call that can raise goes through `ObjCException`.** The
Mac app's every crash was a tap installed for a format a Bluetooth headset
then changed.

**A control's intent runs in the widget extension.** It has no microphone,
and iOS does not start capture from the background anyway. The intent
opens `clio://record`; the app starts recording as it comes forward. Do not
make the intent say recording has started. A locked phone asks for its
unlock first, for any control that opens an app.

**MLX on a phone is memory-bound.** The catalog's `memoryBytes` are
estimates (about 1.6× the weights plus 300 MB); `LanguageModelSupport.fits`
compares them with `os_proc_available_memory()` at the time, and the app
carries the increased-memory-limit entitlement. The engine loads a model
per summary and releases it; the GPU cache is capped at 20 MB. Do not keep
a model resident.

**Small text models cannot keep a two-part answer straight.** Asked for
"Title: … then the summary" in one go, Qwen3 0.6B copied the placeholder
as its title or skipped the line. The MLX engine asks twice: the notes,
then a title for those notes (`SummaryPrompt.titleInstructions`). Apple's
engine has fields and does not need this.

**Qwen3 thinks aloud unless told not to.** `enable_thinking: false` goes in
the chat template context, and `strippingThinking` removes any tags that
come through anyway. Gemma's template has no system role of its own; it
folds the instructions into the first user turn, which is fine.

**Gemma does not stop by itself, and was dropped anyway.** Its
`<end_of_turn>` is not in the tokenizer config as end-of-sequence, so
without `ModelConfiguration(extraEOSTokens:)` naming it the model runs on
to the token cap writing noise — 17 s instead of 2; the engine names it, in
case another model needs it. Stopped properly, Gemma 3 1B still invented a
currency, added headings it was told not to and answered Dutch in English,
so it is not in the catalog. The measurements are in `docs/plan.md`,
milestone 7; a candidate model goes through that test before it is offered.

**Small models invent currencies.** "Eleven hundred" came back as £1100
and $1,100. The rules say to keep numbers as said and add no currency or
unit; the MLX test asserts it.

**`swift test` can show a wrong `Optional<Int64> == literal` failure** with
the right numbers on both sides; write `Int64(…)` on the literal.

## What is proven, and what is not

Verified by something repeatable, as of this release candidate:

- 130 unit tests on the host: the capture state machine on a simulated
  microphone, including the row landing before the transcript, cancel and
  failure keeping the audio, the live preview appearing and vanishing; the
  trimmer keeping a quiet tail, a soft first word and a word after a
  breath; the meter not pinning on normal speech and not jittering on a
  steady tone; the prompt's layers and order; preferences reaching the stub
  engine on the first summary, on Summarize Again and after a merge; a
  failed regeneration keeping the old summary; the router's five routes
  and its corrections of the stored choice; the language-model layout's
  discovery and download; settings and index migrations.
- With `CLIO_INTEGRATION=1` on this Mac: Whisper Tiny transcribes
  synthesized speech; the quiet last sentence reaches the transcript where
  the old cut lost it; Apple's model, with the shared prompt, writes a
  faithful title and summary in English and Dutch and bullets when asked.
- Through `xcodebuild` on this Mac: both catalog MLX models load from the
  installed folder offline, follow the shared prompt's shape, title in a
  second call and release their memory; numbers and limits in
  `docs/plan.md`, milestone 7.
- The app and the widget extension build for the iOS 27.2 simulator.

Not verified, and worth knowing:

- **Anything on a phone.** The real microphone, Bluetooth routes, a call
  mid-recording, the Action button, the Lock Screen control, the Live
  Activity on a Lock Screen, Foundation Models on an iPhone, and every MLX
  figure below. The simulator cannot run MLX, so a phone without Apple
  Intelligence — an iPhone 15 is the representative one — is the only
  place a downloaded summary can be seen.
- **MLX timings on a phone.** A Mac's GPU says which model writes better,
  not how long a phone takes; the plan's figures are the Mac's.
- **Memory estimates** in `LanguageModelCatalog` are estimates until
  `GPU.peakMemory` is read on a phone for each model.
- **The Apple7 GPU requirement** (A14 and later) is MLX's documented floor
  for its kernels; an A13 phone has not been tried.
- **Live preview cost.** Whisper Small every two seconds while holding is
  Neural Engine work and battery; the setting is off by default and says so.
- **The increased memory entitlement** needs the capability on the App ID;
  automatic signing adds it, but a first device build should be watched
  for a provisioning complaint.
