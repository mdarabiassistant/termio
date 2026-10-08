import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { Connection } from './connection';
import { refusal, validGrid, type Control, type PairingAddress } from './protocol';

export type TerminalKey = 'Escape' | 'Tab' | 'Control' | 'Alt' | 'ArrowLeft' | 'ArrowDown' | 'ArrowUp' | 'ArrowRight' | 'Home' | 'End' | 'PageUp' | 'PageDown';

export class TerminalSession {
  private terminal!: Terminal;
  private fit!: FitAddon;
  private link: Connection;
  private observer: ResizeObserver;
  private queue: (Control | Uint8Array)[] = [];
  private queuedBytes = 0;
  private processing = false;
  private generation = 0;
  private disposed = false;
  private sharedGrid = false;
  private connected = false;
  private control = false;
  private alt = false;
  private viewport = { cols: 80, rows: 24 };
  private lastViewport = '';
  private resizeFrame = 0;
  private visibilityChanged = () => this.reportViewport();

  constructor(address: PairingAddress, private sessionID: string, private container: HTMLElement,
    private status: (status: string, error?: string) => void,
    private dimensions: (text: string) => void, private screenReaderMode: boolean,
    private inputChanged: () => void = () => {}) {
    this.link = new Connection(address, {
      status: (status, error) => {
        this.connected = false;
        this.clearModifiers();
        this.generation++;
        this.queue = [];
        this.queuedBytes = 0;
        this.processing = false;
        if (status === 'Connecting…' || status === 'Reconnecting…') {
          if (!error) this.reset();
        }
        this.terminal.options.disableStdin = true;
        this.status(status === 'Connected' ? 'Opening session…' : status, error);
      },
      ready: () => {
        this.link.send({ t: 'attach', session: this.sessionID });
        this.lastViewport = '';
        this.reportViewport();
      },
      message: (message) => this.enqueue(message),
    });
    this.reset();
    this.observer = new ResizeObserver(() => {
      cancelAnimationFrame(this.resizeFrame);
      this.resizeFrame = requestAnimationFrame(() => this.measure());
    });
    this.observer.observe(container);
    document.addEventListener('visibilitychange', this.visibilityChanged);
    this.link.connect();
  }

  private reset(): void {
    this.generation++;
    this.queue = [];
    this.queuedBytes = 0;
    this.processing = false;
    this.sharedGrid = false;
    this.terminal?.dispose();
    this.container.replaceChildren();
    this.terminal = new Terminal({
      cursorBlink: true, fontFamily: '"SFMono-Regular", Consolas, "Liberation Mono", monospace',
      fontSize: 13, lineHeight: 1.2, scrollback: 5000, disableStdin: true,
      screenReaderMode: this.screenReaderMode,
      theme: { background: '#151719', foreground: '#dce1df', cursor: '#a7d8be', selectionBackground: '#3d5549' },
    });
    this.fit = new FitAddon();
    this.terminal.loadAddon(this.fit);
    this.terminal.open(this.container);
    this.terminal.onData((data) => {
      if (!this.canInput) return;
      // Soft keyboards emit text input, so a one-shot modifier must also handle onData.
      if ([...data].length === 1) {
        const code = data.charCodeAt(0);
        if (this.control) {
          if (data === ' ') data = '\x00';
          else if (data === '?') data = '\x7f';
          else if (code >= 64 && code <= 95) data = String.fromCharCode(code - 64);
          else if (code >= 97 && code <= 122) data = String.fromCharCode(code - 96);
        }
        if (this.alt) data = `\x1b${data}`;
      }
      this.clearModifiers();
      this.link.send(new TextEncoder().encode(data));
    });
    this.terminal.onBinary((data) => {
      if (this.connected) this.link.send(Uint8Array.from(data, (character) => character.charCodeAt(0)));
    });
    this.measure();
  }

  private measure(): void {
    if (this.disposed || !this.container.clientWidth || !this.container.clientHeight) return;
    const dimensions = this.fit.proposeDimensions();
    if (!dimensions || !validGrid(dimensions.cols, dimensions.rows)) return;
    this.viewport = dimensions;
    // The viewport is our available space; the shared grid describes how incoming bytes wrap.
    if (!this.sharedGrid) this.terminal.resize(dimensions.cols, dimensions.rows);
    this.reportViewport();
  }

  private reportViewport(rendering = document.visibilityState === 'visible'): void {
    const message = {
      t: 'resize', ...this.viewport, rendering,
      surfaceCols: this.terminal.cols, surfaceRows: this.terminal.rows,
    };
    const signature = JSON.stringify(message);
    if (signature !== this.lastViewport && this.link.send(message)) this.lastViewport = signature;
    this.dimensions(`${this.terminal.cols} × ${this.terminal.rows}`);
  }

  private enqueue(message: Control | Uint8Array): void {
    if (this.disposed) return;
    if (message instanceof Uint8Array) this.queuedBytes += message.byteLength;
    if (this.queuedBytes > 8 * 1024 * 1024) {
      this.queue = [];
      this.queuedBytes = 0;
      this.link.fail('Terminal output arrived too quickly. Reconnect to refresh the screen.');
      return;
    }
    this.queue.push(message);
    this.drain();
  }

  private drain(): void {
    if (this.processing || this.disposed) return;
    let message: Control | Uint8Array | undefined;
    while ((message = this.queue.shift()) !== undefined) {
      if (message instanceof Uint8Array) {
        this.connected = true;
        this.terminal.options.disableStdin = false;
        this.status('Connected');
        this.processing = true;
        const generation = this.generation;
        const size = message.byteLength;
        this.terminal.write(message, () => {
          if (this.disposed || generation !== this.generation) return;
          this.queuedBytes -= size;
          this.processing = false;
          this.drain();
        });
        return;
      }
      if (message.t === 'grid') {
        if (!validGrid(message.cols, message.rows)) {
          this.link.fail('The Mac sent an invalid terminal size. Reconnect to this session.');
          this.queue = [];
          return;
        }
        this.sharedGrid = true;
        this.terminal.resize(message.cols, Number(message.rows));
        this.connected = true;
        this.terminal.options.disableStdin = false;
        this.status('Connected');
        this.reportViewport();
      } else if (message.t === 'exit' || message.t === 'error') {
        this.link.close();
        this.connected = false;
        this.clearModifiers();
        this.terminal.options.disableStdin = true;
        this.status(message.t === 'exit' ? `Ended (${Number(message.code) || 0})` : 'Disconnected',
          message.t === 'error' ? refusal(message) : undefined);
        this.queue = [];
        return;
      }
    }
  }

  get canInput(): boolean { return this.connected && !this.disposed; }
  get controlPressed(): boolean { return this.control; }
  get altPressed(): boolean { return this.alt; }

  clearModifiers(): void {
    if (!this.control && !this.alt) return;
    this.control = false;
    this.alt = false;
    this.inputChanged();
  }

  pressKey(key: TerminalKey): void {
    if (!this.canInput) return;
    if (key === 'Control' || key === 'Alt') {
      if (key === 'Control') this.control = !this.control;
      else this.alt = !this.alt;
      this.inputChanged();
      return;
    }
    const modifier = 1 + (this.alt ? 2 : 0) + (this.control ? 4 : 0);
    let data: string;
    if (key === 'Escape' || key === 'Tab') {
      data = (this.alt ? '\x1b' : '') + (key === 'Escape' ? '\x1b' : '\t');
    } else if (key === 'PageUp' || key === 'PageDown') {
      data = `\x1b[${key === 'PageUp' ? 5 : 6}${modifier > 1 ? `;${modifier}` : ''}~`;
    } else {
      const suffix = { ArrowLeft: 'D', ArrowDown: 'B', ArrowUp: 'A', ArrowRight: 'C', Home: 'H', End: 'F' }[key];
      const prefix = modifier > 1 ? `[1;${modifier}` : this.terminal.modes.applicationCursorKeysMode ? 'O' : '[';
      data = `\x1b${prefix}${suffix}`;
    }
    this.clearModifiers();
    this.terminal.input(data, true);
  }

  focus(): void { this.terminal.focus(); }
  blur(): void { this.terminal.blur(); this.clearModifiers(); }
  reconnect(): void { this.link.connect(); this.focus(); }
  setScreenReaderMode(enabled: boolean): void {
    this.screenReaderMode = enabled;
    this.terminal.options.screenReaderMode = enabled;
  }

  dispose(): void {
    this.reportViewport(false);
    this.disposed = true;
    this.clearModifiers();
    this.link.close();
    this.observer.disconnect();
    cancelAnimationFrame(this.resizeFrame);
    document.removeEventListener('visibilitychange', this.visibilityChanged);
    this.terminal.dispose();
    this.container.replaceChildren();
  }
}
