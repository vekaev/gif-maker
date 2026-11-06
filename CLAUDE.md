# GIF Maker: working rules

**Crop, trim, tone. Nothing else.** Keep it that small: every feature must defend its place against that line.

Two apps, one product, one repository: the **Mac app** (native SwiftUI, `App/` + `Core/`) and the **web version**
(`index.html`, GitHub Pages).

| | Mac | Web |
|---|---|---|
| UI | `App/` | `index.html` |
| Engine | `Core/` (no UI) | `index.html` |
| Tests | `scripts/test-core.sh` (`Tests/main.swift`) | `npm test` (`e2e/`, Playwright in Google Chrome) |
| Run | `scripts/install-mac.sh` | `npm start`, http://localhost:4173 |
| Ships with | `scripts/release.sh X.Y.Z notes.md` | a push to `main` (CI tests, then Pages) |

iPhone / iPad: n/a for now.

## Rule: every change ships on both

The owner should never have to ask twice. For any feature, fix or design change:

1. **Task list with two sides before writing code**: one task for Mac, one for web.
2. **Same recipes, same maths.** Looks (`Core/Model.swift`, `FILTERS` in `index.html`), speed maps, file names and
   the 3-second sticker rule must mean the same thing on both. If something truly can't apply to one, record it
   in the README's "Mac and web" table.
3. **Test both**: `scripts/test-core.sh` and `npm test`. Tests check the output files themselves, not just the UI.
4. **Build, restart the Mac app with the new build when a change is done**, without asking: `scripts/install-mac.sh`.
5. **Check on screen**: computer-use for the Mac app with the owner's permission, Playwright for the web. Say what
   was and wasn't seen. The owner's window may be in use: test on a separate copy, with another bundle ID.
6. **Commit and push each finished fix** to `main`.

## Design

The owner's taste: monochrome, Notion / Apple minimal, with Stoic's warmth. Paper and ink (`App/Theme.swift`), a heavy
lowercase headline ending in a period on the start page, one black pill per screen, cards with hairlines, no
decoration. Colour belongs to the picture, and to the one thing borrowed from QuickTime: the yellow trim frame.

## Things learned the hard way

- **Seeking per frame is what makes exports crawl.** Read frames in order: `AVAssetReader` on the Mac, WebCodecs
  through mediabunny on the web. 12 s became 2 s on a 2880×1620 HEVC clip.
- **Don't let Core Image convert SDR video.** Video buffers are opened without a colour space, or BT.709's curve gets
  converted to sRGB and midtones lift (137 instead of 125). HDR does get converted.
- **AVAssetWriter holds each track back for the other.** Never block on the audio input: the silent track runs ahead of
  the picture, and `endSession` cuts what's left over.
- **AVFoundation can't read WebM.** `Core/WebMImport.swift` parses it, decodes in WebKit, writes a temporary ProRes movie.
- **macOS has no VP9 encoder; WebKit does**, through WebCodecs in a hidden `WKWebView` (`Core/VideoWriters.swift`). It
  needs a secure base URL and `inactiveSchedulingPolicy = .none`.
- **A WebM sent into a Telegram chat stays a file.** Stickers go through @Stickers with `/newvideo`, as a file, title
  first. Static packs (`/newpack`) only take PNG/WEBP.
- GIF: one palette for the clip, exact nearest colour, Bayer dithering, all 256 greys for B&W, delays from rounded
  timestamps. See `Core/GIFWriter.swift`.
- Test exports go to a temp folder, and the update test needs a free port (8765 is DayGate's).

## Updates and installer (Mac)

Sparkle 2 (`App/Updater.swift`), feed at `releases/latest/download/appcast.xml`, key in the login keychain (account
`gif-maker`). DMG: `Support/DMG` via dmgbuild. One-line installer: `scripts/install.sh`. `scripts/release.sh` does the
rest. Never replace an asset on an existing release: fixing a DMG means a new patch release. Signed with the owner's
Apple Development certificate (`scripts/signing.sh`) so permissions survive updates; not notarized.

## Owner's data

The owner's real files are read-only for tests, and their personal recordings aren't test material at all: use
the generated clips in `e2e/fixtures`.
