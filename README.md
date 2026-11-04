# Clio for iOS

Record, and the words are yours: Whisper runs on the phone, and nothing
leaves it. A native SwiftUI app with the same offline promise as the Mac app
in the sibling `clio` repository.

[`docs/plan.md`](docs/plan.md) is the plan and the orientation — what is
built, what is next, and why the choices went the way they did.

## Build

```sh
swift build                   # the two libraries, on the host
swift test                    # core tests, no simulator needed
xcodegen generate             # brew install xcodegen
open Clio.xcodeproj           # run on a simulator or a phone
```

Or from the shell:

```sh
xcodebuild -project Clio.xcodeproj -scheme Clio \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' build
xcodebuild -project Clio.xcodeproj -scheme Clio \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' test
xcrun simctl privacy booted grant microphone com.bartbak.clio.ios   # then the UI test:
xcodebuild -project Clio.xcodeproj -scheme Clio -only-testing:ClioUITests \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' test
```

[`AGENTS.md`](AGENTS.md) is the orientation for working on the code: the
loop file by file, the commands, the patterns, and the traps.

The Xcode project is generated from `project.yml` and not tracked. To put a
particular screen on a simulator without tapping through to it, see
"Looking at it" in the plan.

```sh
CLIO_INTEGRATION=1 swift test --filter Integration   # downloads ~81 MB, real Whisper (and Apple's model, where the Mac has it)
TEST_RUNNER_CLIO_INTEGRATION=1 xcodebuild -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme ClioMobile-Package -destination 'platform=macOS' \
  -only-testing:ClioMobileSummaryTests test           # downloads ~350 MB, a real MLX summary (needs xcodebuild: Metal)
```

## Status

Release candidate: Whisper via WhisperKit on models downloaded from Hugging
Face; titles and summaries from Apple's on-device model where the phone has
one, or from a downloaded MLX model where it does not, both through one
prompt shaped by Settings (note type, format, length); a transcript whose
sentences can be tapped to play; "Record with Clio" from Siri, the Action
button and a Lock Screen control; a Live Activity while recording; a live
transcript preview while holding to record. Proven on the host and the
simulator; the first run on a phone is still ahead, and TestFlight follows
it.
