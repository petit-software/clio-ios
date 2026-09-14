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
  -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project Clio.xcodeproj -scheme Clio \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The Xcode project is generated from `project.yml` and not tracked. To put a
particular screen on a simulator without tapping through to it, see
"Looking at it" in the plan.

```sh
CLIO_INTEGRATION=1 swift test --filter Integration   # downloads ~81 MB, real Whisper
```

## Status

Milestone 3: Whisper via WhisperKit on models downloaded from Hugging Face
in Settings ▸ Model, and titles and summaries from Apple's on-device
language model on phones with iOS 26 and Apple Intelligence. Both are
proven on the host by the integration tests; the first run on a phone is
still ahead. Polish and TestFlight are milestone 4.
