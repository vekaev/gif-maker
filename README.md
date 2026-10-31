<div align="center">

<img src="docs/icon.svg" width="112" alt="GIF Maker icon" />

# GIF Maker

**Crop, trim, tone. Nothing else.**

Turn a video into a sharp GIF, MP4, WebM or Telegram sticker right in your browser: crop it to 1:1,<br>
cut the moment you want, lift a dark clip, give it a black-and-white film look. Nothing is uploaded.

[![Runs in the browser](https://img.shields.io/badge/runs%20in-the%20browser-4f8cff?style=flat-square&logo=googlechrome&logoColor=white)](https://vekaev.github.io/gif-maker/)
[![One HTML file](https://img.shields.io/badge/one%20HTML%20file-no%20build-3a3a3a?style=flat-square&logo=html5&logoColor=white)](index.html)
[![License: MIT](https://img.shields.io/badge/license-MIT-3a3a3a?style=flat-square)](LICENSE)
[![Status: early](https://img.shields.io/badge/status-early-d69e2e?style=flat-square)](#status)

<br>

[![Open GIF Maker](https://img.shields.io/badge/Open-GIF%20Maker-4f8cff?style=for-the-badge&logo=googlechrome&logoColor=white)](https://vekaev.github.io/gif-maker/)

<sub>Free, no sign-up, no install. Works best in Chrome or Edge on a computer.</sub>

<br><br>

<img src="docs/screenshot.png" alt="GIF Maker: a video with a square crop frame on the left, and on the right a black-and-white preview, the filter list with Leica Monochrom selected, and the crop controls" width="100%">

<sub>The demo clip is a generated Mandelbrot zoom; the preview shows the Leica Monochrom look.</sub>

<p>
  <a href="#features">Features</a> ·
  <a href="#formats">Formats</a> ·
  <a href="#black-and-white-looks">B&amp;W looks</a> ·
  <a href="#why-it-looks-clean">Quality</a> ·
  <a href="#telegram">Telegram</a> ·
  <a href="#get-started">Get started</a> ·
  <a href="#privacy">Privacy</a>
</p>

</div>

## Features

- **Crop to any shape.** 1:1, 4:5, 9:16, 16:9 or the original. Drag the frame, scroll to zoom, or snap it to
  the left edge, the center or the right edge in one click. Everything outside the frame dims, so you see
  exactly what you'll get.
- **Trim to the moment.** Start and end sliders, or pause where you want and press **Start here** /
  **End here**. The preview loops only that part.
- **Fix the light.** Exposure, Shadows, Contrast, Saturation and Warmth, live as you drag. **✨ Auto** lifts
  a dark clip so the highlights sit near white and the midtones open up. **Reset** puts it all back.
- **Black-and-white film looks.** Six of them: iPhone Mono, Silvertone and Noir, Leica Monochrom and Leica
  High Contrast, Fuji Acros. Plus optional grain.
- **Four formats.** GIF by default, or MP4, WebM and a ready-to-send Telegram video sticker. See
  [Formats](#formats).
- **Your exports stay at hand.** Every file you make lands in **Your exports** with a moving thumbnail, its
  size and time. Save any of them again later, even after a reload, or remove the ones you don't need.
- **Full quality.** Frames come from the video at its original resolution and are scaled down once, with
  high-quality smoothing. It never upscales: ask for more pixels than the crop has and it tells you.
- **Stays responsive.** GIF encoding runs in a background worker and the preview only redraws when
  something changed, so a big HEVC screen recording doesn't freeze the tab.

## Formats

| Format | Best for | Notes |
|---|---|---|
| **GIF** | Anywhere that only takes GIFs | Up to 256 colours, so files are the biggest. Up to 1920 px, up to 50 frames/s. |
| **MP4** (H.264) | Telegram, iMessage, WhatsApp, the web | Full colour, small files, plays everywhere. Adds a silent sound track by default so Telegram sends it as a video, not a GIF. |
| **WebM** (VP9) | The web, Discord | Full colour, small files. Optional silent Opus track. |
| **Telegram sticker** | Telegram video stickers | WebM VP9, 512 px on the longer side, up to 3 s, no sound, under 256 KB: the size is checked and the bitrate stepped down until it fits. |

MP4 and WebM are encoded with your browser's own video encoder (WebCodecs). If a browser can't encode a
format at that size, the app says so instead of producing a broken file.

## Black-and-white looks

Each look turns colour into grey its own way (like a coloured filter in front of the lens) and has its own
tone curve:

| Look | What it does |
|---|---|
| **iPhone Mono** | Plain, neutral black and white. |
| **iPhone Silvertone** | Brighter, a little more contrast, a faint cool silver in the midtones. |
| **iPhone Noir** | Deep blacks, clipped whites, hard contrast; blues go dark. |
| **Leica Monochrom** | Neutral and wide-ranged, with a gentle S-curve. |
| **Leica High Contrast** | Punchy, with rich blacks. |
| **Fuji Acros** | Acros with a yellow filter: darker skies, glowing skin, rich shadows. |

These are approximations made by eye. Apple, Leica and Fujifilm don't publish their recipes.

<p align="center">
  <img src="docs/sample-leica.gif" width="360" alt="A square black-and-white GIF of a Mandelbrot zoom, exported with the Leica Monochrom look">
  <br>
  <sub>A real export: Leica Monochrom, 360 px, 12 frames/s, 3 s, 2.3 MB.</sub>
</p>

**Grain** is a separate slider and starts at zero. In a GIF, grain barely compresses: even a little makes
the file 5–8× bigger. In MP4 and WebM it costs far less.

## Why it looks clean

GIFs made in the browser often show contour lines on skin and walls, and blotches that crawl from frame to
frame. GIF Maker avoids both:

- **One palette for the whole clip.** It samples frames across the clip and builds a single 256-colour
  palette, so colours don't jump between frames.
- **Exact colour matching.** Each pixel goes to its truly nearest palette colour. The usual shortcut rounds
  colours to 32–64 levels per channel first, which is what draws the contour lines.
- **Ordered dithering.** An 8×8 Bayer pattern smooths gradients. Unlike error diffusion it stays still from
  frame to frame, so there's no "boiling" noise. Turn it off for a smaller file.
- **All 256 greys for black and white.** B&W looks use every grey level instead of a quantized palette, so
  there's no banding at all.
- **Exact timing.** GIF delays are whole hundredths of a second. The delays alternate, so a 4-second clip
  stays 4 seconds at any frame rate.

## Telegram

- **As a GIF:** export **GIF** or **MP4** without the sound track and send it. Telegram stores GIFs as
  silent MP4s anyway, so the MP4 looks better and is smaller.
- **As a video:** export **MP4** with **Silent sound track** on (the default). Telegram sends a video with
  a sound track as a regular video.
- **As a sticker:** export **Telegram sticker**, then send the file to [@Stickers](https://t.me/stickers)
  with `/newvideo` (new pack) or `/addsticker`. Requirements are in
  [Telegram's guide](https://core.telegram.org/stickers/webm-vp9-encoding). Sticker packs can be opened by
  anyone with their link.

## Get started

Open **[vekaev.github.io/gif-maker](https://vekaev.github.io/gif-maker/)**, drop a video on the page and
press **Make GIF**.

Or run it from your own copy. It's a single HTML file, no build step:

```bash
git clone https://github.com/vekaev/gif-maker && cd gif-maker
open index.html            # or double-click it
```

It works opened straight from disk too.

## Under the hood

One `index.html`, plain JavaScript, no framework.

- **Decoding:** the browser's `<video>` element, so anything your browser plays works (MP4, MOV, HEVC,
  WebM…).
- **GIF:** [gifenc](https://github.com/mattdesl/gifenc) writes the file. Palette mapping, dithering and the
  colour pipeline are custom, and run in a Web Worker.
- **MP4 / WebM:** [WebCodecs](https://developer.mozilla.org/docs/Web/API/WebCodecs_API) encodes, and
  [mp4-muxer](https://github.com/Vanilagy/mp4-muxer) and [webm-muxer](https://github.com/Vanilagy/webm-muxer)
  package the result.
- **Exports list:** IndexedDB, in your browser only.

## Privacy

Your video never leaves your computer: it's read, processed and encoded on the page. The only network
requests load the three libraries above from jsDelivr. Exports are kept in this browser's storage until
you remove them or clear site data. No analytics, no cookies, no accounts.

## Status

Early, made for its author's own clips. Tested in Chrome on macOS. Issues and ideas welcome.

## License

MIT
