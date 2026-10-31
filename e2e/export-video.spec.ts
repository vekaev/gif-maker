import { test, expect, type Page } from '@playwright/test'
import { open, loadVideo, setSlider, exportFile, videoInfo } from './helpers'

test.beforeEach(async ({ page }) => { await open(page) })

// Linux Chrome has no AAC encoder; the app then leaves the MP4 without sound and says nothing breaks.
const canEncodeAac = (page: Page) => page.evaluate(() =>
  AudioEncoder.isConfigSupported({ codec: 'mp4a.40.2', sampleRate: 48000, numberOfChannels: 1, bitrate: 32000 })
    .then((r) => !!r.supported).catch(() => false))

// Decode the middle frame of an exported video and measure how colourful it is.
const videoChroma = (page: Page, url: string) => page.evaluate(async (url) => {
  const v = document.createElement('video')
  v.muted = true; v.src = url
  await new Promise((r) => { v.onloadeddata = r })
  await new Promise((r) => { v.onseeked = r; v.currentTime = 0.5 })
  const c = new OffscreenCanvas(v.videoWidth, v.videoHeight), x = c.getContext('2d')!
  x.drawImage(v, 0, 0)
  const d = x.getImageData(0, 0, c.width, c.height).data
  let max = 0
  for (let i = 0; i < d.length; i += 16) max = Math.max(max, Math.max(d[i], d[i + 1], d[i + 2]) - Math.min(d[i], d[i + 1], d[i + 2]))
  return max
}, url)

test('the format picker explains each format and shows only the settings that apply', async ({ page }) => {
  await loadVideo(page, 'bars.mp4')
  const rows = async () => ({
    width: await page.locator('#widthRow').isVisible(),
    sound: await page.locator('#audioRow').isVisible(),
    dither: await page.locator('#ditherRow').isVisible(),
  })
  await expect(page.locator('#format')).toHaveValue('gif')
  expect(await rows()).toEqual({ width: true, sound: false, dither: true })

  await page.selectOption('#format', 'mp4')
  await expect(page.locator('#export')).toHaveText('Make MP4')
  await expect(page.locator('#formatHint')).toContainText('Telegram sends it as a video')
  expect(await rows()).toEqual({ width: true, sound: true, dither: false })

  await page.selectOption('#format', 'webm')
  await expect(page.locator('#export')).toHaveText('Make WebM')
  expect(await rows()).toEqual({ width: true, sound: true, dither: false })

  await page.selectOption('#format', 'sticker')
  await expect(page.locator('#export')).toHaveText('Make sticker')
  await expect(page.locator('#formatHint')).toContainText('@Stickers')
  expect(await rows()).toEqual({ width: false, sound: false, dither: false })
})

test('MP4: H.264 at the chosen size and length, with a silent track for Telegram', async ({ page }) => {
  await loadVideo(page, 'fade.mp4')
  await page.selectOption('#format', 'mp4')
  await setSlider(page, 'end', 400) // 2 s
  await setSlider(page, 'width', 480)
  await setSlider(page, 'fps', 30)
  const file = await exportFile(page)
  expect(file.name).toBe('fade-480x480.mp4')
  expect(file.type).toBe('video/mp4')
  const info = await videoInfo(page, file.url)
  expect(info).toMatchObject({ width: 480, height: 480, avc: true })
  expect(info.duration).toBeGreaterThan(1.9)
  expect(info.duration).toBeLessThan(2.2)
  expect(info.aac).toBe(await canEncodeAac(page))

  await page.locator('#audio').uncheck()
  const silent = await videoInfo(page, (await exportFile(page)).url)
  expect(silent.aac).toBe(false)
})

test('MP4 keeps the black-and-white look', async ({ page }) => {
  await loadVideo(page, 'bars.mp4')
  await page.selectOption('#format', 'mp4')
  await page.click('#filters [data-f=noir]')
  await setSlider(page, 'end', 250)
  await setSlider(page, 'width', 360)
  const file = await exportFile(page)
  expect(file.name).toBe('bars-noir-360x360.mp4')
  expect(await videoChroma(page, file.url)).toBeLessThan(12)
})

test('WebM: VP9 with an optional Opus track', async ({ page }) => {
  await loadVideo(page, 'bars.webm')
  await page.selectOption('#format', 'webm')
  await setSlider(page, 'width', 640)
  await page.getByRole('button', { name: '16:9' }).click()
  const file = await exportFile(page)
  expect(file.name).toBe('bars-640x360.webm')
  const info = await videoInfo(page, file.url)
  expect(info).toMatchObject({ width: 640, height: 360, vp9: true, opus: true })
  expect(info.duration).toBeGreaterThan(1.9)
  expect(info.duration).toBeLessThan(2.1)
  expect(await videoChroma(page, file.url)).toBeGreaterThan(100)

  await page.locator('#audio').uncheck()
  expect((await videoInfo(page, (await exportFile(page)).url)).opus).toBe(false)
})

test('Telegram sticker: 512 px, at most 3 s and 256 KB, no sound', async ({ page }) => {
  await loadVideo(page, 'bars.mp4') // 4 s, so it gets cut
  await page.selectOption('#format', 'sticker')
  await page.getByRole('button', { name: 'Original' }).click()
  await setSlider(page, 'fps', 60)
  await expect(page.locator('#estimate')).toContainText('512×288, 90 frames at 30/s, 3.0 s')
  await expect(page.locator('#estimate .warn')).toContainText('The clip plays 4.0 s, but Telegram stickers stop at 3 s')
  const file = await exportFile(page)
  expect(file.name).toBe('bars-sticker-512x288.webm')
  expect(file.size).toBeLessThanOrEqual(256 * 1024)
  const info = await videoInfo(page, file.url)
  expect(info).toMatchObject({ width: 512, height: 288, vp9: true, opus: false })
  expect(info.duration).toBeLessThanOrEqual(3.05)
})

test('a square sticker is 512×512', async ({ page }) => {
  await loadVideo(page, 'fade.mp4')
  await page.selectOption('#format', 'sticker')
  await setSlider(page, 'end', 200)
  const file = await exportFile(page)
  expect(file.name).toBe('fade-sticker-512x512.webm')
  expect((await videoInfo(page, file.url))).toMatchObject({ width: 512, height: 512 })
})
