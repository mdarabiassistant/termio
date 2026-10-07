import { parseControl, parseRoster, refusal, wireVersion, type Control, type PairingAddress } from './protocol';

export type ConnectionStatus = 'Connecting…' | 'Connected' | 'Reconnecting…' | 'Disconnected';
interface Callbacks {
  status: (status: ConnectionStatus, error?: string) => void;
  ready?: () => void;
  message: (message: Control | Uint8Array) => void;
}

export class Connection {
  private socket?: WebSocket;
  private retry?: ReturnType<typeof setTimeout>;
  private timeout?: ReturnType<typeof setTimeout>;
  private attempts = 0;
  private stopped = true;
  private authenticated = false;

  constructor(private address: PairingAddress, private callbacks: Callbacks) {}

  connect(): void {
    this.close();
    this.stopped = false;
    this.attempts = 0;
    this.dial();
  }

  private dial(): void {
    if (this.stopped) return;
    this.authenticated = false;
    this.callbacks.status(this.attempts ? 'Reconnecting…' : 'Connecting…');
    let socket: WebSocket;
    try { socket = new WebSocket(this.address.endpoint); } catch {
      this.fail('The browser couldn’t open this address. Check the URI and use wss:// on an HTTPS page.');
      return;
    }
    this.socket = socket;
    socket.binaryType = 'arraybuffer';
    this.timeout = setTimeout(() => {
      if (this.socket === socket) socket.close();
    }, 15000);
    socket.onopen = () => {
      if (this.socket === socket) socket.send(JSON.stringify({ t: 'auth', token: this.address.token, wire: wireVersion }));
    };
    socket.onmessage = (event: MessageEvent<string | ArrayBuffer>) => {
      if (this.socket !== socket) return;
      if (typeof event.data !== 'string') {
        if (this.authenticated) this.callbacks.message(new Uint8Array(event.data));
        return;
      }
      let message: Control;
      try {
        message = parseControl(event.data);
        if (message.t === 'roster') parseRoster(message);
      } catch {
        this.fail('The Mac sent an unsupported response. Update Termio and reconnect.');
        return;
      }
      if (message.t === 'error' && (!this.authenticated || ['unauthorized', 'client_too_old'].includes(String(message.code)))) {
        this.fail(refusal(message));
        return;
      }
      if (message.t === 'roster' && !this.authenticated) {
        clearTimeout(this.timeout);
        this.authenticated = true;
        this.attempts = 0;
        this.callbacks.status('Connected');
        this.callbacks.ready?.();
      }
      this.callbacks.message(message);
    };
    socket.onerror = () => { /* Browsers report connection errors through close without exposing their cause. */ };
    socket.onclose = () => {
      if (this.socket !== socket || this.stopped) return;
      clearTimeout(this.timeout);
      this.socket = undefined;
      this.authenticated = false;
      this.callbacks.status('Reconnecting…', 'Connection lost. Check Mobile Access and the address on your Mac.');
      this.retry = setTimeout(() => this.dial(), Math.min(1000 * 2 ** this.attempts++, 10000));
    };
  }

  send(message: Control | Uint8Array): boolean {
    if (!this.authenticated || this.socket?.readyState !== WebSocket.OPEN) return false;
    if (this.socket.bufferedAmount > 1_048_576) {
      this.fail('The connection couldn’t keep up with input. Reconnect before typing again.');
      return false;
    }
    this.socket.send(message instanceof Uint8Array ? message : JSON.stringify(message));
    return true;
  }

  fail(message: string): void {
    this.close();
    this.callbacks.status('Disconnected', message);
  }

  close(): void {
    this.stopped = true;
    this.authenticated = false;
    clearTimeout(this.timeout);
    clearTimeout(this.retry);
    const socket = this.socket;
    this.socket = undefined;
    socket?.close();
  }
}
