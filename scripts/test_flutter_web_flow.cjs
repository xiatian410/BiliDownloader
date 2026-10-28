// MANAGE_FIXTURE=1 starts/stops the fixture and additionally tests service restart.
const { chromium } = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { execFileSync, spawn } = require('node:child_process');
const { createInterface } = require('node:readline');
const { EventEmitter } = require('node:events');

(async () => {
  const output = path.resolve(__dirname, '../artifacts/rewrite');
  fs.mkdirSync(output, { recursive: true });
  let fixture, fixtureLines, browser, page;
  const mediaRequests = [];
  const network = [], errors = [], jobHistory = [];
  // Attach rejection handlers immediately to waits that span a separate UI action.
  function observe(future) { future.catch(() => {}); return future; }
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
      fixtureLines.on('line', line => {
        if (line.startsWith('Fixture media: ')) mediaRequests.push(JSON.parse(line.slice(15)));
      });
      await waitForFixture('Fixture ready:');
    }
    browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
      headless: true, args: process.getuid?.() === 0 ? ['--no-sandbox'] : [] });
    const context = await browser.newContext({ viewport: { width: 1440, height: 1080 }, acceptDownloads: true });
    context.setDefaultTimeout(15000);
    context.setDefaultNavigationTimeout(30000);
    const jobs = new Map(), jobEvents = new EventEmitter();
    let activeSocket;
    await context.routeWebSocket('**/api/events', socket => {
      activeSocket = socket;
      const server = socket.connectToServer();
      server.onMessage(message => {
        const job = JSON.parse(message.toString());
        jobHistory.push({ at: Date.now(), id: job.id, aid: job.episode?.aid, state: job.state, stage: job.stage, received: job.received, total: job.total });
        jobs.set(job.id, job);
        jobEvents.emit('job', job);
        socket.send(message);
      });
    });
    function waitForJob(id, matches) {
      if (jobs.has(id) && matches(jobs.get(id))) return Promise.resolve(jobs.get(id));
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => finish(new Error(`Job timed out: ${id} ${matches.toString()} ${JSON.stringify(jobs.get(id))}`)), 30000);
        function receive(job) { if (job.id === id && matches(job)) finish(null, job); }
        function finish(error, job) {
          clearTimeout(timer);
          jobEvents.off('job', receive);
          error ? reject(error) : resolve(job);
        }
        jobEvents.on('job', receive);
      });
    }
    page = await context.newPage();
    page.on('pageerror', e => errors.push(e.message));
    page.on('response', r => {
      if (new URL(r.url()).pathname.startsWith('/api/')) network.push({ path: new URL(r.url()).pathname, status: r.status() });
    });
    async function semantics() {
      await page.waitForSelector('flt-glass-pane', { state: 'attached' });
      const placeholder = page.locator('flt-semantics-placeholder');
      if (await placeholder.count()) await placeholder.evaluate(e => e.click());
    }
    async function typeInto(input, text) {
      // Focusing splits Flutter's merged semantics node on the next frame.
      // Wait two rendering frames, then type into the active editing connection.
      await input.click();
      await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
      await page.keyboard.press('ControlOrMeta+A');
      await page.keyboard.insertText(text);
      await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
      assert.equal(await page.locator('textarea:focus, input:focus').inputValue(), text);
    }
    async function createJob(aid, mode = '视频', dropResponse = false) {
      await page.getByRole('button', { name: '新建下载', exact: true }).click();
      await typeInto(page.getByRole('textbox', { name: /已识别:|粘贴一个或多个/ }), `av${aid}`);
      await page.getByRole('button', { name: '解析链接', exact: true }).click();
      await page.getByRole('group', { name: new RegExp(`跨端下载验证 · AV${aid}`) }).waitFor();
      await page.getByRole('checkbox', { name: mode, exact: true }).click();
      if (mode !== '仅弹幕') {
        await page.getByRole('button', { name: '获取可用画质', exact: true }).click();
      }
      let submitted;
      if (dropResponse) {
        let accepted, failed;
        submitted = observe(new Promise((resolve, reject) => { accepted = resolve; failed = reject; }));
        await page.route('**/api/jobs', async route => {
          try {
            const response = await route.fetch({ timeout: 15000 });
            accepted(await response.json());
            await route.abort('failed');
          } catch (error) {
            failed(error);
            await route.abort('failed').catch(() => {});
          }
        }, { times: 1 });
      } else {
        submitted = observe(page.waitForResponse(r => r.url().endsWith('/api/jobs') && r.request().method() === 'POST').then(r => r.json()));
      }
      await page.getByRole('button', { name: '加入下载队列 (1)', exact: true }).click();
      const job = await submitted;
      assert.ok(job.id, JSON.stringify(job));
      await page.getByRole('checkbox', { name: '全部', exact: true }).waitFor();
      await typeInto(page.getByRole('textbox'), `AV${aid}`);
      console.log(`Browser: AV${aid} submitted and filtered at ${Date.now()}.`);
      return job.id;
    }
    async function saveOutput(name) {
      const button = page.getByRole('button', { name: '下载文件 1', exact: true });
      await button.waitFor({ timeout: 30000 });
      const downloaded = observe(page.waitForEvent('download'));
      await button.click();
      const item = await downloaded;
      const destination = path.join(output, name || item.suggestedFilename());
      await item.saveAs(destination);
      return destination;
    }
    async function releaseMedia() {
      const released = waitForFixture('Fixture released:');
      fixture.stdin.write('release\n');
      await released;
    }
    await page.goto(process.env.WEB_URL || 'http://127.0.0.1:18744', { waitUntil: 'networkidle' });
    await semantics();
    await typeInto(page.getByRole('textbox').first(), 'av1;av412');
    const rejected = observe(page.waitForResponse(r => r.url().endsWith('/api/resolve') && r.status() === 422));
    await page.getByRole('button', { name: '解析链接', exact: true }).click();
    assert.equal((await (await rejected).json()).detail, '412');
    await page.getByRole('group', { name: /跨端下载验证 · AV1/ }).waitFor();
    console.log('Browser: partial parse failure verified.');
    await page.screenshot({ path: path.join(output, 'desktop-new.png') });
    await page.getByRole('button', { name: '获取可用画质', exact: true }).click();
    await page.getByRole('button', { name: '加入下载队列 (1)', exact: true }).click();
    await page.getByRole('button', { name: '下载文件 1', exact: true }).waitFor({ timeout: 30000 });
    await page.screenshot({ path: path.join(output, 'desktop-task.png') });
    const downloadPromise = observe(page.waitForEvent('download'));
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
      const afterRestartPromise = observe(page.waitForEvent('download'));
      await page.getByRole('button', { name: '下载文件 1', exact: true }).click();
      const afterRestart = await afterRestartPromise;
      const recoveredFile = path.join(output, 'recovered.mp4');
      await afterRestart.saveAs(recoveredFile);
      assert.deepEqual(fs.readFileSync(recoveredFile), fs.readFileSync(file));
    }

    await page.getByRole('button', { name: '设置', exact: true }).first().click();
    const login = observe(page.waitForResponse(r => r.url().endsWith('/api/login/poll')));
    await page.getByRole('button', { name: '扫码登录', exact: true }).click();
    assert.deepEqual(await (await login).json(), { code: 0 });
    await page.getByRole('button', { name: '退出登录', exact: true }).waitFor();
    assert.equal(await page.evaluate(() => document.cookie.includes('bili_session')), false);
    const cookies = await context.cookies();
    assert.ok(cookies.some(c => c.name === 'bili_session' && c.httpOnly && c.sameSite === 'Strict'));
    assert.equal(cookies.some(c => ['SESSDATA', 'bili_jct'].includes(c.name)), false);
    console.log('Browser: QR login verified.');

    const audioId = await createJob(2, '仅下载音频');
    await waitForJob(audioId, j => j.state === 'completed');
    const audioFile = await saveOutput('audio-only.m4a');
    const audioProbe = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_streams', '-of', 'json', audioFile], { encoding: 'utf8' }));
    assert.deepEqual(audioProbe.streams.map(s => s.codec_type), ['audio']);
    execFileSync('ffmpeg', ['-nostdin', '-v', 'error', '-i', audioFile, '-f', 'null', '-']);
    console.log('Browser: audio-only output verified.');

    const commentsId = await createJob(3, '仅弹幕');
    await waitForJob(commentsId, j => j.state === 'completed');
    const commentsFile = await saveOutput('comments-only.ass');
    const comments = fs.readFileSync(commentsFile, 'utf8');
    assert.ok(comments.includes('[Events]') && comments.includes('本地弹幕'));
    assert.equal(mediaRequests.some(r => r.aid === '3'), false);
    console.log('Browser: comments-only output verified.');

    if (fixture) {
      const pausedId = await createJob(4);
      await waitForJob(pausedId, j => j.stage === 'videoDownload' && j.received > 0 && j.received < j.total);
      await page.getByRole('button', { name: '暂停', exact: true }).click();
      await waitForJob(pausedId, j => j.state === 'paused');
      await releaseMedia();
      await page.getByRole('button', { name: '继续', exact: true }).click();
      await waitForJob(pausedId, j => j.state === 'completed');
      assert.ok(mediaRequests.some(r => r.aid === '4' && r.start > 0), 'Resume must request the remaining byte range');
      await saveOutput('resumed.mp4');
      console.log('Browser: partial byte resume verified.');
    }

    const failedId = await createJob(5);
    await waitForJob(failedId, j => j.state === 'failed');
    await page.getByRole('button', { name: '继续', exact: true }).click();
    await waitForJob(failedId, j => j.state === 'completed');
    await saveOutput('retried.mp4');
    console.log('Browser: failed task retry verified.');

    if (fixture) {
      const disconnectedId = await createJob(6);
      await waitForJob(disconnectedId, j => j.stage === 'videoDownload' && j.received > 0 && j.received < j.total);
      await activeSocket.close({ code: 1011, reason: 'fixture disconnect' });
      await page.getByRole('button', { name: '继续', exact: true }).waitFor();
      assert.match(await page.locator('body').ariaSnapshot(), /与服务连接中断；任务可能仍在执行，可点击继续重新连接。/);
      await releaseMedia();
      await page.getByRole('button', { name: '继续', exact: true }).click();
      await waitForJob(disconnectedId, j => j.state === 'completed');
      await saveOutput('reconnected.mp4');
      console.log('Browser: WebSocket reconnect verified.');
    }
    const lostResponseId = await createJob(7, '视频', true);
    await page.getByRole('button', { name: '继续', exact: true }).waitFor();
    const resubmitted = observe(page.waitForResponse(r => r.url().endsWith('/api/jobs') && r.request().method() === 'POST'));
    await page.getByRole('button', { name: '继续', exact: true }).click();
    assert.equal((await (await resubmitted).json()).id, lostResponseId);
    await waitForJob(lostResponseId, j => j.state === 'completed');
    await saveOutput('lost-response-recovered.mp4');
    const origin = new URL(page.url()).origin;
    const history = await context.request.post(`${origin}/api/session`, { headers: { Origin: origin, 'X-Bili-Client': '1' }, data: {} });
    const restored = await history.json();
    assert.equal(restored.jobs.filter(j => j.episode.aid === 7).length, 1);
    console.log('Browser: lost create response recovered without a duplicate task.');

    for (const name of ['resumed.mp4', 'retried.mp4', 'reconnected.mp4', 'lost-response-recovered.mp4']) {
      if (!fixture && ['resumed.mp4', 'reconnected.mp4'].includes(name)) continue;
      execFileSync('ffmpeg', ['-nostdin', '-v', 'error', '-i', path.join(output, name), '-map', '0:v:0', '-map', '0:a:0', '-f', 'null', '-']);
    }
    await typeInto(page.getByRole('textbox'), 'AV1');
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
      serviceRestartPreservedTask: !!fixture, qrLogin: true, audioOnly: true, commentsOnly: true,
      failedTaskResumed: true, partialByteResume: !!fixture, disconnectedTaskReconnected: !!fixture,
      lostCreateResponseRecovered: true,
      mediaRequests }, null, 2));
    for (const name of ['failure.png', 'failure-aria.txt', 'failure-network.json', 'failure-inputs.json']) fs.rmSync(path.join(output, name), { force: true });
    console.log(`Browser fixture passed: batch partial failure, download, FFmpeg merge, file export, refresh recovery, QR login, audio/comments, failure recovery, mobile rendering${fixture ? ', service restart, partial byte resume, WebSocket reconnect' : ''}.`);
  } catch (error) {
    fs.writeFileSync(path.join(output, 'failure-network.json'), JSON.stringify({ network, errors, mediaRequests, jobHistory }, null, 2));
    if (page && !page.isClosed()) {
      await page.locator('textarea, input').evaluateAll(fields => fields.map(e => ({ html: e.outerHTML, parent: e.parentElement.outerHTML }))).then(fields => fs.writeFileSync(path.join(output, 'failure-inputs.json'), JSON.stringify(fields, null, 2))).catch(() => {});
      await page.screenshot({ path: path.join(output, 'failure.png') }).catch(() => {});
      await page.locator('body').ariaSnapshot().then(snapshot => fs.writeFileSync(path.join(output, 'failure-aria.txt'), snapshot)).catch(() => {});
    }
    throw error;
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
