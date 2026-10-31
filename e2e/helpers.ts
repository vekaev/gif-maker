import { expect, type Page } from '@playwright/test'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

declare global {
  interface Window {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    gifMaker: any
  }
}

const here = path.dirname(fileURLToPath(import.meta.url))
export const fixture = (name: string) => path.join(here, 'fixtures', name)
export const pageFile = pathToFileURL(path.join(here, '..', 'index.html')).href

// Fixtures (all 1280×720 unless noted):
//  fade.mp4  5 s, a flat frame going from black to white; grey level = 51 × seconds
//  split.mp4 3 s, red 0–280 px, green 280–1000 px, blue 1000–1280 px
//  bars.mp4  4 s, 960×540 colour test pattern
//  bars.webm 2 s, colour test pattern in VP9

export async function open(page: Page, url = '/') {
  await page.goto(url)
  await page.waitForFunction(() => !!window.gifMaker)
}

export async function loadVideo(page: Page, name: string) {
  await page.setInputFiles('#file', fixture(name))
  await expect(page.locator('#export')).toBeEnabled()
  await page.waitForFunction(() => window.gifMaker.video.readyState >= 2)
}

export const state = (page: Page) => page.evaluate(() => window.gifMaker.state())

export async function setSlider(page: Page, id: string, value: number) {
  await page.locator(`#${id}`).fill(String(value))
}

// Pause on a moment and wait until the preview has been redrawn for it.
export async function seek(page: Page, t: number) {
  await page.evaluate(async (t) => {
    const v = window.gifMaker.video
    v.pause()
    if (Math.abs(v.currentTime - t) > 1e-3) {
      await new Promise((r) => { v.addEventListener('seeked', r, { once: true }); v.currentTime = t })
    }
  }, t)
  await settle(page)
}

export const settle = (page: Page) =>
  page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))))

// Average colour of a small square in the result preview (#out), in preview pixels.
export async function previewColor(page: Page, x: number, y: number, size = 4) {
  await settle(page)
  return page.evaluate(({ x, y, size }) => {
    const c = document.getElementById('out') as HTMLCanvasElement
    const px = (v: number) => Math.round(v < 0 ? c.width + v - size : v)
    const py = (v: number) => Math.round(v < 0 ? c.height + v - size : v)
    const d = c.getContext('2d')!.getImageData(px(x), py(y), size, size).data
    const sum = [0, 0, 0]
    for (let i = 0; i < d.length; i += 4) { sum[0] += d[i]; sum[1] += d[i + 1]; sum[2] += d[i + 2] }
    const n = d.length / 4
    return sum.map((s) => Math.round(s / n)) as [number, number, number]
  }, { x, y, size })
}

export async function previewStats(page: Page) {
  await settle(page)
  return page.evaluate(() => {
    const c = document.getElementById('out') as HTMLCanvasElement
    const d = c.getContext('2d')!.getImageData(0, 0, c.width, c.height).data
    let maxChroma = 0, sum = 0, sum2 = 0
    for (let i = 0; i < d.length; i += 4) {
      maxChroma = Math.max(maxChroma, Math.max(d[i], d[i + 1], d[i + 2]) - Math.min(d[i], d[i + 1], d[i + 2]))
      const l = (d[i] + d[i + 1] + d[i + 2]) / 3
      sum += l; sum2 += l * l
    }
    const n = d.length / 4, mean = sum / n
    return { maxChroma, mean, sd: Math.sqrt(sum2 / n - mean * mean), w: c.width, h: c.height }
  })
}

export type Exported = { name: string; size: number; type: string; url: string }

// Press the export button and return the newest file from "Your exports".
export async function exportFile(page: Page): Promise<Exported> {
  const items = page.locator('#history .item')
  const before = await items.count()
  await page.click('#export')
  await expect(page.locator('#error')).toBeHidden()
  await expect(items).toHaveCount(before + 1, { timeout: 120_000 })
  await expect(page.locator('#export')).toBeEnabled()
  return page.evaluate(async () => {
    const a = document.querySelector('#history .item a') as HTMLAnchorElement
    const blob = await (await fetch(a.href)).blob()
    return { name: a.download, size: blob.size, type: blob.type, url: a.href }
  })
}

// Decode a GIF with the browser's own decoder: frame count, size, total duration, and per-frame stats.
export function gifInfo(page: Page, url: string) {
  return page.evaluate(async (url) => {
    const blob = await (await fetch(url)).blob()
    const dec = new ImageDecoder({ data: blob.stream(), type: 'image/gif' })
    await dec.completed
    const frames = dec.tracks.selectedTrack!.frameCount
    let width = 0, height = 0, duration = 0
    const centre: number[] = [], greys: boolean[] = [], levels = new Set<number>()
    for (let i = 0; i < frames; i++) {
      const { image } = await dec.decode({ frameIndex: i })
      width = image.displayWidth; height = image.displayHeight
      duration += (image.duration ?? 0) / 1e6
      const c = new OffscreenCanvas(width, height), x = c.getContext('2d')!
      x.drawImage(image, 0, 0)
      image.close()
      const d = x.getImageData(0, 0, width, height).data
      // average a 16×16 block in the middle: with dithering, single pixels deliberately differ from the mean
      let sum = 0
      for (let y = (height >> 1) - 8; y < (height >> 1) + 8; y++) {
        for (let x = (width >> 1) - 8; x < (width >> 1) + 8; x++) { const q = (y * width + x) * 4; sum += (d[q] + d[q + 1] + d[q + 2]) / 3 }
      }
      centre.push(Math.round(sum / 256))
      let grey = true
      for (let p = 0; p < d.length; p += 4) {
        if (d[p] !== d[p + 1] || d[p + 1] !== d[p + 2]) { grey = false }
        if (i === 0) levels.add(d[p])
      }
      greys.push(grey)
    }
    return { frames, width, height, duration, centre, allGrey: greys.every(Boolean), firstFrameLevels: levels.size }
  }, url)
}

// Load a video export into a <video> and look for codec markers in the container.
export function videoInfo(page: Page, url: string) {
  return page.evaluate(async (url) => {
    const v = document.createElement('video')
    v.muted = true
    v.src = url
    await new Promise((resolve, reject) => { v.onloadedmetadata = resolve; v.onerror = () => reject(new Error('the video does not load')) })
    let duration = v.duration
    if (!Number.isFinite(duration)) {
      await new Promise((r) => { v.ondurationchange = r; v.currentTime = 1e9 })
      duration = v.duration
    }
    const text = new TextDecoder('latin1').decode(new Uint8Array(await (await fetch(url)).arrayBuffer()))
    return {
      width: v.videoWidth, height: v.videoHeight, duration,
      avc: text.includes('avc1'), aac: text.includes('mp4a'),
      vp9: text.includes('V_VP9'), opus: text.includes('A_OPUS'),
    }
  }, url)
}
