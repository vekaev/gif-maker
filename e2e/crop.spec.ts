import { test, expect } from '@playwright/test'
import { open, loadVideo, state, seek, setSlider, previewColor } from './helpers'

// split.mp4: 1280×720, red 0–280 px, green 280–1000 px, blue 1000–1280 px.
test.beforeEach(async ({ page }) => {
  await open(page)
  await loadVideo(page, 'split.mp4')
  await seek(page, 1)
})

const isRed = ([r, g, b]: number[]) => r > 150 && g < 80 && b < 80
const isGreen = ([r, g, b]: number[]) => g > 120 && r < 80 && b < 80
const isBlue = ([r, g, b]: number[]) => b > 150 && r < 80 && g < 80

test('aspect buttons set the crop shape', async ({ page }) => {
  const shapes: [string, number][] = [['1:1', 1], ['4:5', 0.8], ['9:16', 0.5625], ['16:9', 1.7778], ['Original', 1280 / 720]]
  for (const [label, ratio] of shapes) {
    await page.getByRole('button', { name: label, exact: true }).click()
    await expect(page.locator('#aspects button.on')).toHaveText(label)
    const { crop } = await state(page)
    expect(crop.w / crop.h).toBeCloseTo(ratio, 2)
    expect(crop.x).toBeGreaterThanOrEqual(0)
    expect(crop.x + crop.w).toBeLessThanOrEqual(1280.5)
    expect(crop.y + crop.h).toBeLessThanOrEqual(720.5)
  }
  // "Original" at full size is the whole frame
  const { crop } = await state(page)
  expect(crop).toMatchObject({ x: 0, y: 0, w: 1280, h: 720 })
})

test('snap buttons move the square to the left edge, the center and the right edge', async ({ page }) => {
  await page.getByRole('button', { name: '← Left edge' }).click()
  expect((await state(page)).crop.x).toBe(0)
  expect(isRed(await previewColor(page, 2, 100))).toBe(true)
  expect(isGreen(await previewColor(page, -2, 100))).toBe(true)

  await page.getByRole('button', { name: 'Center', exact: true }).click()
  expect((await state(page)).crop.x).toBeCloseTo(280)
  expect(isGreen(await previewColor(page, 2, 100))).toBe(true)
  expect(isGreen(await previewColor(page, -2, 100))).toBe(true)

  await page.getByRole('button', { name: 'Right edge →' }).click()
  expect((await state(page)).crop.x).toBeCloseTo(560)
  expect(isGreen(await previewColor(page, 2, 100))).toBe(true)
  expect(isBlue(await previewColor(page, -2, 100))).toBe(true)
})

test('dragging the frame moves the crop, and it stays inside the video', async ({ page }) => {
  const box = (await page.locator('#view').boundingBox())!
  const perPx = 1280 / box.width
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  await page.mouse.down()
  await page.mouse.move(box.x + box.width / 2 - 60, box.y + box.height / 2, { steps: 5 })
  await page.mouse.up()
  expect((await state(page)).crop.x).toBeCloseTo(280 - 60 * perPx, 0)

  // drag far past the edge: clamped at 0
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  await page.mouse.down()
  await page.mouse.move(box.x + 5, box.y + box.height / 2, { steps: 5 })
  await page.mouse.up()
  expect((await state(page)).crop.x).toBe(0)
})

test('the size slider and the mouse wheel zoom the crop', async ({ page }) => {
  await setSlider(page, 'size', 50)
  await expect(page.locator('#sizeV')).toHaveText('50%')
  let { crop } = await state(page)
  expect(crop.w).toBeCloseTo(360)
  expect(crop.h).toBeCloseTo(360)

  await page.locator('#view').hover()
  await page.mouse.wheel(0, 100)
  await expect(page.locator('#sizeV')).toHaveText('47%')
  await page.mouse.wheel(0, -100)
  await page.mouse.wheel(0, -100)
  await expect(page.locator('#sizeV')).toHaveText('53%')
  ;({ crop } = await state(page))
  expect(crop.w).toBeCloseTo(720 * 0.53)
})

test('the output never upscales the crop', async ({ page }) => {
  await setSlider(page, 'size', 50) // crop is 360×360 source pixels
  await setSlider(page, 'width', 1080)
  expect((await state(page)).out).toEqual({ w: 360, h: 360 })
  await expect(page.locator('#estimate')).toContainText('360×360')
  await expect(page.locator('#estimate')).toContainText('no upscaling')

  await setSlider(page, 'width', 240)
  expect((await state(page)).out).toEqual({ w: 240, h: 240 })
  await expect(page.locator('#estimate')).not.toContainText('no upscaling')
})

test('the area outside the crop is dimmed in the main view', async ({ page }) => {
  await page.getByRole('button', { name: 'Center', exact: true }).click()
  await seek(page, 1.5)
  const [inside, outside] = await page.evaluate(() => {
    const v = document.getElementById('view') as HTMLCanvasElement
    const c = v.getContext('2d')!
    const at = (x: number) => Array.from(c.getImageData(Math.round(x * v.width), Math.round(v.height / 2), 1, 1).data)
    return [at(0.5), at(0.05)] // centre: green, inside the crop; far left: red, outside
  })
  expect(inside[1]).toBeGreaterThan(150)
  expect(outside[0]).toBeGreaterThan(40)
  expect(outside[0]).toBeLessThan(110) // the red is ~224 in the video; the overlay takes it down to ~85
})
