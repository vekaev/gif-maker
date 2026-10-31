import { test, expect } from '@playwright/test'
import { open, loadVideo, state, seek, setSlider, settle } from './helpers'
import type { Page } from '@playwright/test'

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

test.describe('the timeline', () => {
  // x position on the track for a source time
  const xAt = async (page: Page, t: number) => {
    const box = (await page.locator('#track').boundingBox())!
    return { x: box.x + box.width * t / 5, y: box.y + box.height / 2, box }
  }
  const dragHandle = async (page: Page, id: string, to: number) => {
    const h = (await page.locator(id).boundingBox())!
    const target = await xAt(page, to)
    // grab the handle at its inner edge, which sits exactly on the current start / end
    const grabX = id === '#hL' ? h.x + h.width - 1 : h.x + 1
    await page.mouse.move(grabX, h.y + h.height / 2)
    await page.mouse.down()
    await page.mouse.move(target.x, h.y + h.height / 2, { steps: 6 })
    await page.mouse.up()
  }

  test('dragging the yellow handles trims, like QuickTime', async ({ page }) => {
    await dragHandle(page, '#hL', 1)
    await dragHandle(page, '#hR', 3.5)
    const { range } = await state(page)
    expect(range.start).toBeCloseTo(1, 1)
    expect(range.end).toBeCloseTo(3.5, 1)
    await expect(page.locator('#trimInfo')).toHaveText(/1\.0 s – 3\.5 s · 2\.5 s/)
    // the sidebar sliders follow
    await expect(page.locator('#startV')).toHaveText('1.0 s')
    expect(Number(await page.locator('#end').inputValue())).toBeCloseTo(700, -1)
  })

  test('while dragging a handle the big view shows that frame', async ({ page }) => {
    const h = (await page.locator('#hL').boundingBox())!
    const target = await xAt(page, 2)
    await page.mouse.move(h.x + h.width - 1, h.y + h.height / 2)
    await page.mouse.down()
    await page.mouse.move(target.x, h.y + h.height / 2, { steps: 6 })
    expect(await page.evaluate(() => window.gifMaker.video.currentTime)).toBeCloseTo(2, 1)
    expect(await page.evaluate(() => window.gifMaker.video.paused)).toBe(true)
    await page.mouse.up()
  })

  test('clicking the track jumps there', async ({ page }) => {
    await page.click('#play') // pause
    const { x, y } = await xAt(page, 3)
    await page.mouse.click(x, y)
    await expect.poll(() => page.evaluate(() => window.gifMaker.video.currentTime)).toBeCloseTo(3, 1)
    await expect(page.locator('#clock')).toHaveText('3.0 s')
  })

  test('the yellow bar slides the whole clip and keeps its length', async ({ page }) => {
    await setSlider(page, 'start', 0)
    await setSlider(page, 'end', 400) // 0–2 s
    const bar = (await page.locator('#grab').boundingBox())!
    const { box } = await xAt(page, 0)
    await page.mouse.move(bar.x + bar.width / 2, bar.y + bar.height / 2)
    await page.mouse.down()
    await page.mouse.move(bar.x + bar.width / 2 + box.width * 0.3, bar.y + bar.height / 2, { steps: 6 }) // +1.5 s
    await page.mouse.up()
    let { range } = await state(page)
    expect(range.start).toBeCloseTo(1.5, 1)
    expect(range.end - range.start).toBeCloseTo(2, 2)
    // it stops at the end of the video
    await page.mouse.move(bar.x + bar.width / 2 + box.width * 0.3, bar.y + bar.height / 2)
    await page.mouse.down()
    await page.mouse.move(box.x + box.width + 200, bar.y + bar.height / 2, { steps: 6 })
    await page.mouse.up()
    ;({ range } = await state(page))
    expect(range.end).toBeCloseTo(5, 1)
    expect(range.end - range.start).toBeCloseTo(2, 2)
  })

  test('the filmstrip shows the clip (fade: dark on the left, bright on the right)', async ({ page }) => {
    await expect.poll(() => page.evaluate(() => {
      const c = document.getElementById('strip') as HTMLCanvasElement
      const x = c.getContext('2d')!
      const at = (f: number) => x.getImageData(Math.round(f * c.width), c.height >> 1, 1, 1).data[0]
      return at(0.95) - at(0.05)
    }), { timeout: 10_000 }).toBeGreaterThan(150)
  })

  test('Space plays and pauses', async ({ page }) => {
    await page.click('#view')
    const before = await page.evaluate(() => window.gifMaker.video.paused)
    await page.keyboard.press('Space')
    await settle(page)
    expect(await page.evaluate(() => window.gifMaker.video.paused)).toBe(!before)
  })
})
