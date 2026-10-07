import { defineConfig } from '@playwright/test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const root = fileURLToPath(new URL('.', import.meta.url));

export default defineConfig({
  testDir: './tests',
  fullyParallel: false,
  workers: 1,
  use: {
    baseURL: pathToFileURL(resolve(root, 'dist/index.html')).href,
    viewport: { width: 1200, height: 800 },
  },
});
