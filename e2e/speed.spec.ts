import { test, expect } from '@playwright/test'
import { open, loadVideo, state, seek, setSlider, exportFile, gifInfo, videoInfo } from './helpers'

// fade.mp4: 5 s, grey level = 51 × seconds
test.beforeEach(async ({ page }) => {
  await open(page)
  await loadVideo(page, 'fade.mp4')
  await setSlider(page, 'width', 240)
})

test('the whole clip at 2× halves its length and keeps every moment', async ({ page }) => {
  await setSlider(page, 'end', 800) // 0–4 s
  await setSlider(page, 'speed', 100) // 2^(100/100) = 2×
  await expect(page.locator('#speedV')).toHaveText('2×')
  await expect(page.locator('#estimate')).toContainText('2.0 s · 15 fps · 30 frames')
  await expect(page.locator('#trimInfo')).toContainText('plays 2.0 s')
  const gif = await gifInfo(page, (await exportFile(page)).url)
  expect(gif.frames).toBe(30)
  expect(gif.duration).toBeCloseTo(2, 2)
  expect(gif.centre[0]).toBeLessThan(10) // 0 s
  expect(gif.centre[29]).toBeGreaterThan(185) // 3.87 s of the source
})

test('a faster part plays faster and shortens only itself', async ({ page }) => {
  await seek(page, 2)
  await page.click('#addPart') // 1.5–2.5 s at 2×
  let s = await state(page)
  expect(s.parts).toHaveLength(1)
  expect(s.parts[0]).toMatchObject({ from: 1.5, to: 2.5, speed: 2 })
  await expect(page.locator('#parts .band')).toHaveText(['2×'])
  await expect(page.locator('#partEditor')).toBeVisible()

  // make it 1–3 s at 4×
  await seek(page, 1)
  await page.click('#partFrom')
  await seek(page, 3)
  await page.click('#partTo')
  await setSlider(page, 'partSpeed', 200)
  await expect(page.locator('#partSpeedV')).toHaveText('4×')
  await expect(page.locator('#partInfo')).toContainText('1.0 s – 3.0 s: plays at 4×')
  s = await state(page)
  expect(s.length).toBeCloseTo(1 + 0.5 + 2, 3) // 0–1 s, 1–3 s in 0.5 s, 3–5 s
  await expect(page.locator('#estimate')).toContainText('3.5 s')

  const gif = await gifInfo(page, (await exportFile(page)).url)
  expect(gif.frames).toBe(53)
  expect(gif.duration).toBeCloseTo(53 / 15, 1)
  // 1 s into the GIF the source is at 1 s; 0.4 s later it is already at 2.6 s
  expect(Math.abs(gif.centre[15] - 51)).toBeLessThan(10)
  expect(Math.abs(gif.centre[21] - 51 * 2.6)).toBeLessThan(12)
})

test('the preview plays a fast part at its speed', async ({ page }) => {
  await seek(page, 2)
  await page.click('#addPart')
  await seek(page, 2)
  await page.evaluate(() => window.gifMaker.video.play())
  await expect.poll(() => page.evaluate(() => window.gifMaker.video.playbackRate)).toBe(2)
})

test('a part can be selected from its band and deleted', async ({ page }) => {
  await seek(page, 1)
  await page.click('#addPart')
  await seek(page, 4)
  await page.click('#addPart')
  await expect(page.locator('#parts .band')).toHaveCount(2)
  await page.locator('#parts .band').first().click()
  await expect(page.locator('#parts .band.on')).toHaveCount(1)
  expect((await state(page)).parts.length).toBe(2)
  await page.click('#partDelete')
  await expect(page.locator('#parts .band')).toHaveCount(1)
  await expect(page.locator('#partEditor')).toBeHidden()
  expect((await state(page)).parts[0].from).toBeCloseTo(3.5, 1)
})

test('a sticker shows what doesn’t fit in 3 s, and “Fit into 3 s” speeds it up', async ({ page }) => {
  await page.selectOption('#format', 'sticker')
  await expect(page.locator('#over')).toBeVisible() // 5 s clip: the last 2 s hatched in red
  await expect(page.locator('#estimate .warn')).toContainText('The clip plays 5.0 s')
  await expect(page.locator('#fit3')).toBeVisible()

  await page.click('#fit3')
  expect((await state(page)).speed).toBeCloseTo(5 / 3, 3)
  expect((await state(page)).length).toBeCloseTo(3, 3)
  await expect(page.locator('#over')).toBeHidden()
  await expect(page.locator('#estimate .warn')).toHaveCount(0)

  const info = await videoInfo(page, (await exportFile(page)).url)
  expect(info.duration).toBeLessThanOrEqual(3.05)
  expect(info.duration).toBeGreaterThan(2.9)
})

test('only stickers are limited: a GIF keeps all 5 s', async ({ page }) => {
  await expect(page.locator('#fit3')).toBeHidden()
  await expect(page.locator('#over')).toBeHidden()
  const gif = await gifInfo(page, (await exportFile(page)).url)
  expect(gif.frames).toBe(75)
  expect(gif.duration).toBeCloseTo(5, 2)
})

test('a new file starts at normal speed again', async ({ page }) => {
  await setSlider(page, 'speed', 100)
  await seek(page, 2)
  await page.click('#addPart')
  await loadVideo(page, 'split.mp4')
  const s = await state(page)
  expect(s.speed).toBe(1)
  expect(s.parts).toHaveLength(0)
  await expect(page.locator('#speedV')).toHaveText('1×')
})
