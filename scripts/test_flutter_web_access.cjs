// Real HTTPS reverse proxy + Chrome. Credentials exist only in process memory.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const https = require('node:https');
const http = require('node:http');
const net = require('node:net');
const { randomBytes } = require('node:crypto');
const { spawn, execFileSync } = require('node:child_process');
const { createInterface } = require('node:readline');

(async () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'bili-https-test-'));
  const output = path.resolve(__dirname, '../artifacts/access');
  fs.mkdirSync(output, { recursive: true });
  const key = randomBytes(32).toString('hex');
  let proxy, fixture, lines, browser, page;
  const sockets = new Set(), errors = [];
  function fixtureMessage(prefix) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => finish(new Error(`Fixture timeout: ${prefix}`)), 30000);
      function line(value) { if (value.startsWith(prefix)) finish(); }
      function exit() { finish(new Error('Fixture exited')); }
      function finish(error) {
        clearTimeout(timer); lines.off('line', line); fixture.off('exit', exit);
        error ? reject(error) : resolve();
      }
      lines.on('line', line); fixture.once('exit', exit);
    });
  }
  async function command(value, response) {
    const done = fixtureMessage(response); fixture.stdin.write(`${value}\n`); await done;
  }
  try {
    execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', path.join(temp, 'tls.key'),
      '-out', path.join(temp, 'tls.crt'), '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=IP:127.0.0.1'], { stdio: 'ignore' });
    proxy = https.createServer({ key: fs.readFileSync(path.join(temp, 'tls.key')), cert: fs.readFileSync(path.join(temp, 'tls.crt')) }, (req, res) => {
      const upstream = http.request({ hostname: '127.0.0.1', port: 18744, path: req.url, method: req.method, headers: req.headers }, r => {
        res.writeHead(r.statusCode, r.headers); r.pipe(res);
      });
      upstream.on('error', () => { res.writeHead(502); res.end(); });
      req.pipe(upstream);
    });
    proxy.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
    proxy.on('upgrade', (req, socket, head) => {
      const upstream = net.connect(18744, '127.0.0.1', () => {
        upstream.write(`GET ${req.url} HTTP/1.1\r\n${Object.entries(req.headers).map(([k, v]) => `${k}: ${v}`).join('\r\n')}\r\n\r\n`);
        if (head.length) upstream.write(head);
        socket.pipe(upstream); upstream.pipe(socket);
      });
      upstream.on('error', () => socket.destroy());
      socket.on('error', () => upstream.destroy());
      socket.on('close', () => upstream.destroy());
      upstream.on('close', () => socket.destroy());
    });
    await new Promise(resolve => proxy.listen(0, '127.0.0.1', resolve));
    const origin = `https://127.0.0.1:${proxy.address().port}`;
    fixture = spawn('dart', ['run', 'test/fixtures/browser_service.dart'], {
      cwd: path.resolve(__dirname, '../flutter_app'), stdio: ['pipe', 'pipe', 'inherit'],
      env: { ...process.env, BILI_FIXTURE_ACCESS_KEY: key, BILI_FIXTURE_PUBLIC_ORIGIN: origin },
    });
    lines = createInterface({ input: fixture.stdout });
    await fixtureMessage('Fixture ready:');
    browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true,
      args: process.getuid?.() === 0 ? ['--no-sandbox'] : [] });
    // Certificate trust is overridden only for this ephemeral test certificate.
    const context = await browser.newContext({ ignoreHTTPSErrors: true, acceptDownloads: true, viewport: { width: 360, height: 800 } });
    context.setDefaultTimeout(15000);
    page = await context.newPage(); page.on('pageerror', e => errors.push(e.message));
    async function post(route, data = {}, target = context) {
      return target.request.post(`${origin}${route}`, { headers: { Origin: origin, 'X-Bili-Client': '1' }, data });
    }
    async function semantics() {
      await page.locator('flt-glass-pane').waitFor({ state: 'attached' });
      const placeholder = page.locator('flt-semantics-placeholder');
      if (await placeholder.count()) await placeholder.evaluate(e => e.click());
    }
    async function typeInto(input, value) {
      await input.click();
      await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
      await page.keyboard.press('ControlOrMeta+A'); await page.keyboard.insertText(value);
      await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
      assert.equal(await page.locator('input:focus, textarea:focus').evaluate(e => e.value.length), value.length, 'Focused input length');
    }
    async function unlock(button = '连接服务') {
      await typeInto(page.getByRole('textbox', { name: '访问密钥', exact: true }), key);
      await page.getByRole('button', { name: button, exact: true }).click();
      await page.getByRole('textbox', { name: '访问密钥', exact: true }).waitFor({ state: 'hidden' });
      if (page.viewportSize().width >= 900) {
        await page.getByRole('button', { name: '新建下载', exact: true }).click();
      } else {
        await page.getByRole('tab', { name: '新建下载', exact: true }).click();
      }
      await page.getByRole('button', { name: '解析链接', exact: true }).waitFor();
    }
    const unauthenticated = await post('/api/session');
    assert.deepEqual(await unauthenticated.json(), { accessRequired: true, accessGranted: false });
    assert.equal((await context.cookies()).length, 0);
    await page.goto(origin, { waitUntil: 'networkidle' }); await semantics();
    await page.getByRole('button', { name: '连接服务', exact: true }).waitFor();
    await page.screenshot({ path: path.join(output, 'mobile-access.png') });
    await typeInto(page.getByRole('textbox', { name: '访问密钥', exact: true }), 'incorrect');
    await page.getByRole('button', { name: '连接服务', exact: true }).click();
    await page.getByText('访问密钥不正确', { exact: true }).last().waitFor();
    await unlock();
    const owner = await (await post('/api/session')).json();
    const cookie = (await context.cookies()).find(c => c.name === '__Host-bili_session');
    assert.ok(cookie && cookie.secure && cookie.httpOnly && cookie.sameSite === 'Strict');
    assert.equal(await page.evaluate(() => document.cookie.includes('bili_session')), false);
    assert.equal((await page.evaluate(() => JSON.stringify(localStorage))).includes(key), false);
    console.log('Access: HTTPS gate, incorrect key and protected cookie verified.');

    await page.setViewportSize({ width: 1440, height: 1080 });
    await typeInto(page.getByRole('textbox', { name: /已识别:|粘贴一个或多个/ }), 'av1');
    await page.getByRole('button', { name: '解析链接', exact: true }).click();
    await page.getByRole('group', { name: /跨端下载验证 · AV1/ }).waitFor();
    await page.getByRole('button', { name: '获取可用画质', exact: true }).click();
    await page.getByRole('button', { name: '加入下载队列 (1)', exact: true }).click();
    const fileButton = page.getByRole('button', { name: '下载文件 1', exact: true });
    await fileButton.waitFor({ timeout: 30000 });
    const downloaded = page.waitForEvent('download'); await fileButton.click();
    const file = path.join(output, 'authenticated.mp4'); await (await downloaded).saveAs(file);
    execFileSync('ffmpeg', ['-nostdin', '-v', 'error', '-i', file, '-map', '0:v:0', '-map', '0:a:0', '-f', 'null', '-']);
    const state = await (await post('/api/session')).json();
    const job = state.jobs[0], fileUrl = `${origin}${job.outputs[0].url}`;
    const other = await browser.newContext({ ignoreHTTPSErrors: true });
    assert.equal((await other.request.get(fileUrl)).status(), 401);
    const otherSession = await (await post('/api/access/unlock', { key }, other)).json();
    assert.notEqual(otherSession.workspace, owner.workspace);
    assert.ok([403, 404].includes((await other.request.get(fileUrl)).status()));
    console.log('Access: authenticated download and cross-workspace file isolation verified.');

    await page.getByRole('button', { name: '设置', exact: true }).first().click();
    await page.getByRole('button', { name: '锁定服务访问', exact: true }).click();
    await page.getByRole('button', { name: '连接服务', exact: true }).waitFor();
    assert.equal((await context.request.get(fileUrl)).status(), 401);
    await unlock();
    assert.equal((await (await post('/api/session')).json()).jobs[0].id, job.id);
    await command('expire', 'Fixture expired:');
    assert.equal((await (await post('/api/session')).json()).accessGranted, false);
    await page.getByRole('button', { name: '连接服务', exact: true }).waitFor();
    await unlock();
    await command('restart', 'Fixture restarted:');
    await page.reload({ waitUntil: 'networkidle' }); await semantics();
    await page.getByRole('button', { name: '下载任务', exact: true }).click();
    await page.getByRole('button', { name: '下载文件 1', exact: true }).waitFor();
    assert.equal((await (await post('/api/session')).json()).jobs[0].id, job.id);
    console.log('Access: lock, expiry and service restart preserve the original task.');

    await page.getByRole('button', { name: '新建下载', exact: true }).click();
    await typeInto(page.getByRole('textbox', { name: /已识别:|粘贴一个或多个/ }), 'av2');
    assert.equal(await page.getByRole('button', { name: '解析链接', exact: true }).isEnabled(), true, 'Draft reached the Flutter controller');
    await post('/api/access/lock');
    await page.getByRole('button', { name: '连接服务', exact: true }).waitFor();
    await unlock();
    const draft = page.getByRole('textbox', { name: /已识别:|粘贴一个或多个/ });
    await draft.click();
    await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
    assert.equal(await draft.inputValue(), 'av2');

    const ownedCookies = await context.cookies();
    await context.clearCookies();
    await page.reload({ waitUntil: 'networkidle' }); await semantics();
    await page.getByRole('button', { name: '创建新的工作区', exact: true }).waitFor();
    await page.screenshot({ path: path.join(output, 'expired-workspace.png') });
    await unlock('创建新的工作区');
    const replacement = await (await post('/api/session')).json();
    assert.notEqual(replacement.workspace, owner.workspace); assert.deepEqual(replacement.jobs, []);
    const recovered = await browser.newContext({ ignoreHTTPSErrors: true }); await recovered.addCookies(ownedCookies);
    assert.equal((await (await post('/api/session', {}, recovered)).json()).jobs[0].id, job.id);
    assert.deepEqual(errors, []);
    fs.writeFileSync(path.join(output, 'browser-result.json'), JSON.stringify({ httpsProxy: true, incorrectKeyRejected: true,
      secureCookie: true, authenticatedDownloadDecoded: true, crossWorkspaceFileDenied: true, lockPreservedTask: true,
      expiryPreservedTask: true, serviceRestartPreservedTask: true, draftPreserved: true,
      lostOwnershipRequiresExplicitWorkspace: true, errors }, null, 2));
    for (const name of ['failure.png', 'failure-aria.txt']) fs.rmSync(path.join(output, name), { force: true });
    console.log('Access browser flow passed.');
  } catch (error) {
    if (page && !page.isClosed()) {
      await page.screenshot({ path: path.join(output, 'failure.png') }).catch(() => {});
      await page.locator('body').ariaSnapshot().then(text => fs.writeFileSync(path.join(output, 'failure-aria.txt'), text.replaceAll(key, '[redacted]'))).catch(() => {});
    }
    throw error;
  } finally {
    await browser?.close();
    if (fixture?.pid && fixture.exitCode === null && fixture.signalCode === null) {
      const stopped = new Promise(resolve => fixture.once('exit', resolve)); fixture.kill('SIGTERM');
      const timer = setTimeout(() => fixture.kill('SIGKILL'), 10000); await stopped; clearTimeout(timer);
    }
    lines?.close();
    for (const socket of sockets) socket.destroy();
    if (proxy) await new Promise(resolve => proxy.close(resolve));
    fs.rmSync(temp, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
