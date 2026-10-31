import { test, expect } from '@playwright/test'
import { open, loadVideo, state, seek, setSlider } from './helpers'

// fade.mp4 is 5 s long
test.beforeEach(async ({ page }) => {
  await open(page)
  await loadVideo(page, 'fade.mp4')
})

test('start and end sliders set the clip', async ({ page }) => {
  await setSlider(page, 'start', 200) // the sliders go 0–1000 over the clip
  await setSlider(page, 'end', 700)
  await expect(page.locator('#startV')).toHaveText('1.0 s')
  await expect(page.locator('#endV')).toHaveText('3.5 s')
  const { range } = await state(page)
  expect(range.start).toBeCloseTo(1)
  expect(range.end).toBeCloseTo(3.5)
  await expect(page.locator('#estimate')).toContainText('38 frames at 15/s, 2.5 s')
})

test('the start can never pass the end', async ({ page }) => {
  await setSlider(page, 'end', 400)
  await setSlider(page, 'start', 900)
  const { range } = await state(page)
  expect(range.start).toBeLessThan(range.end)
  expect(range.end - range.start).toBeCloseTo(0.1, 2)
})

test('"Start here" and "End here" use the paused moment', async ({ page }) => {
  await seek(page, 1.2)
  await page.click('#setStart')
  await seek(page, 2.8)
  await page.click('#setEnd')
  const { range } = await state(page)
  expect(range.start).toBeCloseTo(1.2, 1)
  expect(range.end).toBeCloseTo(2.8, 1)
  await expect(page.locator('#startV')).toHaveText('1.2 s')
  await expect(page.locator('#endV')).toHaveText('2.8 s')
})

test('the preview loops inside the clip', async ({ page }) => {
  await setSlider(page, 'start', 400)
  await setSlider(page, 'end', 600) // 2.0–3.0 s
  await page.evaluate(() => window.gifMaker.video.play())
  const times: number[] = []
  for (let i = 0; i < 16; i++) {
    times.push(await page.evaluate(() => window.gifMaker.video.currentTime))
    await page.waitForTimeout(150)
  }
  for (const t of times) {
    expect(t).toBeGreaterThanOrEqual(1.9)
    expect(t).toBeLessThanOrEqual(3.15)
  }
  // it went round at least once in 2.4 s of a 1 s loop
  expect(times.some((t, i) => i > 0 && t < times[i - 1])).toBe(true)
})

test('the timeline slider seeks', async ({ page }) => {
  await page.click('#play')
  await setSlider(page, 'seek', 600)
  await expect.poll(() => page.evaluate(() => window.gifMaker.video.currentTime)).toBeCloseTo(3, 1)
  await expect(page.locator('#clock')).toHaveText('3.0 s')
})
