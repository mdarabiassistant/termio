import { mkdir, rm, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { build } from 'vite';

const root = fileURLToPath(new URL('..', import.meta.url));
const result = await build({
  root,
  configFile: false,
  // A public build must not pick up local environment files or copied assets.
  envDir: false,
  envPrefix: [],
  publicDir: false,
  build: {
    write: false,
    sourcemap: false,
    modulePreload: false,
    cssCodeSplit: false,
    rollupOptions: { output: { format: 'iife', inlineDynamicImports: true } },
  },
});

if (!('output' in result)) throw new Error('Expected a single application bundle.');
const html = result.output.find((item) => item.fileName === 'index.html');
const scripts = result.output.filter((item) => item.type === 'chunk');
const styles = result.output.filter((item) => item.type === 'asset' && item.fileName.endsWith('.css'));
if (html?.type !== 'asset' || scripts.length !== 1 || styles.length !== 1 || result.output.length !== 3) {
  throw new Error('The standalone app must contain only HTML, one script, and one stylesheet.');
}
const script = scripts[0];
if (script.imports.length || script.dynamicImports.length) throw new Error('Standalone scripts cannot load other files.');

let document = String(html.source);
const scriptTag = /<script\b[^>]*\bsrc="[^"]+"[^>]*><\/script>/g;
const styleTag = /<link\b[^>]*\brel="stylesheet"[^>]*>/g;
if ([...document.matchAll(scriptTag)].length !== 1 || [...document.matchAll(styleTag)].length !== 1) {
  throw new Error('Couldn’t identify the application assets in the generated HTML.');
}
document = document.replace(scriptTag, '').replace(styleTag, () => `<style>${String(styles[0].source).replace(/<\/style/gi, '<\\/style')}</style>`);
// Classic inline scripts run immediately, so place the bundle after the app's elements.
document = document.replace('</body>', () => `<script>${script.code.replace(/<\/script/gi, '<\\/script')}</script>\n  </body>`);
const destination = new URL('../dist/', import.meta.url);
await rm(destination, { recursive: true, force: true });
await mkdir(destination, { recursive: true });
await writeFile(new URL('index.html', destination), document);
console.log(`Built dist/index.html (${Math.ceil(Buffer.byteLength(document) / 1024)} KB). Open it directly in a browser.`);
