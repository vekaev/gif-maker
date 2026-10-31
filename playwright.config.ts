import { defineConfig, devices } from '@playwright/test'

// Runs against Google Chrome (channel: 'chrome'), not Playwright's bundled Chromium: the open-source build
// can't decode H.264 or encode it with WebCodecs, and the MP4 export depends on both.
// The page is served by http-server, which answers Range requests, so seeking works like on GitHub Pages.
export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 2 : undefined,
  timeout: 90_000,
  reporter: process.env.CI ? [['github'], ['html', { open: 'never' }]] : 'list',
  expect: { timeout: 10_000 },
  use: {
    baseURL: 'http://localhost:4173',
    trace: 'on-first-retry',
  },
  projects: [
    { name: 'chrome', use: { ...devices['Desktop Chrome'], channel: 'chrome', viewport: { width: 1440, height: 900 } } },
  ],
  webServer: {
    command: 'npm start',
    url: 'http://localhost:4173',
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
  },
})
