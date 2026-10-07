import { test, expect, type BrowserContext } from '@playwright/test';
import { readFile, readdir } from 'node:fs/promises';

const artifact = new URL('../dist/index.html', import.meta.url);
const site = 'https://companion.example/';
const machineEndpoint = 'wss://machine.example/';
const syntheticToken = 'synthetic-browser-pairing-token';
const machineName = 'Example workstation';
const storageKey = 'termio.web.machines.v1';

test('public artifact contains no local paths, source maps, or development fixture data', async () => {
  const html = await readFile(artifact, 'utf8');
  expect(await readdir(new URL('../dist/', import.meta.url))).toEqual(['index.html']);
  expect(html).not.toMatch(/(?:\/Users\/|\/home\/|[A-Z]:\\Users\\)/);
  expect(html).not.toMatch(/sourceMappingURL|sourceURL|-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----/);
  expect(html).not.toMatch(/(?:github_pat_[A-Za-z0-9_]{40,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[A-Z0-9]{16})/);
  expect(html).not.toContain('test-pairing-token');
  expect(html).not.toContain(syntheticToken);
  expect(html).not.toContain(machineName);
});

test('HTTPS hosting keeps pairings per browser and sends no visitor data to the host', async ({ browser }) => {
  const html = await readFile(artifact, 'utf8');
  const first = await browser.newContext();
  const second = await browser.newContext();
  const httpRequests: { url: string; method: string; body: string | null }[] = [];
  const socketURLs: string[] = [];
  const authentication: unknown[] = [];
  const browserErrors: string[] = [];

  async function serve(context: BrowserContext): Promise<void> {
    // Mock only the hosting response and the user's Mac; no public service is contacted.
    await context.route('**/*', async (route) => {
      const request = route.request();
      httpRequests.push({ url: request.url(), method: request.method(), body: request.postData() });
      if (request.url() === site) await route.fulfill({ contentType: 'text/html', body: html });
      else await route.abort();
    });
    await context.routeWebSocket('**/*', (socket) => {
      socketURLs.push(socket.url());
      socket.onMessage((raw) => {
        if (typeof raw !== 'string') return;
        const message = JSON.parse(raw);
        if (message.t !== 'auth') return;
        authentication.push(message);
        socket.send(JSON.stringify({
          t: 'roster', wire: 2, macID: 'synthetic-machine-id', macName: machineName,
          projects: [{ id: 'local', deviceAlias: null, sessions: [{ id: 'synthetic-session', title: 'Example shell', agent: 'terminal', status: 'idle' }] }],
        }));
      });
    });
  }

  try {
    await serve(first);
    await serve(second);
    const page = await first.newPage();
    page.on('pageerror', (error) => browserErrors.push(error.message));
    await page.goto(site);
    await expect(page.getByRole('heading', { name: 'Your sessions, here.' })).toBeVisible();
    await page.getByRole('button', { name: 'Connect a Machine', exact: true }).click();
    await page.getByLabel('Mobile WebSocket URI').fill(`ws://machine.example/?t=${syntheticToken}`);
    await page.getByRole('button', { name: 'Connect', exact: true }).click();
    await expect(page.locator('#pair-error')).toContainText('Use a secure wss://');
    expect(socketURLs).toEqual([]);
    await page.getByLabel('Mobile WebSocket URI').fill(`${machineEndpoint}?t=${syntheticToken}`);
    await page.getByLabel('Remember on this browser').check();
    await page.getByRole('button', { name: 'Connect', exact: true }).click();
    await expect(page.getByRole('heading', { name: machineName, exact: true })).toBeVisible();
    expect(await page.evaluate((key) => JSON.parse(localStorage.getItem(key) ?? '[]'), storageKey)).toEqual([
      { url: `${machineEndpoint}?t=${syntheticToken}`, name: machineName },
    ]);
    expect(await page.evaluate(() => location.href)).toBe(site);
    await expect(page.getByLabel('Mobile WebSocket URI')).toHaveValue('');
    await page.reload();
    await expect(page.getByRole('heading', { name: machineName, exact: true })).toBeVisible();

    const visitor = await second.newPage();
    visitor.on('pageerror', (error) => browserErrors.push(error.message));
    await visitor.goto(site);
    await expect(visitor.getByRole('heading', { name: 'Your sessions, here.' })).toBeVisible();
    expect(await visitor.evaluate((key) => localStorage.getItem(key), storageKey)).toBeNull();
    expect(await first.cookies()).toEqual([]);
    expect(await second.cookies()).toEqual([]);
    expect(socketURLs).toEqual([machineEndpoint, machineEndpoint]);
    expect(authentication).toEqual([
      { t: 'auth', token: syntheticToken, wire: 2 },
      { t: 'auth', token: syntheticToken, wire: 2 },
    ]);
    expect(httpRequests).toEqual(Array.from({ length: 3 }, () => ({ url: site, method: 'GET', body: null })));
    expect(browserErrors).toEqual([]);
  } finally {
    await first.close();
    await second.close();
  }
});
