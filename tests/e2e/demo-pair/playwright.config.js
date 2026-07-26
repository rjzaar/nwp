// ops#133 Phase 2 — nwd<->ssd demo-pair e2e. DEV DDEV SITES ONLY.
module.exports = {
  testDir: __dirname,
  timeout: 180_000,
  expect: { timeout: 20_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list']],
  use: {
    ignoreHTTPSErrors: true,
    headless: true,
    viewport: { width: 1280, height: 900 },
    actionTimeout: 25_000,
  },
};
