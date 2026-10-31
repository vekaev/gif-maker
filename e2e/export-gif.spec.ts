import { test, expect } from '@playwright/test'
import { open, loadVideo, setSlider, exportFile, gifInfo, pageFile } from './helpers'

test.beforeEach(async ({ page }) => { await open(page) })

test('a trimmed GIF has the right frames, size, length and moments', async ({ page }) => {
  await loadVideo(page, 'fade.mp4')
  await setSlider(page, 'start', 200) // 1.0 s
  await setSlider(page, 'end', 800) // 4.0 s
  await setSlider(page, 'width', 240)
  const file = await exportFile(page)
  expect(file.name).toBe('fade-240x240.gif')
  expect(file.type).toBe('image/gif')

  const gif = await gifInfo(page, file.url)
  expect(gif.frames).toBe(45) // 3 s at 15 frames/s
  expect(gif).toMatchObject({ width: 240, height: 240 })
  expect(gif.duration).toBeCloseTo(3, 2) // GIF delays are whole centiseconds; they alternate to keep the length
  // grey = 51 × seconds: the clip runs from 1.0 s to 3.93 s
  expect(gif.centre[0]).toBeGreaterThan(43)
  expect(gif.centre[0]).toBeLessThan(60)
  expect(gif.centre[22]).toBeGreaterThan(115)
  expect(gif.centre[22]).toBeLessThan(137)
  expect(gif.centre[44]).toBeGreaterThan(188)
  expect(gif.centre[44]).toBeLessThan(212)
  // a smooth ramp: never darker than the frame before, no jumps (a sparse palette makes steps of 10+)
  for (let i = 1; i < gif.centre.length; i++) {
    expect(gif.centre[i]).toBeGreaterThanOrEqual(gif.centre[i - 1])
    expect(gif.centre[i] - gif.centre[i - 1]).toBeLessThanOrEqual(8)
  }
})

test('colour settings are baked into the GIF', async ({ page }) => {
  await loadVideo(page, 'fade.mp4')
  await setSlider(page, 'start', 200)
  await setSlider(page, 'end', 400)
  await setSlider(page, 'width', 240)
  await setSlider(page, 'exposure', 100) // twice as bright
  const gif = await gifInfo(page, (await exportFile(page)).url)
  expect(gif.centre[0]).toBeGreaterThan(90)
  expect(gif.centre[0]).toBeLessThan(115)
})

test('a black-and-white GIF is pure grey and uses many grey levels', async ({ page }) => {
  await loadVideo(page, 'bars.mp4')
  await page.click('#filters [data-f=leica]')
  await setSlider(page, 'end', 250) // 1 s
  await setSlider(page, 'width', 360)
  const file = await exportFile(page)
  expect(file.name).toBe('bars-leica-360x360.gif')
  const gif = await gifInfo(page, file.url)
  expect(gif.allGrey).toBe(true)
  expect(gif.firstFrameLevels).toBeGreaterThan(60)
})

test('dithering can be turned off for a smaller file', async ({ page }) => {
  await loadVideo(page, 'bars.mp4')
  await setSlider(page, 'end', 250)
  await setSlider(page, 'width', 360)
  const dithered = await exportFile(page)
  await page.locator('#dither').uncheck()
  const plain = await exportFile(page)
  expect(plain.size).toBeLessThan(dithered.size)
  const gif = await gifInfo(page, plain.url)
  expect(gif.frames).toBe(15)
})

test('GIF frame rate tops out at 50 frames/s', async ({ page }) => {
  await loadVideo(page, 'fade.mp4')
  await setSlider(page, 'end', 200) // 1 s
  await setSlider(page, 'width', 240)
  await setSlider(page, 'fps', 60)
  await expect(page.locator('#estimate')).toContainText('50 frames at 50/s')
  await expect(page.locator('#estimate')).toContainText('GIF tops out at 50 frames/s')
  const gif = await gifInfo(page, (await exportFile(page)).url)
  expect(gif.frames).toBe(50)
  expect(gif.duration).toBeCloseTo(1, 2)
})

test('encoding runs in a worker and never freezes the page', async ({ page }) => {
  await loadVideo(page, 'bars.mp4')
  await setSlider(page, 'width', 540)
  await page.evaluate(() => {
    (window as any).longTasks = []
    new PerformanceObserver((l) => l.getEntries().forEach((e) => (window as any).longTasks.push(e.duration))).observe({ type: 'longtask' })
  })
  await exportFile(page)
  expect(await page.evaluate(() => window.gifMaker.usedWorker)).toBe(true)
  const longest = await page.evaluate(() => Math.max(0, ...(window as any).longTasks))
  expect(longest).toBeLessThan(800)
})

test('works when the page is opened straight from disk', async ({ page }) => {
  await open(page, pageFile)
  await loadVideo(page, 'fade.mp4')
  await setSlider(page, 'end', 200)
  await setSlider(page, 'width', 240)
  const gif = await gifInfo(page, (await exportFile(page)).url)
  expect(gif.frames).toBe(15)
  expect(await page.evaluate(() => window.gifMaker.usedWorker)).toBe(true)
})
