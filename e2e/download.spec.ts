import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { open, loadVideo, fixture, setSlider, exportFile, gifInfo } from './helpers'

test.beforeEach(async ({ page }) => { await open(page) })

test('the download button sits at the very top, always in view', async ({ page }) => {
  await loadVideo(page, 'fade.mp4')
  const box = (await page.locator('#export').boundingBox())!
  expect(box.y).toBeLessThan(40)
  await page.locator('main > aside').evaluate((el) => { el.scrollTop = 99999 })
  await expect(page.locator('#export')).toBeInViewport()
  await expect(page.locator('#format')).toBeInViewport()
})

test('pressing it downloads the file straight away, and the status says what happened', async ({ page }) => {
  await loadVideo(page, 'fade.mp4')
  await setSlider(page, 'end', 200)
  await setSlider(page, 'width', 240)
  const download = page.waitForEvent('download')
  await page.click('#export')
  await expect(page.locator('#export')).toHaveText(/%$/)
  const file = await download
  expect(file.suggestedFilename()).toBe('fade-240x240.gif')
  const bytes = readFileSync(await file.path())
  expect(bytes.subarray(0, 6).toString('latin1')).toBe('GIF89a')
  await expect(page.locator('#status')).toContainText('✓ Downloaded fade-240x240.gif')
  await expect(page.locator('#export')).toHaveText('Download GIF')
  await expect(page.locator('#history .item')).toHaveCount(1)
})

test('every press is its own download', async ({ page }) => {
  await loadVideo(page, 'fade.mp4')
  await setSlider(page, 'end', 100)
  await setSlider(page, 'width', 240)
  for (const name of ['fade-240x240.gif', 'fade-240x240.mp4']) {
    await page.selectOption('#format', name.endsWith('gif') ? 'gif' : 'mp4')
    const download = page.waitForEvent('download')
    await page.click('#export')
    expect((await download).suggestedFilename()).toBe(name)
    await expect(page.locator('#export')).toBeEnabled()
  }
})

test('a sticker made from an earlier export gets a clean name', async ({ page }) => {
  const loads = await page.evaluate(() => window.gifMaker.loads)
  await page.setInputFiles('#file', {
    name: 'гифa (1)-leicaHC-600x600-sticker-512x512 (2).gif',
    mimeType: 'image/gif',
    buffer: readFileSync(fixture('fade.gif')),
  })
  await page.waitForFunction((n) => window.gifMaker.loads > n, loads)
  await page.selectOption('#format', 'sticker')
  await page.click('#filters [data-f=leicaHC]')
  const file = await exportFile(page)
  expect(file.name).toBe('гифa (1)-leica-high-contrast-telegram-sticker.webm')
})

test('the downloads list shows stills, it doesn’t keep playing every export', async ({ page }) => {
  await loadVideo(page, 'fade.mp4')
  await setSlider(page, 'end', 100)
  await setSlider(page, 'width', 240)
  await exportFile(page)
  await page.selectOption('#format', 'mp4')
  await exportFile(page)
  await expect(page.locator('#history video')).toHaveCount(0)
  const src = await page.locator('#history .thumb').first().getAttribute('src')
  expect(src).toMatch(/^data:image\/jpeg/)
})

test.describe('reading frames', () => {
  test('video is decoded in order rather than seeked, and the frames are the right ones', async ({ page }) => {
    await loadVideo(page, 'fade.mp4')
    await setSlider(page, 'start', 200)
    await setSlider(page, 'end', 800)
    await setSlider(page, 'width', 240)
    const gif = await gifInfo(page, (await exportFile(page)).url)
    expect(await page.evaluate(() => window.gifMaker.fastDecode)).toBe(true)
    expect(Math.abs(gif.centre[0] - 51)).toBeLessThan(9)
    expect(Math.abs(gif.centre[22] - 125)).toBeLessThan(11)
  })

  test('a file cut without re-encoding (with an edit list) starts at the right frame', async ({ page }) => {
    // trimmed.mp4 is fade.mp4 from 2 s on, cut by stream copy: its first visible frame is grey ≈ 102
    await loadVideo(page, 'trimmed.mp4')
    await setSlider(page, 'width', 240)
    const gif = await gifInfo(page, (await exportFile(page)).url)
    expect(gif.frames).toBe(45)
    expect(Math.abs(gif.centre[0] - 102)).toBeLessThan(12)
    expect(Math.abs(gif.centre[44] - 51 * 4.93)).toBeLessThan(14)
  })

  test('a WebM source works too', async ({ page }) => {
    await loadVideo(page, 'bars.webm')
    await setSlider(page, 'width', 240)
    const gif = await gifInfo(page, (await exportFile(page)).url)
    expect(gif.frames).toBe(30)
  })
})

test.describe('the sidebar', () => {
  const dragResizer = async (page: import('@playwright/test').Page, dx: number) => {
    const box = (await page.locator('#resizer').boundingBox())!
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
    await page.mouse.down()
    await page.mouse.move(box.x + box.width / 2 + dx, box.y + box.height / 2, { steps: 5 })
    await page.mouse.up()
  }

  test('dragging its edge makes it, and the preview, bigger; the width is remembered', async ({ page }) => {
    await loadVideo(page, 'fade.mp4')
    const before = (await page.locator('#out').boundingBox())!
    await dragResizer(page, -250)
    const after = (await page.locator('#out').boundingBox())!
    expect(after.width).toBeGreaterThan(before.width + 200)
    const side = (await page.locator('main > aside').boundingBox())!.width
    await page.reload()
    await page.waitForFunction(() => !!window.gifMaker)
    expect((await page.locator('main > aside').boundingBox())!.width).toBeCloseTo(side, -1)
  })

  test('it stays between sensible limits, and double-click resets it', async ({ page }) => {
    await loadVideo(page, 'fade.mp4')
    await dragResizer(page, 900)
    expect((await page.locator('main > aside').boundingBox())!.width).toBe(280)
    await dragResizer(page, -1400)
    const wide = (await page.locator('main > aside').boundingBox())!.width
    expect(wide).toBeLessThanOrEqual(1000)
    expect((await page.locator('#view').boundingBox())!.width).toBeGreaterThan(100)
    await page.locator('#resizer').dblclick()
    expect((await page.locator('main > aside').boundingBox())!.width).toBe(380)
  })
})
