import { test, expect } from '@playwright/test'
import { open, loadVideo, seek, setSlider, previewColor, previewStats, previewGrid } from './helpers'

// fade.mp4 is a flat frame whose grey level is 51 × seconds; bars.mp4 is a colourful test pattern.
test.beforeEach(async ({ page }) => { await open(page) })

const grey = ([r, g, b]: number[]) => Math.round((r + g + b) / 3)

test.describe('light and colour', () => {
  test.beforeEach(async ({ page }) => {
    await loadVideo(page, 'fade.mp4')
    await seek(page, 1) // grey ≈ 51
  })

  test('exposure brightens by stops', async ({ page }) => {
    expect(grey(await previewColor(page, 50, 50))).toBeGreaterThan(40)
    expect(grey(await previewColor(page, 50, 50))).toBeLessThan(62)
    await setSlider(page, 'exposure', 100) // +1 stop: twice as bright
    const g = grey(await previewColor(page, 50, 50))
    expect(g).toBeGreaterThan(90)
    expect(g).toBeLessThan(115)
  })

  test('shadows lift the dark tones', async ({ page }) => {
    await setSlider(page, 'shadows', 100)
    expect(grey(await previewColor(page, 50, 50))).toBeGreaterThan(100)
  })

  test('contrast pushes a dark grey towards black', async ({ page }) => {
    await setSlider(page, 'contrast', 100)
    expect(grey(await previewColor(page, 50, 50))).toBeLessThan(15)
  })

  test('warmth tints towards orange or blue', async ({ page }) => {
    await seek(page, 2.5) // mid grey
    await setSlider(page, 'warmth', 50)
    let [r, , b] = await previewColor(page, 50, 50)
    expect(r - b).toBeGreaterThan(40)
    await setSlider(page, 'warmth', -50)
    ;[r, , b] = await previewColor(page, 50, 50)
    expect(b - r).toBeGreaterThan(40)
  })

  test('Auto brightens a dark clip', async ({ page }) => {
    await page.click('#auto')
    expect(Number(await page.locator('#exposure').inputValue())).toBeGreaterThan(50)
    expect(grey(await previewColor(page, 50, 50))).toBeGreaterThan(110)
  })

  test('Reset puts every slider back', async ({ page }) => {
    await setSlider(page, 'exposure', 80)
    await setSlider(page, 'contrast', 40)
    await setSlider(page, 'saturation', 20)
    await setSlider(page, 'warmth', 30)
    await setSlider(page, 'shadows', 30)
    await setSlider(page, 'grain', 10)
    await page.click('#filters [data-f=noir]')
    await page.click('#reset')
    for (const [id, v] of [['exposure', '0'], ['shadows', '0'], ['contrast', '0'], ['saturation', '100'], ['warmth', '0'], ['grain', '0']]) {
      await expect(page.locator(`#${id}`)).toHaveValue(v)
    }
    await expect(page.locator('#filters button.on')).toHaveText('Color')
    expect(grey(await previewColor(page, 50, 50))).toBeLessThan(62)
  })

  test('grain adds noise in colour and in black and white', async ({ page }) => {
    expect((await previewStats(page)).sd).toBeLessThan(2)
    await setSlider(page, 'grain', 25)
    expect((await previewStats(page)).sd).toBeGreaterThan(5)
    await page.click('#filters [data-f=mono]')
    expect((await previewStats(page)).sd).toBeGreaterThan(5)
  })
})

test.describe('filters', () => {
  test.beforeEach(async ({ page }) => {
    await loadVideo(page, 'bars.mp4')
    await seek(page, 1)
  })

  test('every black-and-white look turns the picture grey, Color brings colour back', async ({ page }) => {
    expect((await previewStats(page)).maxChroma).toBeGreaterThan(100)
    const grids: Record<string, number[]> = {}
    for (const f of ['mono', 'silvertone', 'noir', 'leica', 'leicaHC', 'acros']) {
      await page.click(`#filters [data-f=${f}]`)
      await expect(page.locator('#filters button.on')).toHaveAttribute('data-f', f)
      const s = await previewStats(page)
      // Silvertone has a faint cool tint in the midtones; the rest are neutral
      expect(s.maxChroma, f).toBeLessThanOrEqual(f === 'silvertone' ? 14 : 1)
      grids[f] = await previewGrid(page)
    }
    // every pair of looks gives a visibly different picture (mean difference per pixel)
    const names = Object.keys(grids)
    for (let i = 0; i < names.length; i++) for (let j = i + 1; j < names.length; j++) {
      const a = grids[names[i]], b = grids[names[j]]
      const diff = a.reduce((s, v, k) => s + Math.abs(v - b[k]), 0) / a.length
      expect(diff, `${names[i]} vs ${names[j]}`).toBeGreaterThan(6)
    }

    await page.click('#filters [data-f=color]')
    expect((await previewStats(page)).maxChroma).toBeGreaterThan(100)
  })

  test('saturation at zero removes colour', async ({ page }) => {
    await setSlider(page, 'saturation', 0)
    expect((await previewStats(page)).maxChroma).toBeLessThanOrEqual(2)
  })

  test('there are six black-and-white looks plus Color', async ({ page }) => {
    await expect(page.locator('#filters button')).toHaveText([
      'Color', 'iPhone Mono', 'iPhone Silvertone', 'iPhone Noir', 'Leica Monochrom', 'Leica High Contrast', 'Fuji Acros',
    ])
  })
})
