import { test, expect, type Page } from '@playwright/test'
import { open, loadVideo, state, seek, settle } from './helpers'

// bars.mp4: a colourful 960×540 test pattern
test.beforeEach(async ({ page }) => {
  await open(page)
  await loadVideo(page, 'bars.mp4')
  await seek(page, 1)
})

// colourfulness of a column of the big view, at a fraction of its width
const columnChroma = (page: Page, fx: number) => page.evaluate((fx) => {
  const v = document.getElementById('view') as HTMLCanvasElement
  const d = v.getContext('2d')!.getImageData(Math.round(fx * v.width), Math.round(v.height * 0.2), 1, Math.round(v.height * 0.6)).data
  let max = 0
  for (let i = 0; i < d.length; i += 4) max = Math.max(max, Math.max(d[i], d[i + 1], d[i + 2]) - Math.min(d[i], d[i + 1], d[i + 2]))
  return max
}, fx)

test('three views: Crop, Result and Before / After', async ({ page }) => {
  await expect(page.locator('#modes button')).toHaveText(['Crop', 'Result', 'Before / After'])
  await expect(page.locator('#modes button.on')).toHaveText('Crop')
  await expect(page.locator('#previewPanel')).toBeVisible()

  await page.getByRole('button', { name: 'Result' }).click()
  await expect(page.locator('#modes button.on')).toHaveText('Result')
  await expect(page.locator('#viewHint')).toContainText('The finished picture')
  await expect(page.locator('#previewPanel')).toBeHidden() // the big view is the preview now
  expect((await state(page)).mode).toBe('result')

  await page.getByRole('button', { name: 'Before / After' }).click()
  await expect(page.locator('#viewHint')).toContainText('Drag the line')
  await page.getByRole('button', { name: 'Crop' }).click()
  await expect(page.locator('#previewPanel')).toBeVisible()
})

test('Result shows the finished picture big, in the crop’s shape', async ({ page }) => {
  await page.click('#filters [data-f=noir]')
  await page.getByRole('button', { name: 'Result' }).click()
  await settle(page)
  let s = await state(page)
  expect(s.view).toEqual({ w: 800, h: 800 })
  expect(await columnChroma(page, 0.5)).toBeLessThanOrEqual(1)
  const box = (await page.locator('#view').boundingBox())!
  expect(box.width).toBeGreaterThan(500) // fills the main area, not a corner

  await page.getByRole('button', { name: '16:9' }).click()
  await settle(page)
  s = await state(page)
  expect(s.view).toEqual({ w: 800, h: 450 })
})

test('Before / After: original on the left, result on the right, with a line you drag', async ({ page }) => {
  await page.click('#filters [data-f=mono]')
  await page.getByRole('button', { name: 'Before / After' }).click()
  await settle(page)
  expect((await state(page)).split).toBe(0.5)
  expect(await columnChroma(page, 0.3)).toBeGreaterThan(80) // before: colour
  expect(await columnChroma(page, 0.7)).toBeLessThanOrEqual(1) // after: black and white

  const box = (await page.locator('#view').boundingBox())!
  await page.mouse.move(box.x + box.width * 0.5, box.y + box.height / 2)
  await page.mouse.down()
  await page.mouse.move(box.x + box.width * 0.2, box.y + box.height / 2, { steps: 4 })
  await page.mouse.up()
  expect((await state(page)).split).toBeCloseTo(0.2, 1)
  await settle(page)
  expect(await columnChroma(page, 0.1)).toBeGreaterThan(80)
  expect(await columnChroma(page, 0.3)).toBeLessThanOrEqual(1) // now part of the "after" side
})

test('dragging in Result moves the crop the way the picture moves', async ({ page }) => {
  await page.getByRole('button', { name: 'Result' }).click()
  await settle(page) // the view takes the crop's shape on the next frame
  const x0 = (await state(page)).crop.x // centred: (960 − 540) / 2 = 210
  const box = (await page.locator('#view').boundingBox())!
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  await page.mouse.down()
  await page.mouse.move(box.x + box.width / 2 + 100, box.y + box.height / 2, { steps: 4 })
  await page.mouse.up()
  const { crop } = await state(page)
  expect(crop.x).toBeCloseTo(x0 - 100 * 540 / box.width, 0)
})
