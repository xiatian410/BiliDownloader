// Run with: dart run test/fixtures/browser_service.dart (from flutter_app).
const { chromium } = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');

(async () => {
  const output = path.resolve(__dirname, '../artifacts/rewrite');
  fs.mkdirSync(output, { recursive: true });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
    headless: true, args: process.getuid?.() === 0 ? ['--no-sandbox'] : [] });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1080 }, acceptDownloads: true });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  async function semantics() {
    await page.waitForSelector('flt-glass-pane', { state: 'attached' });
    const placeholder = page.locator('flt-semantics-placeholder');
    if (await placeholder.count()) await placeholder.evaluate(e => e.click());
  }
  try {
    await page.goto(process.env.WEB_URL || 'http://127.0.0.1:18744', { waitUntil: 'networkidle' });
    await semantics();
    await page.getByRole('textbox').first().fill('av1;av412');
    const rejected = page.waitForResponse(r => r.url().endsWith('/api/resolve') && r.status() === 422);
    await page.getByRole('button', { name: '解析链接', exact: true }).click();
    await page.getByRole('group', { name: /跨端下载验证 · AV1/ }).waitFor();
    assert.equal((await (await rejected).json()).detail, '412');
    await page.screenshot({ path: path.join(output, 'desktop-new.png') });
    await page.getByRole('button', { name: '获取可用画质', exact: true }).click();
    await page.getByRole('button', { name: '加入下载队列 (1)', exact: true }).click();
    await page.getByRole('button', { name: '下载文件 1', exact: true }).waitFor({ timeout: 30000 });
    await page.screenshot({ path: path.join(output, 'desktop-task.png') });
    const downloadPromise = page.waitForEvent('download');
    await page.getByRole('button', { name: '下载文件 1', exact: true }).click();
    const download = await downloadPromise;
    const file = path.join(output, download.suggestedFilename());
    await download.saveAs(file);
    const probe = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_streams', '-of', 'json', file], { encoding: 'utf8' }));
    assert.deepEqual(probe.streams.map(s => s.codec_type).sort(), ['audio', 'video']);
    execFileSync('ffmpeg', ['-nostdin', '-v', 'error', '-i', file, '-map', '0:v:0', '-map', '0:a:0', '-f', 'null', '-']);
    await page.reload({ waitUntil: 'networkidle' });
    await semantics();
    await page.getByText('下载任务', { exact: true }).click();
    await page.getByRole('button', { name: '下载文件 1', exact: true }).waitFor();
    await page.setViewportSize({ width: 360, height: 800 });
    await page.screenshot({ path: path.join(output, 'mobile-task.png') });
    await page.getByRole('tab', { name: '新建下载', exact: true }).click();
    await page.mouse.move(0, 0);
    await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
    await page.screenshot({ path: path.join(output, 'mobile-new.png') });
    await page.emulateMedia({ colorScheme: 'dark' });
    // Wait bounded animation frames for Material's theme transition to settle.
    await page.evaluate(async () => { for (let i = 0; i < 20; i++) await new Promise(requestAnimationFrame); });
    await page.screenshot({ path: path.join(output, 'mobile-dark.png') });
    assert.deepEqual(errors, []);
    fs.writeFileSync(path.join(output, 'browser-result.json'), JSON.stringify({ fixture: true, errors,
      downloadedFile: path.basename(file), streams: probe.streams.map(s => s.codec_type), reloadPreservedTask: true }, null, 2));
    console.log('Browser fixture passed: batch partial failure, download, FFmpeg merge, file export, refresh recovery, mobile rendering.');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
