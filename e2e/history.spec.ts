import { test, expect } from '@playwright/test'
import { open, loadVideo, setSlider, exportFile } from './helpers'

test.beforeEach(async ({ page }) => {
  await open(page)
  await loadVideo(page, 'fade.mp4')
  await setSlider(page, 'end', 200) // 1 s keeps every export quick
  await setSlider(page, 'width', 240)
})

test('every export is listed, newest first, with a working Save link', async ({ page }) => {
  await exportFile(page)
  await page.selectOption('#format', 'webm')
  await exportFile(page)

  const items = page.locator('#history .item')
  await expect(page.locator('#historyPanel')).toBeVisible()
  await expect(items).toHaveCount(2)
  await expect(items.nth(0).locator('.name')).toHaveText('fade-240x240.webm')
  await expect(items.nth(0)).toContainText('WebM ·')
  await expect(items.nth(1).locator('.name')).toHaveText('fade-240x240.gif')
  await expect(items.nth(1)).toContainText(/GIF · \d+ KB/)

  const download = page.waitForEvent('download')
  await items.nth(1).getByRole('link', { name: '⬇ Save' }).click()
  expect((await download).suggestedFilename()).toBe('fade-240x240.gif')
})

test('exports survive a reload and can be removed', async ({ page }) => {
  await exportFile(page)
  await page.click('#filters [data-f=acros]')
  await exportFile(page)

  await page.reload()
  await page.waitForFunction(() => !!window.gifMaker)
  const items = page.locator('#history .item')
  await expect(items).toHaveCount(2)
  await expect(items.nth(0).locator('.name')).toHaveText('fade-acros-240x240.gif')

  await items.nth(0).getByRole('button', { name: '✕' }).click()
  await expect(items).toHaveCount(1)
  await page.reload()
  await expect(page.locator('#history .item')).toHaveCount(1)
  await page.locator('#history .item').getByRole('button', { name: '✕' }).click()
  await expect(page.locator('#historyPanel')).toBeHidden()
})
