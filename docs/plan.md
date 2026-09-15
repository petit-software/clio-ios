# Clio for iOS — plan

Clio on the Mac is dictation: hold a key, speak, and the text is pasted into
the frontmost app. That loop does not exist on iOS — there is no global
hotkey, no frontmost app to paste into, and no way to inject text. What
survives the move is the promise: **speech becomes text on this device, and
nothing leaves it.**

So the iOS app is a recorder with a local transcriber. Tap record, speak,
stop; the audio is kept, Whisper runs on the Neural Engine, and the transcript
sits beside the recording. Everything offline after the model download.

This document is the plan: what is being built, in what order, and what each
milestone has to prove before the next one starts. It is written the way the
Mac app's `AGENTS.md` is — for whoever picks it up cold.

## Product

Four screens, all native SwiftUI, no third-party UI:

| Screen | What it does |
|---|---|
| **Recordings** | The list. Newest first, title, date, duration, first line of the transcript. Search. Swipe to delete. A record button that is never more than one tap away. |
| **Record** | Elapsed time, live level meter, the cap. Stop or cancel. Transcribes on stop and returns to the list with the new recording at the top. |
| **Recording** | Playback with a scrubber, the transcript (selectable), an editable title, share, copy, delete. Later: an on-device summary. |
| **Settings** | Model (download, select, delete), transcription (language, translate, vocabulary, replacements), text (capitalisation, punctuation), recording (cap, VAD), intelligence, about. |

"Local LLM" means two on-device models, both native:

1. **Whisper via WhisperKit** — the transcriber. Same engine, same catalog,
   same Hugging Face layout as the Mac app, run on the Apple Neural Engine.
2. **Apple Foundation Models** — the on-device language model that ships
   with iOS 26 and Apple Intelligence. Used for titles and summaries of a
   transcript. Gated behind availability; the app is complete without it.

Non-goals: cloud anything, streaming transcription, iCloud sync, sharing
between the Mac app and this one, an iPad layout beyond what SwiftUI gives
for free.

## Shape

```
clio-ios/
  Package.swift               ClioMobileCore, ClioMobileUI, tests
  project.yml                 xcodegen → Clio.xcodeproj (not tracked)
  Resources/Info.plist        usage descriptions, background audio
  Sources/
    ClioMobileCore/           no SwiftUI; everything with logic
    ClioMobileObjC/           one function: catch an NSException
    ClioMobileUI/             every view, AppModel wiring
    ClioMobileApp/            @main and nothing else
  Tests/ClioMobileCoreTests/
  docs/plan.md                this file
```

The same three-target split as the Mac app, for the same reasons: logic in a
library with no SwiftUI so it is testable without a device, views in a
library so `#Preview` renders dependably, and an executable that owns
`@main` and nothing else.

The core is **copied and adapted** from `../clio/Sources/ClioCore` (the Mac
app, a sibling repository), not imported.
`ClioCore` builds for macOS only — it owns the event tap, CoreAudio device
enumeration and the pasteboard — and making it cross-platform means
`#if os(macOS)` through a shipping app to serve one that does not exist yet.
The platform-neutral pieces (settings, formatter, model catalog, transport,
manager, the engine seam, WhisperKit engine) are ~1,200 lines and change
rarely. If they drift, milestone 4 is where they become a shared package
both repositories depend on.

Persistence is JSON, as on the Mac: one `settings.json`, one
`recordings.json`, and a WAV per recording. SwiftData would be the more
"iOS" choice, but a Codable struct decoded field by field is what has kept
the Mac app's settings surviving every schema change, and the store stays
testable without a model container.

## Milestones

Each milestone ends with something that runs. "Done" means it builds for the
simulator, its tests pass, and it has been looked at on a screen.

### M1 — the loop, on a stub  ✓

The whole app, with the transcriber faked. Every screen, every store, the
recorder, the state machine, and a stub engine that returns an obviously fake
transcript — so a broken ASR path can never look like a working one.

- `Settings`, `SettingsStore` — field-by-field decode, debounced save
- `Recording`, `RecordingStore` — the library: index + audio files
- `AudioRecorder` — AVAudioEngine tap at `format: nil`, converter built from
  the buffers, 16 kHz mono Float32, WAV written at stop, the cap
- `CaptureController` — idle → recording → transcribing → done, cancellable
- `TranscriptionEngine` protocol + `StubTranscriptionEngine`
- `TranscriptFormatter` — replacements, capitalisation, trailing punctuation
- Recordings list, Record sheet, Recording detail with playback, Settings
- Previews on simulated dependencies; no preview touches the microphone
- Tests: settings round-trip and tolerance, store add/delete/rename,
  formatter, capture state machine on a simulated recorder

Proves: the app is usable end to end and nothing about the UI depends on
which engine is behind the seam.

### M2 — Whisper  ✓

Swap the stub for the real thing.

- `ModelCatalog`, `ModelTransport`, `ModelManager` from the Mac app —
  Hugging Face listing, SHA-256 verified download, tokenizer beside the
  model, resumable at file granularity. Downloads stage in `<id>.partial`
  and are renamed into place when complete, so a half-download never reads
  as installed and a failed one resumes on retry. No shared Hugging Face
  cache: there is no `~/.cache` on a phone.
- `WhisperKitEngine`, `withoutTimestamps` false, tokenizer folder set
- `VoiceActivityTrimmer` on WhisperKit's energy VAD; silence at both ends
  is cut before transcription, a clip with no speech is "nothing heard"
  without the engine being asked
- `CaptureController` loads the active model on record start (overlapping
  the load with the talking), transcribes on stop, and unloads afterwards
  when "keep in memory" is off. Nothing installed marks the recording
  failed with a message and keeps the audio; "Transcribe Again" picks it
  up once a model is there.
- Settings ▸ Model: one row per catalog model with download, progress,
  cancel, select, delete; models directory excluded from backup. About
  shows models on disk. The list shows a banner while nothing is installed.
- The active model is warmed when the app becomes active if "keep in
  memory" is on; selecting a different model drops the resident one
- Integration test, gated on `CLIO_INTEGRATION=1`, host only: install
  Tiny, transcribe a phrase from `say`, assert the words — once through
  the engine alone, once through the capture controller

Proves: transcription works on a Neural Engine path, offline, through the
same loop the app runs. **Not yet proven on a phone** — see below.

### M3 — on-device intelligence  ✓

Apple Foundation Models, iOS 26+, Apple Intelligence on.

- `SummaryEngine` protocol with a stub and an "unavailable" engine;
  `FoundationModelsSummarizer` behind `#if canImport` + `#available`, asks
  `SystemLanguageModel.default.availability` and `supportsLocale` before
  every call, and turns the framework's errors into sentences
- Guided generation: one `@Generable` draft with a title and a summary,
  one fresh session per recording, temperature 0.3
- `IntelligenceController` runs beside the capture loop: the recording is
  in the library the moment the transcript is, the title and summary land
  on it a few seconds later. Skipped under twelve words; off in Settings
  or unavailable on the phone does nothing.
- `Recording.generatedTitle`: shown when the user has not typed a name,
  never overwrites one they did
- Settings ▸ Intelligence: the toggle, and the reason when unavailable
- Detail view: summary section with "Summarizing…", the failure and a
  retry, or a Summarize button; "Summarize Again" in the menu
- Integration test, gated on `CLIO_INTEGRATION=1`, host only: the real
  model writes a title and summary for a fixed transcript, or prints why
  it cannot

Proves: an LLM can run over a transcript without the transcript leaving
the phone.

### M4 — polish and ship  ✓

- Interruptions and route changes: the recorder observes the audio
  session and the engine. A call or Siri pauses capture into an
  `interrupted` state — the buffer and the tap survive, the engine is
  started again when the interruption ends, and if it cannot be, the
  recording stops with what it has. A route change restarts the engine on
  the new hardware; the tap has no format of its own, so it follows.
  Proven on the state machine through simulated events; on a phone with a
  real call, not yet.
- Haptics on start, stop and failure, behind the Settings toggle
- A Live Activity while recording: `ClioMobileActivity` (attributes only,
  shared), `ClioWidget` extension (Lock Screen banner and Dynamic Island,
  a system-counted clock, paused state), `RecordingActivityController`
  in the app following the capture state
- App icon re-fitted from the Mac artwork: the export has transparent
  corners and iOS wants an opaque square, so it is drawn over a gradient
  sampled from its own background column. Light and dark variants.
- Storage: recordings, models and the total in About; delete-all with
  confirmation
- Model downloads on a background `URLSession`, so locking the screen
  during a gigabyte download does not end it; the delegate verifies and
  places each file itself, so a relaunched app finds it where the next
  attempt looks
- Privacy manifest, automatic signing with the team; no entitlements
  needed — no iCloud, no push, no app groups. `xcodebuild archive` with
  automatic provisioning succeeds for the app and the widget.
- The record button is the whole strip under the list: solid red from
  edge to edge and down through the home indicator, "Record" in white on
  it, split-view style — the list ends where the red begins rather than
  scrolling under a button. Not a toolbar item: iOS 26 restyles those and
  collapses a labelled one to its glyph. Search is pinned under the title.
- Decision on the shared core: still copied, see "Decisions"

Ships: a TestFlight build, once it has been run on a phone.

### M5 — the transcript is the recording  ← this milestone

Two things a memo app needs that the loop did not give: a way from a
sentence back to the sound of it, and a way to start recording without
finding the app first.

- `TranscriptSegment` — start, end, text — from WhisperKit's segments,
  with the special tokens stripped and the times shifted by whatever the
  trimmer cut off the front, so they index the file on disk. Stored on the
  recording; the transcript text is the segments joined, so the two never
  disagree. Recordings from before decode with no segments and behave as
  they did.
- `TranscriptFormatter.format(_:settings:)` over segments: replacements in
  each, the capital on the first, the trailing punctuation off the last
- Detail view: the transcript is one paragraph of tappable sentences. Tap
  one and playback jumps there; the sentence being played is tinted as
  the audio moves through it. Built as one attributed string of links so
  it wraps like prose; the tap arrives through `openURL`.
- Share the audio file, beside sharing the text
- `StartRecordingIntent` and an App Shortcut: "Record with Clio" from
  Siri, Shortcuts, Spotlight, and the Action button. The intent opens the
  app and hands the root view a pending action.
- The stub engine returns two segments, so previews and tests can seek

Proves: the transcript and the audio are one thing, and the app can be
started by voice or button without a tap in between.

### M6 — the list, as asked

Five things from the todo, all on the way the app is used:

- Settings is a list of pages, one per topic — Model, Transcription,
  Text, Recording, Intelligence, About — each row showing the value that
  matters: the active model, the language, the length cap, on or off
- The player lives in a bar at the bottom of the detail view, scrubber
  and times above the three transport buttons, and the transcript gets
  the whole list
- The record pane goes away while a search is in progress
- The record screen is Scribia's recording sheet, copied and adapted: a
  medium-height sheet on the dark capture surface, a three-second
  countdown, the clock, a meter that remembers the last few seconds,
  pause and resume, stop, start again, close with a discard confirmation,
  and a pull to the large detent for a bigger clock. `CaptureController`
  gained `pause`/`resume` and a `paused` state, and the recorder pauses
  the engine in place.
- "Hold to record" in Settings ▸ Recording: the pane itself records
  while the finger is on it and stops when it lifts, showing the clock
  and then "Transcribing…" until the recording opens. No sheet.

A recording that lands opens from the root, whichever way it was made.

Two home layouts are kept side by side, `HomeStyle.pane` and
`HomeStyle.floating`, switchable at launch with `CLIO_HOME`. The floating
one is the default for now: the list runs the full height, a red capsule
floats at the bottom, and under it a wash rises from solid red at the
screen edge to nothing a little above the button, with the list scrolling
through it. The pane is the earlier design, the list ending above a red
strip that is the button.

The record sheet's meter is six capsules that stay put: circles at rest,
each rising with the part of the voice it hears. `MeterAnalyzer` is the
Mac app's, widened to six bands, fed from the tap on the raw hardware
buffer.

## Looking at it

Any screen can be put on a simulator without tapping through to it, on
simulated data — the same idea as the Mac app's `CLIO_*_SHOW` switches:

```sh
xcodegen generate
xcodebuild -project Clio.xcodeproj -scheme Clio \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/DerivedData build
xcrun simctl boot "iPhone 17 Pro"
xcrun simctl install booted .build/DerivedData/Build/Products/Debug-iphonesimulator/Clio.app
SIMCTL_CHILD_CLIO_SIMULATE=1 SIMCTL_CHILD_CLIO_SHOW=record \
  xcrun simctl launch --terminate-running-process booted com.bartbak.clio.ios
xcrun simctl io booted screenshot record.png
```

`CLIO_SIMULATE=1` runs on fixed recordings, a fake microphone and the stub
engine; the only thing it writes is a synthesized tone per recording in a
temporary folder, so playback and tap-to-seek work. `CLIO_SHOW` is
`record`, `settings` or `detail`; `CLIO_AUTOPLAY=1` starts playback when
the detail view appears. Debug builds only.

## What is proven, and what is not

Verified by something repeatable, as of milestone 5:

- **the real microphone, on a simulator.** `UITests/RecordFlowUITests`
  drives the real app: tap Record, the Mac's microphone runs through
  `AudioRecorder`, tap Stop, the recording opens with its player loaded
  and is in the list. Run with `xcodebuild test -only-testing:ClioUITests`
  after granting the microphone with `simctl privacy`.

- segments come through the loop shifted by the trimmed lead, the
  transcript equals their join, and they survive the index; the
  formatter's per-segment rules; special-token stripping
- playback of a real WAV on the simulator, and the highlighted sentence
  following the scrubber through the segments (`CLIO_AUTOPLAY=1`)
- the real model's segments on the host: one segment for a short clip,
  inside the clip, no special tokens

- the capture state machine through an interruption: paused, resumed,
  ended when the recorder cannot resume, stop and cancel while paused,
  the microphone lost mid-recording (`CaptureTests`)

- the intelligence controller on a stub engine: summarizes after a long
  transcript, skips short ones, respects the toggle and availability,
  reports a failure, regenerates without touching the user's title, and
  is handed every transcript the capture loop finishes
  (`IntelligenceTests`)
- the prompt's limits and the title clean-up; the generated title's place
  in the display order and its round trip through the index

- the state machine, end to end, on a simulated microphone (`CaptureTests`),
  including no model installed, silence trimmed to nothing, trimming off,
  unload after transcription, and the stored selection following what is
  installed
- the model manager on a stub transport: discovery ignores staging folders,
  the tokenizer lands in its own folder without the weights, a failed
  download resumes at file granularity, cancel clears the staging folder,
  delete only touches our own directory (`ModelTests`)
- the trimmer cuts silence at both ends and returns nil for none
  (`TrimmerTests`)
- a WAV round-trips its samples; the level scaler's window
- settings and the recording index survive missing and malformed fields
- every screen renders on an iPhone 17 Pro simulator, on simulated data
- with `CLIO_INTEGRATION=1`, on the host: Tiny downloads from Hugging Face
  with its tokenizer and transcribes synthesized speech correctly, through
  the engine and through the controller

Not verified, and worth knowing:

- **Segment times from the real model.** The stub's segments are exact by
  construction. WhisperKit's are what Whisper's timestamp tokens say,
  which is usually within a few hundred milliseconds; whether a tap lands
  on the right word is a listening test.
- **The intent from the Action button.** The intent and shortcut build;
  Siri and the Action button need a device to try.
- **A real phone call.** The interruption path is proven on simulated
  events; whether `AVAudioEngine` restarts cleanly after a call on a
  device, and whether the gap in the buffer is where the call was, is a
  device test. Same for unplugging headphones mid-recording.
- **The Live Activity on a Lock Screen.** Seen in the simulator's Dynamic
  Island — red dot, running clock — with another app in front. The Lock
  Screen banner and the paused state have not been looked at. If the app
  is killed mid-recording the activity outlives it until its stale date,
  the cap plus a minute; a phone shows the same.
- **Foundation Models on a phone.** The engine is exercised on the host
  when this Mac has Apple Intelligence on, and in the app only through the
  stub. The simulator runs the real model only if the host Mac has Apple
  Intelligence; a phone needs iOS 26 and an A17 Pro or later.
- **Languages beyond English and Dutch.** The model supports a fixed set
  of locales. Whisper's language is checked against `supportsLocale` first
  and the failure names the language. Dutch is supported on this Mac's
  model and the summary came back in Dutch (`IntegrationTests/dutch`).
- **WhisperKit on a phone.** The engine is the Mac app's and the integration
  test runs it on the host's Neural Engine. Nobody has downloaded a model
  and transcribed on an iPhone or a simulator yet. The simulator has no
  Neural Engine, so WhisperKit falls back to CPU there — slow, but it
  should work; the device is where the timing is measured.
- **the real microphone on a phone.** It records on the simulator through
  the Mac's microphone; the phone's own microphone, Bluetooth headsets and
  the permission prompt on a device are still a first-run test.
- **background downloads across a relaunch.** Downloads go through a
  background `URLSession` (`BackgroundDownloader`), so a locked screen
  does not end them; each task carries its destination and checksum so
  the delegate can verify and place the file even if the app was killed
  meanwhile, and the app delegate reconnects the session on relaunch.
  The foreground path is exercised by the integration test; the relaunch
  path is written, not exercised.
- **background recording** with the screen locked.

## Decisions already made

- **iOS 18 minimum.** `@Observable`, `ContentUnavailableView`, editable
  `navigationTitle`, `AVAudioApplication` for the permission. iOS 26 only
  for Foundation Models, gated.
- **Package platforms include macOS 15** so `swift test` runs on the host
  without a simulator. Anything iOS-only sits behind `#if os(iOS)`. The
  simulator run is the one that counts; the host run is the fast one.
- **The tap takes `format: nil`.** The Mac app's every crash was the tap
  install raising on a Bluetooth headset changing format. The converter is
  built from the buffers that arrive, and install runs through the ObjC
  exception shim.
- **Samples are kept in memory, the WAV is written at stop.** 10 minutes of
  Float32 at 16 kHz is 38 MB — the Mac app holds the same. It keeps disk I/O
  off the audio thread and the file is only ever complete or absent.
- **Levels are polled, not pushed.** The tap thread writes one float under a
  lock; the controller reads it 30× a second on the main actor. Nothing on
  the audio thread ever touches an actor.
- **`Settings` and `Recording` decode field by field.** A missing key costs
  that one field, never the file. Add new fields to `init(from:)`.
- **Recordings live in Application Support, not Documents.** They do not
  belong in the Files app unless the user shares them. Models are excluded
  from backup; recordings are not.
- **Whisper Small is the default, not Distil Large as on the Mac.** A phone
  has less memory, and the recordings are as likely to be Dutch as English;
  Small is multilingual and 217 MB. Distil Large and Turbo are in the same
  list, one tap away.
- **The model is loaded on record start, not on stop.** A cold load takes
  seconds; started when the user begins talking, it is done by the time
  they stop. "Keep model in memory" decides whether it is released after.
- **Summaries do not block the transcript.** The row appears when the
  transcript is in and the title and summary update it a moment later,
  because a summary that takes ten seconds should not hold the recording
  hostage, and one that fails should not mark the recording as failed.
- **The shared core stays copied, for now.** The platform-neutral files
  (catalog, transport, manager, engine, trimmer, formatter) were copied
  from the Mac app in M2 and have already diverged in small ways: no
  Hugging Face cache, a staging folder for downloads, a different
  default model. A shared package would need those as options. Until
  one repository has to pick up a fix from the other, the copy costs
  nothing; the first such fix is the signal to extract.
- **Integration tests are host-only.** They need `say` for speech and the
  package builds for macOS so `swift test` runs without a simulator. A
  device run is a manual step until there is a fixture clip.

## Open

- ~~Whether the level meter should share the Mac app's five-band analyser~~
  It does, widened to six bands: the record sheet's meter is six capsules
  that stay put, circles at rest, each hearing its own part of the voice.
  The single RMS level is still polled for the hold-to-record pane.
- Locked-phone recording needs `UIBackgroundModes: audio` — set in M1 — but
  interruption handling (a phone call mid-recording) is M4 and untested
  until then.
- Foundation Models in the simulator needs Apple Intelligence enabled on the
  host Mac. If it is not, the live app on the simulator shows the reason
  in Settings ▸ Intelligence and M3 is proven on a device.
