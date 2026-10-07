import { test, expect, type Page } from '@playwright/test';
import { copyFile, mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { WebSocketServer, WebSocket } from 'ws';
import { pairingAddress, machineSections, parseRoster } from '../src/protocol';

const projects = [
  { id: 'local', deviceAlias: null, name: 'Hidden project', workspaceName: 'Hidden workspace', sessions: [
    { id: 'shell', title: 'Local shell', agent: 'terminal', status: 'idle' },
    { id: 'agent', title: 'Build the companion', agent: 'codex', status: 'working' },
  ] },
  { id: 'remote', deviceAlias: 'build-server', sessions: [
    { id: 'remote-shell', title: 'Deployment logs', agent: 'terminal', status: 'needsAttention' },
  ] },
];
let server: WebSocketServer;
let address: string;
let rosterSockets: Set<WebSocket>;
let sessionSockets: Map<string, WebSocket>;
let controls: { socket: WebSocket; message: Record<string, unknown> }[];
let inputs: { session: string; bytes: Buffer }[];
let handshakes: string[];
let macID: string;
let macName: string;
let refuse = false;
let followViewport = false;

function roster(socket: WebSocket, rows = projects): void {
  socket.send(JSON.stringify({ t: 'roster', wire: 2, macID, macName, projects: rows }));
}

test.beforeEach(async () => {
  rosterSockets = new Set(); sessionSockets = new Map(); controls = []; inputs = []; handshakes = [];
  macID = 'fixture-mac'; macName = 'Studio Mac'; refuse = false; followViewport = false;
  server = new WebSocketServer({ port: 0, host: '127.0.0.1' });
  await new Promise<void>((resolve) => server.once('listening', resolve));
  const binding = server.address();
  if (!binding || typeof binding === 'string') throw new Error('Missing fixture port');
  address = `ws://127.0.0.1:${binding.port}/?t=test-pairing-token`;
  server.on('connection', (socket, request) => {
    handshakes.push(request.url ?? '');
    let authenticated = false;
    let session = '';
    socket.on('message', (data, binary) => {
      if (binary) {
        if (!authenticated || !session) throw new Error('Input before attachment');
        inputs.push({ session, bytes: Buffer.from(data as Buffer) });
        socket.send(data, { binary: true });
        return;
      }
      const message = JSON.parse(data.toString());
      controls.push({ socket, message });
      if (!authenticated) {
        expect(message).toEqual({ t: 'auth', token: 'test-pairing-token', wire: 2 });
        if (refuse) {
          socket.send(JSON.stringify({ t: 'error', code: 'unauthorized' }));
          socket.close();
          return;
        }
        authenticated = true;
        rosterSockets.add(socket);
        roster(socket);
      } else if (message.t === 'attach') {
        session = message.session;
        rosterSockets.delete(socket);
        sessionSockets.set(session, socket);
        socket.send(JSON.stringify({ t: 'grid', cols: 90, rows: 28, writer: false }));
        socket.send(Buffer.from(`\x1b[2J\x1b[H\x1b[32m${session}\x1b[0m ready\r\n`));
        const text = Buffer.from('UTF-8: café 日本語 🌍\r\n$ ');
        socket.send(text.subarray(0, 12));
        socket.send(text.subarray(12));
      } else if (message.t === 'resize' && followViewport) {
        socket.send(JSON.stringify({ t: 'grid', cols: message.cols, rows: message.rows, writer: true }));
      }
    });
    socket.on('close', () => { rosterSockets.delete(socket); });
  });
});

test.afterEach(async () => {
  server.clients.forEach((socket) => socket.terminate());
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

async function pair(page: Page, url = address, remember = false): Promise<void> {
  await page.getByRole('button', { name: 'Add Machine', exact: true }).first().click();
  await page.getByLabel('Mobile WebSocket URI').fill(url);
  if (remember) await page.getByLabel('Remember on this browser').check();
  await page.getByRole('button', { name: 'Connect', exact: true }).click();
  await expect(page.getByRole('dialog')).not.toBeVisible();
}
async function terminalText(page: Page): Promise<string> {
  const accessible = page.locator('.xterm-accessibility-tree');
  return (await accessible.count() ? accessible : page.locator('.xterm-rows')).innerText();
}
async function openShell(page: Page, screenReaderMode = true): Promise<void> {
  await page.goto('./index.html');
  await pair(page);
  await page.getByRole('button', { name: /Local shell/ }).click();
  if (screenReaderMode) await page.getByLabel('Screen reader', { exact: true }).check();
  await page.locator('.xterm-helper-textarea').focus();
  await expect.poll(() => terminalText(page)).toContain('shell ready');
}

test('pairing validation and roster grouping preserve the companion contract', () => {
  expect(pairingAddress(' https://example.com:8443/path?t=a%2Bb&foo=1#fragment ', 'http:')).toEqual({
    url: 'wss://example.com:8443/path?t=a%2Bb&foo=1', token: 'a+b', endpoint: 'wss://example.com:8443/path?foo=1', host: 'example.com:8443',
  });
  for (const input of ['no url', 'ftp://example.com?t=a', 'ws://user:pass@example.com?t=a', 'ws://example.com', 'ws://example.com?t=a&t=b', 'ws://example.com:0?t=a']) {
    expect(() => pairingAddress(input, 'http:')).toThrow();
  }
  expect(() => pairingAddress('termio://device/123', 'http:')).toThrow(/Direct Attach/);
  expect(() => pairingAddress('ws://example.com?t=a', 'https:')).toThrow(/secure/);
  const parsed = parseRoster({ t: 'roster', wire: 2, projects: [...projects, { id: 'other', sessions: [{ id: 'shell', title: 'Updated shell' }, null, {}] }, null, {}] });
  expect(machineSections(parsed.projects).map((group) => [group.alias, group.sessions.length])).toEqual([['', 2], ['build-server', 1]]);
  expect(() => parseRoster({ t: 'roster', wire: 1 })).toThrow(/Update Termio/);
});

test('renders machines and a real xterm terminal with UTF-8, ANSI, keyboard, paste and resize', async ({ page }, testInfo) => {
  const errors: string[] = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await openShell(page);
  await expect(page.getByRole('button', { name: 'This machine 2' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'build-server 1' })).toBeVisible();
  await expect(page.getByText('Hidden project')).not.toBeVisible();
  await expect.poll(() => terminalText(page)).toContain('UTF-8: café 日本語 🌍');
  await expect(page.locator('#terminal-size')).toHaveText('90 × 28');
  expect(handshakes.every((uri) => !uri.includes('test-pairing-token'))).toBe(true);
  expect(rosterSockets.size).toBe(1);
  expect(sessionSockets.size).toBe(1);
  const shellSocket = sessionSockets.get('shell');
  expect(controls.filter((entry) => entry.socket === shellSocket).map((entry) => entry.message.t).slice(0, 3)).toEqual(['auth', 'attach', 'resize']);
  const input = page.locator('.xterm-helper-textarea');
  await input.focus();
  await page.keyboard.type('echo hello');
  await page.keyboard.press('Enter');
  await page.keyboard.press('Control+c');
  await input.evaluate((textarea) => {
    const data = new DataTransfer();
    data.setData('text/plain', 'café 日本語');
    textarea.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true }));
  });
  await expect.poll(() => Buffer.concat(inputs.map((input) => input.bytes)).toString()).toBe('echo hello\r\x03café 日本語');
  await page.getByLabel('Screen reader', { exact: true }).uncheck();
  await input.focus();
  await page.keyboard.insertText('é日本語🌍');
  await expect.poll(() => Buffer.concat(inputs.map((input) => input.bytes)).toString()).toBe('echo hello\r\x03café 日本語é日本語🌍');
  await page.getByLabel('Screen reader', { exact: true }).check();
  followViewport = true;
  await page.setViewportSize({ width: 1450, height: 940 });
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'resize').at(-1)?.message.cols).toBeGreaterThan(90);
  await expect.poll(() => page.locator('#terminal-size').innerText()).not.toBe('90 × 28');
  await page.screenshot({ path: testInfo.outputPath('connected.png') });
  expect(errors).toEqual([]);
});

test('keeps roster updates live and isolates sessions, exit, detach and reconnect', async ({ page }) => {
  await openShell(page);
  const oldSocket = sessionSockets.get('shell');
  await page.getByRole('button', { name: /Deployment logs/ }).click();
  await expect.poll(() => terminalText(page)).toContain('remote-shell ready');
  await expect.poll(() => oldSocket?.readyState).toBe(WebSocket.CLOSED);
  const remoteSocket = sessionSockets.get('remote-shell');
  remoteSocket?.terminate();
  await expect(page.locator('#session-status')).toHaveText('Reconnecting…');
  await expect.poll(() => sessionSockets.get('remote-shell')).not.toBe(remoteSocket);
  await expect.poll(() => terminalText(page)).toContain('remote-shell ready');
  for (const socket of rosterSockets) roster(socket, [{ ...projects[0], sessions: [projects[0].sessions[0]] }, projects[1]]);
  await expect(page.getByRole('button', { name: /Build the companion/ })).not.toBeVisible();
  sessionSockets.get('remote-shell')?.send(JSON.stringify({ t: 'exit', code: 7 }));
  await expect(page.locator('#session-status')).toHaveText('Ended (7)');
  await expect.poll(() => terminalText(page)).toContain('remote-shell ready');
  await page.getByRole('button', { name: 'Detach', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Select a session' })).toBeVisible();
  expect(controls.some((entry) => entry.message.t === 'stop')).toBe(false);
});

test('supports multiple Macs, opt-in persistence, and confirmed forgetting', async ({ page }) => {
  await page.goto('./index.html');
  await pair(page, address, true);
  await expect(page.getByRole('heading', { name: 'Studio Mac', exact: true })).toBeVisible();
  macID = 'second-mac'; macName = 'Laptop';
  await pair(page, address.replace('/?', '/second?'));
  await expect(page.getByRole('heading', { name: 'Laptop', exact: true })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Studio Mac', exact: true })).toBeVisible();
  const saved = await page.evaluate(() => JSON.parse(localStorage.getItem('termio.web.machines.v1') ?? '[]'));
  expect(saved).toHaveLength(1);
  macID = 'fixture-mac'; macName = 'Studio Mac';
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Studio Mac', exact: true })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Laptop', exact: true })).not.toBeVisible();
  await page.getByRole('button', { name: 'Forget Studio Mac' }).click();
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Studio Mac', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Forget Studio Mac' }).click();
  await page.getByRole('button', { name: 'Forget Machine', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Studio Mac', exact: true })).not.toBeVisible();
  expect(await page.evaluate(() => localStorage.getItem('termio.web.machines.v1'))).toBe('[]');
  await pair(page);
  await page.getByRole('button', { name: 'Forget Studio Mac' }).click();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('heading', { name: 'Studio Mac', exact: true })).toBeVisible();
});

test('shows rejected tokens without a retry loop and validates Direct Attach links', async ({ page }) => {
  await page.goto('./index.html');
  await page.getByRole('button', { name: 'Add Machine', exact: true }).first().click();
  await page.getByLabel('Mobile WebSocket URI').fill('termio://device/123');
  await page.getByRole('button', { name: 'Connect', exact: true }).click();
  await expect(page.getByRole('alert')).toContainText('Turn off Direct Attach');
  refuse = true;
  await page.getByLabel('Mobile WebSocket URI').fill(address);
  await page.getByRole('button', { name: 'Connect', exact: true }).click();
  await expect(page.getByText(/This pairing token was refused/)).toBeVisible();
  await expect(page.getByText('Disconnected', { exact: true })).toBeVisible();
  expect(controls).toHaveLength(1);
  expect(await page.evaluate(() => localStorage.getItem('termio.web.machines.v1'))).toBe('[]');
});

test('handles an invalid shared grid and fits the two-pane layout on a small screen', async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 680, height: 700 });
  await openShell(page);
  const sidebar = await page.getByRole('complementary').boundingBox();
  const main = await page.getByRole('main').boundingBox();
  expect(sidebar && main && sidebar.x + sidebar.width <= main.x).toBe(true);
  sessionSockets.get('shell')?.send(JSON.stringify({ t: 'grid', cols: 0, rows: 28 }));
  await expect(page.locator('#terminal-error')).toContainText('invalid terminal size');
  await page.screenshot({ path: testInfo.outputPath('small-screen.png') });
});

test('runs from a single copied HTML file without any HTTP server or asset requests', async ({ page, context }) => {
  const directory = new URL('../dist/', import.meta.url);
  expect(await readdir(directory)).toEqual(['index.html']);
  const temporary = await mkdtemp(join(tmpdir(), 'termio-standalone-'));
  try {
    const copied = join(temporary, 'Termio standalone.html');
    await copyFile(fileURLToPath(new URL('index.html', directory)), copied);
    const networkRequests: string[] = [];
    const errors: string[] = [];
    page.on('request', (request) => { if (/^https?:/.test(request.url())) networkRequests.push(request.url()); });
    page.on('pageerror', (error) => errors.push(error.message));
    await page.route(/^https?:/, (route) => route.abort());
    await context.setOffline(true);
    await page.goto(pathToFileURL(copied).href);
    await expect(page.getByRole('heading', { name: 'Your sessions, here.' })).toBeVisible();
    await expect(page.locator('script[src], link[rel="stylesheet"]')).toHaveCount(0);
    await context.setOffline(false);
    await page.getByLabel('Screen reader', { exact: true }).check();
    await pair(page);
    await page.getByRole('button', { name: /Local shell/ }).click();
    await expect.poll(() => terminalText(page)).toContain('UTF-8: café 日本語 🌍');
    await page.locator('.xterm-helper-textarea').focus();
    await page.keyboard.type('standalone');
    await expect.poll(() => Buffer.concat(inputs.map((input) => input.bytes)).toString()).toBe('standalone');
    expect(networkRequests).toEqual([]);
    expect(errors).toEqual([]);
  } finally {
    await page.close();
    await rm(temporary, { recursive: true, force: true });
  }
});

test('uses the app logo and retracts the sidebar without interrupting the terminal', async ({ page }, testInfo) => {
  followViewport = true;
  await openShell(page);
  const logo = await readFile(new URL('../../landing/public/logo.png', import.meta.url));
  const embeddedLogo = `data:image/png;base64,${logo.toString('base64')}`;
  await expect(page.locator('.brand-mark')).toHaveAttribute('src', embeddedLogo);
  await expect.poll(() => page.locator('.brand-mark').evaluate((image: HTMLImageElement) => image.naturalWidth)).toBe(128);
  await expect(page.locator('link[rel="icon"]')).toHaveAttribute('href', embeddedLogo);
  const attribution = page.getByRole('link', { name: 'Termio by Jiwei Yuan', exact: true });
  await expect(attribution).toHaveAttribute('href', 'https://termio.sh');
  await expect(attribution).toHaveAttribute('rel', 'noopener noreferrer');
  const initialColumns = Number((await page.locator('#terminal-size').innerText()).split(' × ')[0]);
  const socket = sessionSockets.get('shell');
  await page.screenshot({ path: testInfo.outputPath('sidebar-expanded.png') });
  await page.getByRole('button', { name: 'Collapse Sidebar', exact: true }).click();
  await expect(page.locator('#sidebar')).not.toBeVisible();
  await expect(page.getByRole('button', { name: 'Expand Sidebar', exact: true })).toHaveAttribute('aria-expanded', 'false');
  await expect.poll(() => page.getByRole('main').evaluate((main) => Math.round(main.getBoundingClientRect().width))).toBe(1200);
  await expect.poll(async () => Number((await page.locator('#terminal-size').innerText()).split(' × ')[0])).toBeGreaterThan(initialColumns);
  await expect.poll(() => page.locator('#sidebar').evaluate((sidebar) => sidebar.getBoundingClientRect().right)).toBeLessThanOrEqual(0);
  expect(await page.locator('#sidebar').evaluate((sidebar) => sidebar.inert)).toBe(true);
  await page.locator('.xterm-helper-textarea').focus();
  await page.keyboard.type('still connected');
  await expect.poll(() => Buffer.concat(inputs.map((input) => input.bytes)).toString()).toBe('still connected');
  await expect.poll(() => terminalText(page)).toContain('still connected');
  expect(sessionSockets.get('shell')).toBe(socket);
  expect(socket?.readyState).toBe(WebSocket.OPEN);
  await page.screenshot({ path: testInfo.outputPath('sidebar-collapsed.png') });
  await page.getByRole('button', { name: 'Expand Sidebar', exact: true }).click();
  await expect(attribution).toBeVisible();
  await expect.poll(() => page.getByRole('main').evaluate((main) => Math.round(main.getBoundingClientRect().left))).toBe(286);
  await expect.poll(async () => Number((await page.locator('#terminal-size').innerText()).split(' × ')[0])).toBe(initialColumns);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.getByRole('button', { name: 'Collapse Sidebar', exact: true }).click();
  expect(await page.locator('#sidebar').evaluate((sidebar) => getComputedStyle(sidebar).transitionDuration)).toBe('0s');
  await page.setViewportSize({ width: 390, height: 740 });
  await expect.poll(() => page.getByRole('main').evaluate((main) => Math.round(main.getBoundingClientRect().width))).toBe(390);
  const toggle = page.getByRole('button', { name: 'Expand Sidebar', exact: true });
  await toggle.focus();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('button', { name: 'Collapse Sidebar', exact: true })).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(page.locator('#sidebar')).not.toBeVisible();
  await expect.poll(async () => Number((await page.locator('#terminal-size').innerText()).split(' × ')[0])).toBeLessThan(60);
  // The terminal paints on the next frame after the server's grid update.
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  await page.screenshot({ path: testInfo.outputPath('sidebar-collapsed-narrow.png') });
});


test('keeps the touch keyboard out of desktop sessions', async ({ page }) => {
  await openShell(page);
  await expect(page.locator('#touch-keys')).not.toBeVisible();
  await expect(page.locator('#toggle-keyboard')).not.toBeVisible();
  await page.setViewportSize({ width: 600, height: 700 });
  await expect(page.locator('#touch-keys')).not.toBeVisible();
});

test.describe('touch keyboard', () => {
  test.use({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } });

  test('sends special keys and one-shot modifiers while keeping terminal focus', async ({ page }, testInfo) => {
    await openShell(page, false);
    const bar = page.getByRole('group', { name: 'Terminal keys' });
    const textarea = page.locator('.xterm-helper-textarea');
    const key = (name: string) => bar.getByRole('button', { name, exact: true });
    const received = () => Buffer.concat(inputs.map((input) => input.bytes)).toString();
    await expect(bar).toBeVisible();
    await expect(page.locator('#sidebar')).not.toBeVisible();
    let expected = '';
    const send = async (name: string, sequence: string) => {
      await key(name).tap();
      expected += sequence;
      await expect.poll(received).toBe(expected);
      await expect(textarea).toBeFocused();
    };
    for (const [name, sequence] of [
      ['Escape', '\x1b'], ['Tab', '\t'], ['Arrow Left', '\x1b[D'], ['Arrow Down', '\x1b[B'],
      ['Arrow Up', '\x1b[A'], ['Arrow Right', '\x1b[C'], ['Home', '\x1b[H'], ['End', '\x1b[F'],
      ['Page Up', '\x1b[5~'], ['Page Down', '\x1b[6~'],
    ]) await send(name, sequence);
    await key('Control').tap();
    await expect(key('Control')).toHaveAttribute('aria-pressed', 'true');
    await page.keyboard.insertText('c');
    expected += '\x03';
    await expect.poll(received).toBe(expected);
    await expect(key('Control')).toHaveAttribute('aria-pressed', 'false');
    await page.keyboard.insertText('c');
    expected += 'c';
    await expect.poll(received).toBe(expected);
    await key('Alt').tap();
    await page.keyboard.insertText('b');
    expected += '\x1bb';
    await expect.poll(received).toBe(expected);
    await expect(key('Alt')).toHaveAttribute('aria-pressed', 'false');
    await key('Control').tap();
    await send('Arrow Left', '\x1b[1;5D');
    await key('Alt').tap();
    await key('Control').tap();
    await send('Arrow Right', '\x1b[1;7C');
    await key('Control').tap();
    await page.keyboard.insertText('ß');
    expected += 'ß';
    await expect.poll(received).toBe(expected);
    await key('Control').tap();
    await page.keyboard.insertText('日本語');
    expected += '日本語';
    await expect.poll(received).toBe(expected);
    await expect(key('Control')).toHaveAttribute('aria-pressed', 'false');
    sessionSockets.get('shell')?.send(Buffer.from('\x1b[?1h\r\napplication mode\r\n'));
    await expect.poll(() => terminalText(page)).toContain('application mode');
    await send('Arrow Up', '\x1bOA');
    await send('Home', '\x1bOH');
    await key('Tab').focus();
    await key('Tab').press('Enter');
    expected += '\t';
    await expect.poll(received).toBe(expected);
    await expect(textarea).toBeFocused();
    await key('Control').tap();
    await page.screenshot({ path: testInfo.outputPath('phone-keys.png') });
    await page.getByRole('button', { name: 'Hide Keyboard', exact: true }).tap();
    await expect(bar).not.toBeVisible();
    await expect(textarea).not.toBeFocused();
    await page.getByRole('button', { name: 'Show Keyboard', exact: true }).tap();
    await expect(bar).toBeVisible();
    await expect(key('Control')).toHaveAttribute('aria-pressed', 'false');
    await expect(textarea).toBeFocused();
    sessionSockets.get('shell')?.send(JSON.stringify({ t: 'exit', code: 0 }));
    await expect(page.locator('#session-status')).toHaveText('Ended (0)');
    await expect(bar).not.toBeVisible();
    await expect(page.locator('#toggle-keyboard')).not.toBeVisible();
    expect(inputs.every((input) => input.session === 'shell')).toBe(true);
  });

  test('fits tablet keyboard viewport changes and clears keys across sessions', async ({ page }, testInfo) => {
    await page.setViewportSize({ width: 820, height: 1180 });
    await page.addInitScript(() => {
      const viewport = new EventTarget();
      Object.assign(viewport, { height: 1180, offsetTop: 0, scale: 1 });
      Object.defineProperty(window, 'visualViewport', { value: viewport });
    });
    followViewport = true;
    await openShell(page, false);
    const bar = page.getByRole('group', { name: 'Terminal keys' });
    const control = bar.getByRole('button', { name: 'Control', exact: true });
    await expect(bar).toBeVisible();
    await expect(page.locator('#sidebar')).toBeVisible();
    const previousRows = controls.filter((entry) => entry.message.t === 'resize').at(-1)?.message.rows;
    await page.evaluate(() => {
      Object.assign(window.visualViewport!, { height: 470, offsetTop: 30 });
      window.visualViewport!.dispatchEvent(new Event('resize'));
      window.visualViewport!.dispatchEvent(new Event('scroll'));
    });
    await expect.poll(() => page.locator('#app').evaluate((app) => app.getBoundingClientRect().bottom)).toBe(500);
    await expect.poll(() => Number(controls.filter((entry) => entry.message.t === 'resize').at(-1)?.message.rows)).toBeLessThan(Number(previousRows));
    for (const button of await bar.getByRole('button').all()) {
      const box = await button.boundingBox();
      expect(box && box.x >= 0 && box.x + box.width <= 820 && box.y >= 30 && box.y + box.height <= 500).toBe(true);
      expect(box && box.width >= 44 && box.height >= 44).toBe(true);
    }
    await page.screenshot({ path: testInfo.outputPath('tablet-keyboard-viewport.png') });
    await page.setViewportSize({ width: 1180, height: 820 });
    await expect.poll(() => bar.evaluate((element) => element.getBoundingClientRect().height)).toBeLessThan(70);
    await page.screenshot({ path: testInfo.outputPath('tablet-landscape-keys.png') });
    await control.tap();
    await page.getByRole('button', { name: /Deployment logs/ }).tap();
    await expect.poll(() => terminalText(page)).toContain('remote-shell ready');
    await expect(control).toHaveAttribute('aria-pressed', 'false');
    await bar.getByRole('button', { name: 'Tab', exact: true }).tap();
    await expect.poll(() => inputs.at(-1)?.session).toBe('remote-shell');
    await expect(page.locator('.xterm-helper-textarea')).toBeFocused();
    await page.evaluate(() => {
      Object.assign(window.visualViewport!, { scale: 2 });
      window.visualViewport!.dispatchEvent(new Event('resize'));
    });
    await expect(page.locator('#app')).not.toHaveClass(/touch-typing/);
    await page.getByRole('button', { name: 'Detach', exact: true }).tap();
    await expect(bar).not.toBeVisible();
    await expect(page.locator('#toggle-keyboard')).not.toBeVisible();
  });
});
