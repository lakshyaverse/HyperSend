# Contributing to HyperSend

Thanks for looking at the engine. It is small on purpose — the fastest way in
is `mac/Sources/Engine/`, and the fastest way to *understand* it is
`mac/test.sh`, which exercises the real protocol over loopback TCP with no
mocks.

## The one rule

**Do not break the wire protocol.** Three implementations share it: the Swift
sender, the Kotlin receiver, and the Node reference engine in `src/`. If a
change requires new framing, it is a protocol version bump and it needs to land
in all three plus the test oracle, together, in one PR.

## Getting set up

The Mac app:

```bash
git clone https://github.com/lakshyaverse/HyperSend.git
cd HyperSend/mac
./build.sh run     # xcodebuild, then launch
./test.sh          # 42 end-to-end checks, ~seconds, no phone needed
```

There is a real Xcode project (`HyperSend.xcodeproj`) if you want Xcode's
deployment pane.

The CLI (Linux, Windows, macOS — the Node engine in `src/`):

```bash
npm install && npm run build && npm test
```

CI runs that suite on Ubuntu, Windows and macOS on every push; if it is red
there, it is red.

## Before you open a PR

- `mac/test.sh` passes (all 42) and `npm test` passes (all 6).
- The Android receiver still round-trips against the Mac sender if you touched
  anything protocol-side.
- No new dependencies. The zero-dependency property is a feature.
- Match the surrounding code's voice: comments explain *why*, not *what*.

## Good first issues

- A third lane: any second network interface, or a router relay.
- Resume UI: the engine has it; the window does not surface it yet.
- A `bench` mode for the Swift engine mirroring `npm run bench`.

## Reporting bugs

Open an issue with the template — macOS version, Android device, and whether
the failure involves the USB lane are the three details that save the most
back-and-forth.
