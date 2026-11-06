# 1. One repository; a native Mac app next to the web version

The web version came first. The owner then asked for a Mac app "like Photo Minimalist", public, with an icon.

**Decision.** The Mac app is native SwiftUI over AVFoundation and Core Image, not a wrapper around the page: speed was
the complaint, and hardware decoding and GPU colour answer it. It lives in the same repository, so one README, one
Download button and one set of fixtures serve both, and the looks stay in step.

**VP9.** macOS has no public VP9 encoder and Telegram stickers must be VP9. Building and shipping libvpx was the
obvious route; WebKit already contains an encoder, reachable through WebCodecs in a hidden web view, which needs no
third-party binary and covers Intel too. Its limit: it depends on the system's WebKit, so on a macOS whose WebKit
can't do it, stickers and WebM show a clear error while GIF and MP4 keep working.

**WebM in.** AVFoundation can't read WebM, so a small parser finds the frames, WebKit decodes them, and they go into a
temporary ProRes movie that edits like any other video. Sound in a WebM source is ignored, as it is for every source.

**Not done.** Opus sound in WebM output.
