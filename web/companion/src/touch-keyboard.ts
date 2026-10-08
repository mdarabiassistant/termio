import type { TerminalKey, TerminalSession } from './terminal';

const keys: [TerminalKey, string, string][] = [
  ['Escape', 'Esc', 'Escape'], ['Tab', 'Tab', 'Tab'],
  ['Control', 'Ctrl', 'Control'], ['Alt', 'Alt', 'Alt'],
  ['Home', 'Home', 'Home'], ['End', 'End', 'End'],
  ['ArrowLeft', '←', 'Arrow Left'], ['ArrowDown', '↓', 'Arrow Down'],
  ['ArrowUp', '↑', 'Arrow Up'], ['ArrowRight', '→', 'Arrow Right'],
  ['PageUp', 'PgUp', 'Page Up'], ['PageDown', 'PgDn', 'Page Down'],
];

export class TouchKeyboard {
  private touchPointer = matchMedia('(any-pointer: coarse)');
  private frame = 0;
  private pointerActive = false;

  constructor(private app: HTMLElement, private surface: HTMLElement, private bar: HTMLElement,
    private toggle: HTMLButtonElement, private session: () => TerminalSession | undefined,
    private revealTerminal: () => void) {
    for (const [key, label, name] of keys) {
      const button = document.createElement('button');
      button.type = 'button';
      button.textContent = label;
      button.dataset.key = key;
      button.setAttribute('aria-label', name);
      if (key === 'Control' || key === 'Alt') {
        button.setAttribute('aria-pressed', 'false');
        button.title = `${name} for the next key`;
      }
      // Keep the xterm textarea focused so tapping a key does not dismiss the OS keyboard.
      this.bindPress(button, () => {
        const terminal = this.session();
        terminal?.focus();
        terminal?.pressKey(key);
      });
      bar.append(button);
    }
    this.bindPress(toggle, () => {
      if (this.bar.hidden) this.session()?.focus();
      else this.session()?.blur();
      this.refresh();
    });
    document.addEventListener('pointerdown', (event) => {
      const control = event.target instanceof Element ? event.target.closest('button, a, input, select, textarea') : null;
      this.pointerActive = !this.bar.hidden && !!control && !control.matches(':disabled');
    }, true);
    const releasePointer = () => {
      this.pointerActive = false;
      this.refresh();
    };
    // Wait for click, including Safari's synthesized click, before moving other controls.
    document.addEventListener('click', releasePointer);
    document.addEventListener('pointercancel', releasePointer, true);
    window.addEventListener('blur', releasePointer);
    document.addEventListener('focusin', () => this.refresh());
    document.addEventListener('focusout', () => queueMicrotask(() => this.refresh()));
    document.addEventListener('visibilitychange', () => this.refresh());
    this.touchPointer.addEventListener('change', () => this.refresh());
    const resized = () => {
      cancelAnimationFrame(this.frame);
      this.frame = requestAnimationFrame(() => this.fitViewport());
    };
    window.visualViewport?.addEventListener('resize', resized);
    window.visualViewport?.addEventListener('scroll', resized);
    this.refresh();
  }

  private bindPress(button: HTMLButtonElement, action: () => void): void {
    button.addEventListener('pointerdown', (event) => event.preventDefault());
    button.addEventListener('pointerup', (event) => {
      const bounds = button.getBoundingClientRect();
      this.pointerActive = false;
      if (event.button !== 0 || event.clientX < bounds.left || event.clientX > bounds.right ||
        event.clientY < bounds.top || event.clientY > bounds.bottom) {
        this.refresh();
        return;
      }
      action();
    });
    // Keyboard and assistive-technology activation has no preceding pointer event.
    button.addEventListener('click', (event) => { if (event.detail === 0) action(); });
  }

  refresh(): void {
    if (this.pointerActive) return;
    const terminal = this.session();
    const touch = navigator.maxTouchPoints > 0 || this.touchPointer.matches;
    this.app.classList.toggle('touch-device', touch);
    const available = touch && !!terminal?.canInput;
    const focused = this.surface.contains(document.activeElement) || this.bar.contains(document.activeElement);
    const visible = available && focused && document.visibilityState === 'visible';
    this.toggle.hidden = !available;
    this.bar.hidden = !visible;
    this.toggle.setAttribute('aria-expanded', String(visible));
    const label = visible ? 'Hide Keyboard' : 'Show Keyboard';
    this.toggle.setAttribute('aria-label', label);
    this.toggle.title = label;
    if (visible) this.revealTerminal();
    else terminal?.clearModifiers();
    for (const button of this.bar.querySelectorAll<HTMLButtonElement>('[aria-pressed]')) {
      button.setAttribute('aria-pressed', String(button.dataset.key === 'Control' ? !!terminal?.controlPressed : !!terminal?.altPressed));
    }
    this.fitViewport();
  }

  private fitViewport(): void {
    const viewport = window.visualViewport;
    const fit = !this.bar.hidden && !!viewport && viewport.scale === 1;
    this.app.classList.toggle('touch-typing', fit);
    if (fit) {
      // Safari and Chrome shrink the visual viewport when the software keyboard opens.
      this.app.style.setProperty('--typing-height', `${viewport.height}px`);
      this.app.style.setProperty('--typing-top', `${viewport.offsetTop}px`);
    } else {
      this.app.style.removeProperty('--typing-height');
      this.app.style.removeProperty('--typing-top');
    }
  }
}
