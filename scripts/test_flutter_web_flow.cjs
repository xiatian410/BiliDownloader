// MANAGE_FIXTURE=1 starts/stops the fixture and additionally tests service restart.
const { chromium } = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { execFileSync, spawn } = require('node:child_process');
const { createInterface } = require('node:readline');

(async () => {
  const output = path.resolve(__dirname, '../artifacts/rewrite');
  fs.mkdirSync(output, { recursive: true });
  let fixture, fixtureLines, browser;
  function waitForFixture(message) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => finish(new Error(`Fixture timed out: ${message}`)), 30000);
      const line = value => { if (value.startsWith(message)) finish(); };
      const closed = code => finish(new Error(`Fixture exited: ${code}`));
      function finish(error) {
        clearTimeout(timer);
        fixtureLines.off('line', line);
        fixture.off('exit', closed);
        fixture.off('error', finish);
        error ? reject(error) : resolve();
      }
      fixtureLines.on('line', line);
      fixture.once('exit', closed);
      fixture.once('error', finish);
    });
  }
  try {
    if (process.env.MANAGE_FIXTURE === '1') {
      fixture = spawn('dart', ['run', 'test/fixtures/browser_service.dart'], {
        cwd: path.resolve(__dirname, '../flutter_app'), stdio: ['pipe', 'pipe', 'inherit'],
      });
      fixtureLines = createInterface({ input: fixture.stdout });
      await waitForFixture('Fixture ready:');
    }
    browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
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
    if (fixture) {
      const restarted = waitForFixture('Fixture restarted:');
      fixture.stdin.write('restart\n');
      await restarted;
      await page.reload({ waitUntil: 'networkidle' });
      await semantics();
      await page.getByText('下载任务', { exact: true }).click();
      await page.getByRole('button', { name: '下载文件 1', exact: true }).waitFor();
      const afterRestartPromise = page.waitForEvent('download');
      await page.getByRole('button', { name: '下载文件 1', exact: true }).click();
      const afterRestart = await afterRestartPromise;
      const recoveredFile = path.join(output, 'recovered.mp4');
      await afterRestart.saveAs(recoveredFile);
      assert.deepEqual(fs.readFileSync(recoveredFile), fs.readFileSync(file));
    }
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
      downloadedFile: path.basename(file), streams: probe.streams.map(s => s.codec_type), reloadPreservedTask: true,
      serviceRestartPreservedTask: !!fixture }, null, 2));
    console.log(`Browser fixture passed: batch partial failure, download, FFmpeg merge, file export, refresh recovery, mobile rendering${fixture ? ', service restart' : ''}.`);
  } finally {
    await browser?.close();
    if (fixture?.pid && fixture.exitCode === null && fixture.signalCode === null) {
      const exit = new Promise(resolve => fixture.once('exit', resolve));
      fixture.kill('SIGTERM');
      const force = setTimeout(() => fixture.kill('SIGKILL'), 10000);
      await exit;
      clearTimeout(force);
    }
    fixtureLines?.close();
  }
})().catch(e => { console.error(e); process.exitCode = 1; });
