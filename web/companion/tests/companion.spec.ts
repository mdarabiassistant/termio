import { test, expect, type Page, type Locator } from '@playwright/test';
import { copyFile, mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { WebSocketServer, WebSocket } from 'ws';
import { pairingAddress, machineSections, parseRoster } from '../src/protocol';

const projects = [
  { id: 'local', deviceAlias: null, name: 'Hidden project', workspaceID: 'local-workspace', workspaceName: 'Hidden workspace', sessions: [
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
let confirmRenames = true;
let serverWire = 3;
let socketEndpoints: Map<WebSocket, string>;
let socketProjects: Map<WebSocket, typeof projects>;
let sessionNames: Map<string, Map<string, string>>;
let endpointProjects: Map<string, typeof projects>;
let endpointMachines: Map<string, { macID: string; macName: string }>;
let confirmCloses = true;
let closeError = '';

function roster(socket: WebSocket, rows = projects): void {
  socketProjects.set(socket, rows);
  const endpoint = socketEndpoints.get(socket) ?? '';
  endpointProjects.set(endpoint, rows);
  const names = sessionNames.get(endpoint);
  const identity = endpointMachines.get(endpoint) ?? { macID, macName };
  socket.send(JSON.stringify({ t: 'roster', wire: serverWire, ...identity, projects: rows.map((project) => ({
    ...project, sessions: project.sessions.map((session) => ({ ...session, title: names?.get(session.id) ?? session.title })),
  })) }));
}

test.beforeEach(async () => {
  rosterSockets = new Set(); sessionSockets = new Map(); controls = []; inputs = []; handshakes = [];
  macID = 'fixture-mac'; macName = 'Studio Mac'; refuse = false; followViewport = false;
  confirmRenames = true; serverWire = 3;
  socketEndpoints = new Map(); socketProjects = new Map(); sessionNames = new Map();
  endpointProjects = new Map(); endpointMachines = new Map(); confirmCloses = true; closeError = '';
  server = new WebSocketServer({ port: 0, host: '127.0.0.1' });
  await new Promise<void>((resolve) => server.once('listening', resolve));
  const binding = server.address();
  if (!binding || typeof binding === 'string') throw new Error('Missing fixture port');
  address = `ws://127.0.0.1:${binding.port}/?t=test-pairing-token`;
  server.on('connection', (socket, request) => {
    socketEndpoints.set(socket, request.url ?? '');
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
        expect(message).toEqual({ t: 'auth', token: 'test-pairing-token', wire: 3 });
        if (refuse) {
          socket.send(JSON.stringify({ t: 'error', code: 'unauthorized' }));
          socket.close();
          return;
        }
        authenticated = true;
        rosterSockets.add(socket);
        const endpoint = socketEndpoints.get(socket) ?? '';
        if (!endpointMachines.has(endpoint)) endpointMachines.set(endpoint, { macID, macName });
        roster(socket, endpointProjects.get(endpoint) ?? projects);
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
      } else if (message.t === 'renameSession' && confirmRenames) {
        const endpoint = socketEndpoints.get(socket) ?? '';
        const names = sessionNames.get(endpoint) ?? new Map<string, string>();
        names.set(message.session, message.name);
        sessionNames.set(endpoint, names);
        socket.send(JSON.stringify({ t: 'sessionRenamed', session: message.session, name: message.name, request: message.request }));
        for (const viewer of rosterSockets) {
          const rows = socketProjects.get(viewer);
          if (socketEndpoints.get(viewer) === endpoint && rows?.some((project) => project.sessions.some((session) => session.id === message.session))) roster(viewer, rows);
        }
      } else if (message.t === 'stop') {
        if (closeError) {
          socket.send(JSON.stringify({ t: 'error', message: closeError }));
          return;
        }
        if (!confirmCloses) return;
        const endpoint = socketEndpoints.get(socket) ?? '';
        const rows = (endpointProjects.get(endpoint) ?? projects).map((project) => ({
          ...project, sessions: project.sessions.filter((session) => session.id !== message.session),
        }));
        for (const viewer of rosterSockets) if (socketEndpoints.get(viewer) === endpoint) roster(viewer, rows);
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

async function requestTerminal(page: Page, scope: Page | Locator = page, name = 'New Session'): Promise<void> {
  if (!await page.locator('#session-name-dialog').isVisible()) {
    await scope.getByRole('button', { name: 'New Terminal', exact: true }).click();
  }
  await page.getByLabel('Session name', { exact: true }).fill(name);
  await page.getByRole('button', { name: /Create Session|Rename/, exact: true }).last().click();
}

async function sessionActions(page: Page, title: string, scope: Page | Locator = page): Promise<Locator> {
  await scope.getByRole('group', { name: title, exact: true }).getByRole('button', { name: 'Session Actions' }).click();
  return page.getByRole('menu', { name: 'Session Actions' });
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

test('creates and opens a terminal with the Android workspace hint', async ({ page }, testInfo) => {
  await openShell(page);
  const oldSocket = sessionSockets.get('shell');
  await requestTerminal(page, page, 'New shell');
  await expect(page.locator('.new-terminal')).toBeDisabled();
  await page.locator('.new-terminal').evaluate((button: HTMLButtonElement) => button.click());
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'startTerminal').length).toBe(1);
  const request = controls.find((entry) => entry.message.t === 'startTerminal');
  expect(request?.message).toEqual({ t: 'startTerminal', workspace: 'local-workspace' });
  expect(rosterSockets.has(request!.socket)).toBe(true);
  expect(oldSocket?.readyState).toBe(WebSocket.OPEN);
  const created = { id: 'new-terminal', title: 'New shell', agent: 'terminal', status: 'idle' };
  roster(request!.socket, [{ ...projects[0], sessions: [...projects[0].sessions, created] }, projects[1]]);
  request!.socket.send(JSON.stringify({ t: 'started', session: created.id, agent: 'terminal' }));
  await expect(page.locator('#session-title')).toHaveText('New shell');
  await expect.poll(() => terminalText(page)).toContain('new-terminal ready');
  await expect.poll(() => oldSocket?.readyState).toBe(WebSocket.CLOSED);
  await expect(page.getByRole('button', { name: 'New Terminal', exact: true })).toBeEnabled();
  await expect(page.getByRole('button', { name: /New shell/ })).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('.xterm-helper-textarea')).toBeFocused();
  await page.keyboard.type('echo created');
  await expect.poll(() => Buffer.concat(inputs.map((input) => input.bytes)).toString()).toBe('echo created');
  expect(inputs.every((input) => input.session === created.id)).toBe(true);
  expect(controls.some((entry) => entry.message.t === 'stop')).toBe(false);
  await page.screenshot({ path: testInfo.outputPath('new-terminal-desktop.png') });
});

test('creates the first terminal without a workspace and opens it before the roster update', async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 680, height: 700 });
  await page.goto('./index.html');
  await pair(page);
  await expect(page.getByRole('heading', { name: 'Studio Mac', exact: true })).toBeVisible();
  for (const socket of rosterSockets) roster(socket, []);
  await expect(page.locator('.session-row')).toHaveCount(0);
  await expect(page.getByText('Choose New Terminal to start a session on your Mac.')).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath('new-terminal-empty.png') });
  await page.getByLabel('Screen reader', { exact: true }).check();
  await requestTerminal(page);
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'startTerminal').length).toBe(1);
  const request = controls.find((entry) => entry.message.t === 'startTerminal');
  expect(request?.message).toEqual({ t: 'startTerminal' });
  request!.socket.send(JSON.stringify({ t: 'started', session: 'first-terminal', agent: 'terminal' }));
  await expect.poll(() => terminalText(page)).toContain('first-terminal ready');
  await expect(page.locator('#session-title')).toHaveText('New Session');
  roster(request!.socket, [{ ...projects[0], sessions: [{ id: 'first-terminal', title: 'First shell', agent: 'terminal', status: 'idle' }] }]);
  await expect(page.locator('#session-title')).toHaveText('New Session');
  await expect(page.locator('#session-status')).toHaveText('Connected');
  await page.screenshot({ path: testInfo.outputPath('new-terminal-narrow.png') });
});

test('shows creation failures and lets the user retry without dropping the current session', async ({ page }) => {
  await openShell(page);
  const currentSocket = sessionSockets.get('shell');
  await requestTerminal(page);
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'startTerminal').length).toBe(1);
  const socket = controls.find((entry) => entry.message.t === 'startTerminal')!.socket;
  socket.send(JSON.stringify({ t: 'error', message: 'Couldn’t open a terminal.' }));
  await expect(page.locator('#session-name-error')).toContainText('Couldn’t open a terminal.');
  await expect(page.getByRole('button', { name: 'New Terminal', exact: true })).toBeEnabled();
  await expect(page.locator('#session-title')).toHaveText('Local shell');
  expect(currentSocket?.readyState).toBe(WebSocket.OPEN);
  await requestTerminal(page);
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'startTerminal').length).toBe(2);
  await expect(page.locator('#session-name-error')).not.toBeVisible();
  socket.send(JSON.stringify({ t: 'started', session: '' }));
  await expect(page.locator('#session-name-error')).toContainText('The Mac didn’t return a session.');
  await expect(page.getByRole('button', { name: 'New Terminal', exact: true })).toBeEnabled();
  expect(sessionSockets.size).toBe(1);
});

test('clears a pending creation on connection loss without replaying the request', async ({ page }) => {
  await page.goto('./index.html');
  await pair(page);
  await requestTerminal(page);
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'startTerminal').length).toBe(1);
  controls.find((entry) => entry.message.t === 'startTerminal')!.socket.terminate();
  await expect(page.getByRole('button', { name: 'New Terminal', exact: true })).toBeDisabled();
  await expect(page.getByRole('button', { name: 'New Terminal', exact: true })).toBeEnabled();
  expect(controls.filter((entry) => entry.message.t === 'startTerminal')).toHaveLength(1);
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  await page.getByRole('button', { name: 'Disconnect', exact: true }).click();
  await expect(page.getByRole('button', { name: 'New Terminal', exact: true })).toBeDisabled();
});

test('times out a creation without replaying it or opening a late reply', async ({ page }) => {
  await page.clock.install();
  await page.goto('./index.html');
  await pair(page);
  await requestTerminal(page);
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'startTerminal').length).toBe(1);
  await page.clock.fastForward(15001);
  await expect(page.locator('#session-name-error')).toContainText('Check the session list before trying again.');
  await expect(page.getByRole('button', { name: 'New Terminal', exact: true })).toBeEnabled();
  const socket = controls.find((entry) => entry.message.t === 'startTerminal')!.socket;
  socket.send(JSON.stringify({ t: 'started', session: 'late-terminal' }));
  // A later roster still lists the session, but the expired request no longer changes selection.
  roster(socket, [{ ...projects[0], sessions: [{ id: 'late-terminal', title: 'Late shell', agent: 'terminal', status: 'idle' }] }]);
  await expect(page.getByRole('button', { name: /Late shell/ })).toBeVisible();
  await expect(page.locator('#terminal-viewport')).not.toBeVisible();
  expect(controls.filter((entry) => entry.message.t === 'startTerminal')).toHaveLength(1);
  expect(sessionSockets.size).toBe(0);
});

test('creates on the chosen Mac and respects a later session selection', async ({ page }) => {
  await openShell(page);
  macID = 'second-mac'; macName = 'Laptop';
  await pair(page, address.replace('/?', '/second?'));
  const laptop = page.locator('.paired-machine').filter({ has: page.getByRole('heading', { name: 'Laptop', exact: true }) });
  await requestTerminal(page, laptop);
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'startTerminal').length).toBe(1);
  const socket = controls.find((entry) => entry.message.t === 'startTerminal')!.socket;
  socket.send(JSON.stringify({ t: 'started', session: 'laptop-terminal' }));
  await expect.poll(() => terminalText(page)).toContain('laptop-terminal ready');
  await expect(page.locator('#session-context')).toHaveText('Laptop / This machine');
  await requestTerminal(page, laptop, 'Background shell');
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'startTerminal').length).toBe(2);
  const secondSocket = controls.filter((entry) => entry.message.t === 'startTerminal')[1].socket;
  await laptop.getByRole('button', { name: /Deployment logs/ }).evaluate((button: HTMLButtonElement) => button.click());
  await expect.poll(() => terminalText(page)).toContain('remote-shell ready');
  secondSocket.send(JSON.stringify({ t: 'started', session: 'background-terminal' }));
  roster(secondSocket, [{ ...projects[0], sessions: [{ id: 'background-terminal', title: 'Background shell', agent: 'terminal', status: 'idle' }] }, projects[1]]);
  await expect(laptop.getByRole('button', { name: /Background shell/ })).toBeVisible();
  await expect(page.locator('#session-title')).toHaveText('Deployment logs');
  expect(sessionSockets.has('background-terminal')).toBe(false);
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

test('session naming prompts with the selected default and cancels without creating anything', async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 740 });
  await page.goto('./index.html');
  await pair(page);
  await page.getByRole('button', { name: 'New Terminal', exact: true }).click();
  const field = page.getByLabel('Session name', { exact: true });
  await expect(field).toHaveValue('New Session');
  await expect(field).toBeFocused();
  expect(await field.evaluate((input: HTMLInputElement) => [input.selectionStart, input.selectionEnd])).toEqual([0, 11]);
  const dialog = page.locator('#session-name-dialog');
  const bounds = await dialog.boundingBox();
  expect(bounds && bounds.x >= 0 && bounds.x + bounds.width <= 390).toBe(true);
  await page.screenshot({ path: testInfo.outputPath('session-name-mobile.png') });
  await page.keyboard.press('Escape');
  await expect(dialog).not.toBeVisible();
  await page.getByRole('button', { name: 'New Terminal', exact: true }).click();
  await field.fill('   ');
  await page.getByRole('button', { name: 'Create Session', exact: true }).click();
  await expect(page.locator('#session-name-error')).toHaveText('Enter a session name.');
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  expect(controls.filter((entry) => ['startTerminal', 'renameSession'].includes(String(entry.message.t)))).toHaveLength(0);
});

test('names a new session through rename and waits for confirmation before opening it', async ({ page }, testInfo) => {
  confirmRenames = false;
  await openShell(page);
  const existingSocket = sessionSockets.get('shell');
  const name = 'Release "λ" 日本語 <script> & logs';
  await requestTerminal(page, page, `  ${name}  `);
  const started = controls.find((entry) => entry.message.t === 'startTerminal')!;
  started.socket.send(JSON.stringify({ t: 'started', session: 'named-terminal', agent: 'terminal' }));
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'renameSession').length).toBe(1);
  const rename = controls.find((entry) => entry.message.t === 'renameSession')!;
  expect(rename.socket).toBe(started.socket);
  expect(rename.message).toMatchObject({ session: 'named-terminal', name });
  expect(rosterSockets.has(rename.socket)).toBe(true);
  expect(existingSocket?.readyState).toBe(WebSocket.OPEN);
  expect(sessionSockets.has('named-terminal')).toBe(false);
  await expect(page.locator('#save-session-name')).toBeDisabled();
  await page.keyboard.press('Escape');
  await expect(page.locator('#session-name-dialog')).toBeVisible();
  roster(rename.socket, [{ ...projects[0], sessions: [...projects[0].sessions, { id: 'named-terminal', title: name, agent: 'terminal', status: 'idle' }] }]);
  rename.socket.send(JSON.stringify({ t: 'sessionRenamed', session: 'named-terminal', name, request: rename.message.request }));
  await expect(page.locator('#session-name-dialog')).not.toBeVisible();
  await expect(page.locator('#session-title')).toHaveText(name);
  await expect.poll(() => terminalText(page)).toContain('named-terminal ready');
  expect(controls.filter((entry) => entry.message.t === 'startTerminal')).toHaveLength(1);
  await page.screenshot({ path: testInfo.outputPath('named-session-desktop.png') });
});

test('session actions open beside the row and support keyboard and outside dismissal', async ({ page }, testInfo) => {
  await openShell(page);
  const row = page.getByRole('group', { name: 'Deployment logs', exact: true });
  const trigger = row.getByRole('button', { name: 'Session Actions' });
  const menu = await sessionActions(page, 'Deployment logs');
  await expect(menu.getByRole('menuitem')).toHaveText(['Rename', 'Close']);
  await expect(trigger).toHaveAttribute('aria-expanded', 'true');
  const anchorBounds = await trigger.boundingBox();
  const menuBounds = await menu.boundingBox();
  expect(anchorBounds && menuBounds && Math.abs(menuBounds.y - anchorBounds.y - anchorBounds.height) < 10).toBe(true);
  await expect(menu.getByRole('menuitem', { name: 'Rename' })).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(menu.getByRole('menuitem', { name: 'Close', exact: true })).toBeFocused();
  await page.screenshot({ path: testInfo.outputPath('session-actions.png') });
  await page.keyboard.press('Escape');
  await expect(menu).not.toBeVisible();
  await expect(trigger).toBeFocused();
  await trigger.click();
  await page.locator('#session-title').click();
  await expect(menu).not.toBeVisible();
  expect(controls.some((entry) => entry.message.t === 'stop')).toBe(false);
});

test('closing a remote session requires confirmation and refetches the roster without replacing another terminal', async ({ page }, testInfo) => {
  await openShell(page);
  const attached = sessionSockets.get('shell');
  const surface = await page.locator('.xterm').elementHandle();
  const before = await terminalText(page);
  const close = async () => {
    await (await sessionActions(page, 'Deployment logs')).getByRole('menuitem', { name: 'Close', exact: true }).click();
    await expect(page.getByRole('dialog', { name: 'Close Session?' })).toBeVisible();
  };
  await close();
  await expect(page.locator('#close-session-description')).toContainText('Deployment logs');
  expect(controls.some((entry) => entry.message.t === 'stop')).toBe(false);
  await page.screenshot({ path: testInfo.outputPath('close-session-confirmation.png') });
  await page.locator('#cancel-close-session').click();
  expect(controls.some((entry) => entry.message.t === 'stop')).toBe(false);
  await close();
  await page.keyboard.press('Escape');
  await expect(page.locator('#close-session-dialog')).not.toBeVisible();
  expect(controls.some((entry) => entry.message.t === 'stop')).toBe(false);
  await close();
  const beforeAuthentication = controls.filter((entry) => entry.message.t === 'auth').length;
  await page.locator('#confirm-close-session').click();
  await expect(page.locator('#close-session-dialog')).not.toBeVisible();
  await expect(page.getByRole('group', { name: 'Deployment logs', exact: true })).not.toBeVisible();
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'auth').length).toBe(beforeAuthentication + 1);
  const requests = controls.filter((entry) => entry.message.t === 'stop');
  expect(requests).toHaveLength(1);
  expect(requests[0].message).toEqual({ t: 'stop', session: 'remote-shell' });
  expect(requests[0].socket).not.toBe(attached);
  expect(sessionSockets.get('shell')).toBe(attached);
  expect(attached?.readyState).toBe(WebSocket.OPEN);
  expect(await surface?.evaluate((element) => element.isConnected)).toBe(true);
  expect(await terminalText(page)).toBe(before);
  await page.locator('.xterm-helper-textarea').focus();
  await page.keyboard.type('still running');
  await expect.poll(() => Buffer.concat(inputs.map((input) => input.bytes)).toString()).toBe('still running');
});

test('closing the selected session clears its pane after the roster confirms removal', async ({ page }) => {
  confirmCloses = false;
  await openShell(page);
  await (await sessionActions(page, 'Local shell')).getByRole('menuitem', { name: 'Close', exact: true }).click();
  await page.locator('#confirm-close-session').click();
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'stop').length).toBe(1);
  await expect(page.locator('#confirm-close-session')).toBeDisabled();
  await page.keyboard.press('Escape');
  await expect(page.locator('#close-session-dialog')).toBeVisible();
  await expect(page.locator('#terminal-viewport')).toBeVisible();
  const request = controls.find((entry) => entry.message.t === 'stop')!;
  roster(request.socket, [{ ...projects[0], sessions: [projects[0].sessions[1]] }, projects[1]]);
  await expect(page.locator('#close-session-dialog')).not.toBeVisible();
  await expect(page.getByRole('heading', { name: 'Select a session' })).toBeVisible();
  expect(controls.filter((entry) => entry.message.t === 'stop')).toHaveLength(1);
});

test('close errors, timeouts and disconnects keep the session and never replay the close', async ({ page }) => {
  closeError = 'The remote machine refused the close.';
  await page.clock.install();
  await openShell(page);
  const attached = sessionSockets.get('shell');
  await (await sessionActions(page, 'Deployment logs')).getByRole('menuitem', { name: 'Close', exact: true }).click();
  await page.locator('#confirm-close-session').click();
  await expect(page.locator('#close-session-error')).toHaveText(closeError);
  await expect(page.locator('#confirm-close-session')).toBeEnabled();
  closeError = ''; confirmCloses = false;
  await page.locator('#confirm-close-session').click();
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'stop').length).toBe(2);
  await page.clock.fastForward(15001);
  await expect(page.locator('#close-session-error')).toContainText('didn’t confirm the close');
  await expect(page.locator('#confirm-close-session')).toBeEnabled();
  await page.locator('#confirm-close-session').click();
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'stop').length).toBe(3);
  const request = controls.filter((entry) => entry.message.t === 'stop').at(-1)!;
  request.socket.terminate();
  await expect(page.locator('#close-session-error')).toContainText('Connection lost');
  await page.clock.fastForward(1001);
  await expect(page.locator('#confirm-close-session')).toBeEnabled();
  expect(controls.filter((entry) => entry.message.t === 'stop')).toHaveLength(3);
  expect(sessionSockets.get('shell')).toBe(attached);
  await expect(page.getByRole('group', { name: 'Deployment logs', exact: true })).toBeVisible();
});

test('sync refreshes changed and empty rosters while leaving the active terminal intact', async ({ page }) => {
  await openShell(page);
  const attached = sessionSockets.get('shell');
  const surface = await page.locator('.xterm').elementHandle();
  const before = await terminalText(page);
  const endpoint = socketEndpoints.get(attached!) ?? '';
  sessionNames.set(endpoint, new Map([['shell', 'Renamed elsewhere']]));
  endpointProjects.set(endpoint, [{ ...projects[0], sessions: [projects[0].sessions[0], { id: 'new-shell', title: 'Created elsewhere', agent: 'terminal', status: 'idle' }] }]);
  const beforeAttach = controls.filter((entry) => entry.message.t === 'attach').length;
  await page.getByRole('button', { name: 'Sync Studio Mac', exact: true }).click();
  await expect(page.getByRole('group', { name: 'Renamed elsewhere', exact: true })).toBeVisible();
  await expect(page.getByRole('group', { name: 'Created elsewhere', exact: true })).toBeVisible();
  await expect(page.getByRole('group', { name: 'Deployment logs', exact: true })).not.toBeVisible();
  await expect(page.getByRole('button', { name: 'Sync Studio Mac', exact: true })).toBeEnabled();
  endpointProjects.set(endpoint, []);
  await page.getByRole('button', { name: 'Sync Studio Mac', exact: true }).click();
  await expect(page.locator('.session-item')).toHaveCount(0);
  await expect(page.locator('#terminal-viewport')).toBeVisible();
  expect(await surface?.evaluate((element) => element.isConnected)).toBe(true);
  expect(await terminalText(page)).toBe(before);
  expect(sessionSockets.get('shell')).toBe(attached);
  expect(controls.filter((entry) => entry.message.t === 'attach')).toHaveLength(beforeAttach);
  await page.locator('.xterm-helper-textarea').focus();
  await page.keyboard.type('unchanged');
  await expect.poll(() => Buffer.concat(inputs.map((input) => input.bytes)).toString()).toBe('unchanged');
});

test('sync and close target only the chosen machine when session IDs overlap', async ({ page }) => {
  await openShell(page);
  macID = 'laptop'; macName = 'Laptop';
  await pair(page, address.replace('/?', '/second?'));
  const laptop = page.locator('.paired-machine').filter({ has: page.getByRole('heading', { name: 'Laptop' }) });
  const studio = page.locator('.paired-machine').filter({ has: page.getByRole('heading', { name: 'Studio Mac' }) });
  sessionNames.set('/second', new Map([['shell', 'Laptop work']]));
  await page.getByRole('button', { name: 'Sync Laptop', exact: true }).click();
  await expect(laptop.getByRole('group', { name: 'Laptop work', exact: true })).toBeVisible();
  await expect(studio.getByRole('group', { name: 'Local shell', exact: true })).toBeVisible();
  await (await sessionActions(page, 'Laptop work', laptop)).getByRole('menuitem', { name: 'Close', exact: true }).click();
  await page.locator('#confirm-close-session').click();
  await expect(laptop.getByRole('group', { name: 'Laptop work', exact: true })).not.toBeVisible();
  await expect(studio.getByRole('group', { name: 'Local shell', exact: true })).toBeVisible();
  expect(socketEndpoints.get(controls.find((entry) => entry.message.t === 'stop')!.socket)).toBe('/second');
  await expect(page.locator('#session-title')).toHaveText('Local shell');
  expect(sessionSockets.get('shell')?.readyState).toBe(WebSocket.OPEN);
});

test('a failed sync can be retried without disconnecting the terminal', async ({ page }) => {
  await openShell(page);
  const attached = sessionSockets.get('shell');
  refuse = true;
  await page.getByRole('button', { name: 'Sync Studio Mac', exact: true }).click();
  await expect(page.getByRole('alert')).toContainText('pairing token was refused');
  await expect(page.getByRole('button', { name: 'Sync Studio Mac', exact: true })).toBeEnabled();
  await expect(page.locator('#session-status')).toHaveText('Connected');
  expect(attached?.readyState).toBe(WebSocket.OPEN);
  refuse = false;
  endpointProjects.set(socketEndpoints.get(attached!) ?? '', []);
  await page.getByRole('button', { name: 'Sync Studio Mac', exact: true }).click();
  await expect(page.locator('.session-item')).toHaveCount(0);
  await expect(page.getByRole('alert')).not.toBeVisible();
  expect(sessionSockets.get('shell')).toBe(attached);
});

test.describe('session controls on touch', () => {
  test.use({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } });
  test('session actions work on a narrow touch screen', async ({ page }, testInfo) => {
    await page.goto('./index.html');
    await pair(page);
    const row = page.getByRole('group', { name: 'Deployment logs', exact: true });
    await row.getByRole('button', { name: 'Session Actions' }).tap();
    const menu = page.getByRole('menu', { name: 'Session Actions' });
    const bounds = await menu.boundingBox();
    expect(bounds && bounds.x >= 0 && bounds.x + bounds.width <= 390 && bounds.y + bounds.height <= 844).toBe(true);
    await page.screenshot({ path: testInfo.outputPath('session-actions-touch.png') });
    await menu.getByRole('menuitem', { name: 'Rename', exact: true }).tap();
    await expect(page.getByLabel('Session name', { exact: true })).toHaveValue('Deployment logs');
    await page.locator('#cancel-session-name').tap();
    await row.getByRole('button', { name: 'Session Actions' }).tap();
    await menu.getByRole('menuitem', { name: 'Close', exact: true }).tap();
    await expect(page.locator('#close-session-dialog')).toBeVisible();
    await page.locator('#cancel-close-session').tap();
    expect(controls.some((entry) => entry.message.t === 'stop')).toBe(false);
    await page.getByRole('button', { name: 'Sync Studio Mac', exact: true }).tap();
    await expect(page.getByRole('button', { name: 'Sync Studio Mac', exact: true })).toBeEnabled();
  });
});

test('renames an existing remote session without replacing its terminal and receives later name updates', async ({ page }) => {
  await openShell(page);
  await page.getByRole('button', { name: /Deployment logs/ }).click();
  await expect.poll(() => terminalText(page)).toContain('remote-shell ready');
  const attached = sessionSockets.get('remote-shell');
  await (await sessionActions(page, 'Deployment logs')).getByRole('menuitem', { name: 'Rename', exact: true }).click();
  await expect(page.getByLabel('Session name', { exact: true })).toHaveValue('Deployment logs');
  await page.getByLabel('Session name', { exact: true }).fill('Remote deployment λ');
  await page.getByRole('button', { name: 'Rename', exact: true }).click();
  await expect(page.locator('#session-name-dialog')).not.toBeVisible();
  await expect(page.locator('#session-title')).toHaveText('Remote deployment λ');
  const request = controls.find((entry) => entry.message.t === 'renameSession')!;
  expect(request.message).toMatchObject({ session: 'remote-shell', name: 'Remote deployment λ' });
  expect(request.socket).not.toBe(attached);
  await expect.poll(() => request.socket.readyState).toBe(WebSocket.CLOSED);
  expect(sessionSockets.get('remote-shell')).toBe(attached);
  await page.locator('.xterm-helper-textarea').focus();
  await page.keyboard.type('still running');
  await expect.poll(() => Buffer.concat(inputs.map((input) => input.bytes)).toString()).toBe('still running');
  expect(controls.some((entry) => ['startTerminal', 'stop'].includes(String(entry.message.t)))).toBe(false);
  sessionNames.get(socketEndpoints.get(request.socket) ?? '')?.set('remote-shell', 'Renamed on the machine');
  for (const socket of rosterSockets) roster(socket);
  await expect(page.locator('#session-title')).toHaveText('Renamed on the machine');
  await expect(page.getByRole('button', { name: /Renamed on the machine/ })).toBeVisible();
  expect(sessionSockets.get('remote-shell')).toBe(attached);
});

test('retries a failed new-session rename on the same session and ignores a superseded reply', async ({ page }) => {
  confirmRenames = false;
  await openShell(page);
  await requestTerminal(page, page, 'New work');
  const create = controls.find((entry) => entry.message.t === 'startTerminal')!;
  create.socket.send(JSON.stringify({ t: 'started', session: 'retry-session' }));
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'renameSession').length).toBe(1);
  const first = controls.find((entry) => entry.message.t === 'renameSession')!;
  first.socket.send(JSON.stringify({ ...first.message, t: 'sessionRenamed', error: 'The session’s machine is offline.' }));
  await expect(page.locator('#session-name-error')).toHaveText('The session’s machine is offline.');
  await expect(page.getByLabel('Session name', { exact: true })).toHaveValue('New work');
  await page.getByLabel('Session name', { exact: true }).fill('Retry name');
  await page.getByRole('button', { name: 'Rename', exact: true }).click();
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'renameSession').length).toBe(2);
  const second = controls.filter((entry) => entry.message.t === 'renameSession')[1];
  expect(second.message.session).toBe('retry-session');
  expect(second.message.request).not.toBe(first.message.request);
  first.socket.send(JSON.stringify({ ...first.message, t: 'sessionRenamed' }));
  await expect(page.locator('#session-name-dialog')).toBeVisible();
  second.socket.send(JSON.stringify({ ...second.message, t: 'sessionRenamed' }));
  await expect(page.locator('#session-name-dialog')).not.toBeVisible();
  await expect(page.locator('#session-title')).toHaveText('Retry name');
  expect(controls.filter((entry) => entry.message.t === 'startTerminal')).toHaveLength(1);
});

test('times out a rename and ignores its late confirmation without replaying it', async ({ page }) => {
  confirmRenames = false;
  await page.clock.install();
  await openShell(page);
  const attached = sessionSockets.get('shell');
  await (await sessionActions(page, 'Local shell')).getByRole('menuitem', { name: 'Rename', exact: true }).click();
  await page.getByLabel('Session name', { exact: true }).fill('Timed-out name');
  await page.getByRole('button', { name: 'Rename', exact: true }).click();
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'renameSession').length).toBe(1);
  await page.clock.fastForward(15001);
  await expect(page.locator('#session-name-error')).toContainText('The machine didn’t confirm the name.');
  const request = controls.find((entry) => entry.message.t === 'renameSession')!;
  request.socket.send(JSON.stringify({ ...request.message, t: 'sessionRenamed' }));
  await expect(page.locator('#session-name-dialog')).toBeVisible();
  await expect(page.locator('#session-title')).toHaveText('Local shell');
  expect(sessionSockets.get('shell')).toBe(attached);
  expect(controls.filter((entry) => entry.message.t === 'renameSession')).toHaveLength(1);
});

test('reconnects after a pending rename without replay and keeps the confirmed name across reload', async ({ page }) => {
  confirmRenames = false;
  await page.goto('./index.html');
  await pair(page, address, true);
  await (await sessionActions(page, 'Local shell')).getByRole('menuitem', { name: 'Rename', exact: true }).click();
  await page.getByLabel('Session name', { exact: true }).fill('Persistent name');
  await page.getByRole('button', { name: 'Rename', exact: true }).click();
  await expect.poll(() => controls.filter((entry) => entry.message.t === 'renameSession').length).toBe(1);
  controls.find((entry) => entry.message.t === 'renameSession')!.socket.terminate();
  await expect(page.locator('#session-name-error')).toContainText('Connection lost');
  await expect(page.getByRole('button', { name: 'Rename', exact: true })).toBeEnabled();
  expect(controls.filter((entry) => entry.message.t === 'renameSession')).toHaveLength(1);
  confirmRenames = true;
  await page.getByRole('button', { name: 'Rename', exact: true }).click();
  await expect(page.locator('#session-name-dialog')).not.toBeVisible();
  await expect(page.getByRole('button', { name: /Persistent name/ })).toBeVisible();
  await page.reload();
  await expect(page.getByRole('button', { name: /Persistent name/ })).toBeVisible();
  expect(controls.filter((entry) => entry.message.t === 'renameSession')).toHaveLength(2);
});

test('names the session on the chosen Mac without changing an identical session on another Mac', async ({ page }) => {
  await openShell(page);
  macID = 'laptop'; macName = 'Laptop';
  await pair(page, address.replace('/?', '/second?'));
  const laptop = page.locator('.paired-machine').filter({ has: page.getByRole('heading', { name: 'Laptop' }) });
  await (await sessionActions(page, 'Local shell', laptop)).getByRole('menuitem', { name: 'Rename', exact: true }).click();
  await page.getByLabel('Session name', { exact: true }).fill('Laptop work');
  await page.getByRole('button', { name: 'Rename', exact: true }).click();
  await expect(laptop.getByRole('button', { name: /Laptop work/ })).toBeVisible();
  const studio = page.locator('.paired-machine').filter({ has: page.getByRole('heading', { name: 'Studio Mac' }) });
  await expect(studio.getByRole('button', { name: /Local shell/ })).toBeVisible();
  const request = controls.find((entry) => entry.message.t === 'renameSession')!;
  expect(socketEndpoints.get(request.socket)).toBe('/second');
  await expect(page.locator('#session-title')).toHaveText('Local shell');
});

test('keeps older Mac sessions usable and explains that naming needs an update', async ({ page }) => {
  serverWire = 2;
  await openShell(page);
  await page.getByRole('button', { name: 'New Terminal', exact: true }).click();
  await expect(page.getByRole('alert')).toContainText('Update Termio on this Mac');
  await expect(page.locator('#session-name-dialog')).not.toBeVisible();
  await expect(page.locator('#session-status')).toHaveText('Connected');
  expect(controls.some((entry) => ['startTerminal', 'renameSession'].includes(String(entry.message.t)))).toBe(false);
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
