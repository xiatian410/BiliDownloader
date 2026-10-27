// Run after serving flutter_app/build/web. This never disables web security.
const { chromium } = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

(async () => {
  const output = path.resolve(__dirname, '../artifacts');
  fs.mkdirSync(output, { recursive: true });
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH || undefined,
    headless: true,
    args: process.getuid?.() === 0 ? ['--no-sandbox'] : [],
  });
  try {
    const page = await browser.newPage({ viewport: { width: 800, height: 680 } });
    const scriptErrors = [], consoleErrors = [];
    page.on('pageerror', error => scriptErrors.push(error.message));
    page.on('console', message => { if (message.type() === 'error') consoleErrors.push(message.text()); });
    await page.goto(process.env.WEB_URL || 'http://127.0.0.1:18743', { waitUntil: 'networkidle' });
    await page.waitForSelector('flt-glass-pane', { state: 'attached' });
    const semantics = page.locator('flt-semantics-placeholder');
    if (await semantics.count()) await semantics.evaluate(element => element.click());
    await page.getByText('BiliDownloader', { exact: true }).waitFor();
    assert.equal(await page.title(), 'BiliDownloader');
    await page.screenshot({ path: path.join(output, 'web-desktop.png') });
    await page.setViewportSize({ width: 360, height: 740 });
    await page.getByText('输入', { exact: true }).waitFor();
    await page.screenshot({ path: path.join(output, 'web-mobile.png') });
    const probe = await page.evaluate(async () => {
      const results = [];
      for (const url of [
        'https://api.bilibili.com/x/web-interface/view?bvid=BV17x411w7KC',
        'https://api.bilibili.com/x/web-interface/nav',
        'https://passport.bilibili.com/x/passport-login/web/qrcode/generate',
      ]) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 15000);
        try {
          const response = await fetch(url, { signal: controller.signal });
          results.push({ url, status: response.status, body: (await response.text()).slice(0, 180) });
        } catch (error) { results.push({ url, error: String(error) }); }
        finally { clearTimeout(timer); }
      }
      return results;
    });
    const result = { checkedAt: new Date().toISOString(), probe, scriptErrors, consoleErrors };
    fs.writeFileSync(path.join(output, 'web-probe.json'), JSON.stringify(result, null, 2));
    assert.deepEqual(scriptErrors, [], 'Flutter page raised a JavaScript error');
    console.log(JSON.stringify(result, null, 2));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
