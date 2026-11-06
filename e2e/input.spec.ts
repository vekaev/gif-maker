import { test, expect } from '@playwright/test'
import { open, loadVideo, fixture, state, seek, setSlider, previewColor, exportFile, gifInfo, videoInfo } from './helpers'

// fade.gif: 320×320, 20 frames at 10/s, black to white over 2 s (frame i is 255 × i / 20)
// photo.png: 1280×720 still, red 0–280 px, green 280–1000 px, blue 1000–1280 px
test.beforeEach(async ({ page }) => { await open(page) })

const grey = ([r, g, b]: number[]) => Math.round((r + g + b) / 3)

test.describe('a GIF as the source', () => {
  test.beforeEach(async ({ page }) => { await loadVideo(page, 'fade.gif') })

  test('opens with its size and length, and plays', async ({ page }) => {
    const s = await state(page)
    expect(s.source).toEqual({ w: 320, h: 320 })
    expect(s.range.end).toBeCloseTo(2, 2)
    await expect(page.locator('#endV')).toHaveText('2.0 s')
    const t0 = await page.evaluate(() => window.gifMaker.video.currentTime)
    await page.waitForTimeout(400)
    expect(await page.evaluate(() => window.gifMaker.video.currentTime)).not.toBe(t0)
  })

  test('shows the right frame for each moment', async ({ page }) => {
    await seek(page, 0.05)
    expect(grey(await previewColor(page, 50, 50))).toBeLessThan(20)
    await seek(page, 1.0) // frame 10
    const mid = grey(await previewColor(page, 50, 50))
    expect(mid).toBeGreaterThan(110)
    expect(mid).toBeLessThan(145)
    await seek(page, 1.95) // frame 19
    expect(grey(await previewColor(page, 50, 50))).toBeGreaterThan(220)
  })

  test('turns into a Telegram video sticker', async ({ page }) => {
    await page.selectOption('#format', 'sticker')
    const file = await exportFile(page)
    expect(file.name).toBe('fade-telegram-sticker.webm')
    expect(file.size).toBeLessThanOrEqual(256 * 1024)
    const info = await videoInfo(page, file.url)
    expect(info).toMatchObject({ width: 512, height: 512, vp9: true, opus: false })
    expect(info.duration).toBeGreaterThan(1.9)
    expect(info.duration).toBeLessThanOrEqual(2.05)
  })

  test('turns into an MP4 and a new GIF, with the colour settings', async ({ page }) => {
    await page.selectOption('#format', 'mp4')
    const mp4 = await videoInfo(page, (await exportFile(page)).url)
    expect(mp4).toMatchObject({ width: 320, height: 320, avc: true })
    expect(mp4.duration).toBeGreaterThan(1.9)

    await page.selectOption('#format', 'gif')
    await page.click('#filters [data-f=noir]')
    const gif = await gifInfo(page, (await exportFile(page)).url)
    expect(gif).toMatchObject({ width: 320, height: 320, frames: 30, allGrey: true })
    expect(gif.duration).toBeCloseTo(2, 2)
  })
})

test('an animated GIF loads by drag and drop too', async ({ page }) => {
  const buffer = (await import('node:fs')).readFileSync(fixture('fade.gif'))
  const data = await page.evaluateHandle((bytes) => {
    const dt = new DataTransfer()
    dt.items.add(new File([new Uint8Array(bytes)], 'dropped.gif', { type: 'image/gif' }))
    return dt
  }, [...buffer])
  await page.dispatchEvent('#drop', 'drop', { dataTransfer: data })
  await expect(page.locator('#export')).toBeEnabled()
  expect((await state(page)).source).toEqual({ w: 320, h: 320 })
})

test('a photo becomes a 3-second clip', async ({ page }) => {
  await loadVideo(page, 'photo.png')
  const s = await state(page)
  expect(s.source).toEqual({ w: 1280, h: 720 })
  expect(s.range.end).toBe(3)
  await page.getByRole('button', { name: '← Left edge' }).click()
  const [r, g] = await previewColor(page, 2, 100)
  expect(r).toBeGreaterThan(150)
  expect(g).toBeLessThan(80)
  await setSlider(page, 'width', 240)
  const gif = await gifInfo(page, (await exportFile(page)).url)
  expect(gif.frames).toBe(45)
  expect(gif.duration).toBeCloseTo(3, 2)
})

test('a file that is not a video says so', async ({ page }) => {
  await page.setInputFiles('#file', fixture('broken.mp4'))
  await expect(page.locator('#error')).toBeVisible()
  await expect(page.locator('#error')).toContainText('can’t play that file')
  await expect(page.locator('#export')).toBeDisabled()
})

test('switching from a GIF to a video and back works', async ({ page }) => {
  await loadVideo(page, 'fade.gif')
  await loadVideo(page, 'split.mp4')
  expect((await state(page)).source).toEqual({ w: 1280, h: 720 })
  expect((await state(page)).range.end).toBeCloseTo(3, 1)
  await loadVideo(page, 'fade.gif')
  expect((await state(page)).source).toEqual({ w: 320, h: 320 })
})
