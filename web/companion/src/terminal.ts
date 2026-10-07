import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { Connection } from './connection';
import { refusal, validGrid, type Control, type PairingAddress } from './protocol';

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
  private viewport = { cols: 80, rows: 24 };
  private lastViewport = '';
  private resizeFrame = 0;
  private visibilityChanged = () => this.reportViewport();

  constructor(address: PairingAddress, private sessionID: string, private container: HTMLElement,
    private status: (status: string, error?: string) => void,
    private dimensions: (text: string) => void, private screenReaderMode: boolean) {
    this.link = new Connection(address, {
      status: (status, error) => {
        this.connected = false;
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
    this.terminal.onData((data) => { if (this.connected) this.link.send(new TextEncoder().encode(data)); });
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
        this.terminal.options.disableStdin = true;
        this.status(message.t === 'exit' ? `Ended (${Number(message.code) || 0})` : 'Disconnected',
          message.t === 'error' ? refusal(message) : undefined);
        this.queue = [];
        return;
      }
    }
  }

  focus(): void { this.terminal.focus(); }
  reconnect(): void { this.link.connect(); this.focus(); }
  setScreenReaderMode(enabled: boolean): void {
    this.screenReaderMode = enabled;
    this.terminal.options.screenReaderMode = enabled;
  }

  dispose(): void {
    this.reportViewport(false);
    this.disposed = true;
    this.link.close();
    this.observer.disconnect();
    cancelAnimationFrame(this.resizeFrame);
    document.removeEventListener('visibilitychange', this.visibilityChanged);
    this.terminal.dispose();
    this.container.replaceChildren();
  }
}
