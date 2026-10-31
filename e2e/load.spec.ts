import { test, expect } from '@playwright/test'
import { open, loadVideo, state } from './helpers'

test.beforeEach(async ({ page }) => { await open(page) })

test('starts with a drop zone and nothing to export', async ({ page }) => {
  await expect(page.locator('#drop')).toBeVisible()
  await expect(page.locator('#drop')).toContainText('Drop a video here')
  await expect(page.locator('#stage')).toBeHidden()
  await expect(page.locator('#export')).toBeDisabled()
  await expect(page.locator('#export')).toHaveText('Make GIF')
  await expect(page.locator('#historyPanel')).toBeHidden()
})

test('loads an MP4 and shows it with a square crop', async ({ page }) => {
  await loadVideo(page, 'bars.mp4')
  await expect(page.locator('#drop')).toBeHidden()
  await expect(page.locator('#stage')).toBeVisible()
  const s = await state(page)
  expect(s.source).toEqual({ w: 960, h: 540 })
  expect(s.crop.w).toBeCloseTo(540)
  expect(s.crop.h).toBeCloseTo(540)
  expect(s.range.start).toBe(0)
  expect(s.range.end).toBeCloseTo(4, 1)
  await expect(page.locator('#estimate')).toContainText('540×540')
  await expect(page.locator('#estimate')).toContainText('no upscaling')
})

test('loads a WebM too', async ({ page }) => {
  await loadVideo(page, 'bars.webm')
  expect((await state(page)).source).toEqual({ w: 1280, h: 720 })
  await expect(page.locator('#estimate')).toContainText('600×600, 30 frames at 15/s, 2.0 s')
})

test('plays the clip in the preview', async ({ page }) => {
  await loadVideo(page, 'fade.mp4')
  const t0 = await page.evaluate(() => window.gifMaker.video.currentTime)
  await page.waitForTimeout(700)
  const t1 = await page.evaluate(() => window.gifMaker.video.currentTime)
  expect(t1).toBeGreaterThan(t0)
  await page.click('#play')
  await expect(page.locator('#play')).toHaveText('▶︎')
  const paused = await page.evaluate(() => window.gifMaker.video.paused)
  expect(paused).toBe(true)
})

test('the app fits the window: no page scroll, the video is fully visible', async ({ page }) => {
  await loadVideo(page, 'fade.mp4')
  const m = await page.evaluate(() => {
    const view = document.getElementById('view')!.getBoundingClientRect()
    return { scrollH: document.documentElement.scrollHeight, innerH: innerHeight, viewBottom: view.bottom, viewRight: view.right, innerW: innerWidth }
  })
  expect(m.scrollH).toBeLessThanOrEqual(m.innerH)
  expect(m.viewBottom).toBeLessThanOrEqual(m.innerH)
  expect(m.viewRight).toBeLessThanOrEqual(m.innerW)
})

test('a phone-sized window stacks the panels without sideways scrolling', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await loadVideo(page, 'fade.mp4')
  const m = await page.evaluate(() => ({ scrollW: document.documentElement.scrollWidth, innerW: innerWidth }))
  expect(m.scrollW).toBeLessThanOrEqual(m.innerW)
  await page.locator('#export').scrollIntoViewIfNeeded()
  await expect(page.locator('#export')).toBeInViewport()
})
