import '@xterm/xterm/css/xterm.css';
import './style.css';
import { Connection, type ConnectionStatus } from './connection';
import { machineSections, pairingAddress, parseRoster, refusal, type PairingAddress, type Roster, type Session } from './protocol';
import { TerminalSession } from './terminal';
import { TouchKeyboard } from './touch-keyboard';

function element<T extends HTMLElement>(id: string): T {
  const found = document.getElementById(id);
  if (!found) throw new Error(`Missing element: ${id}`);
  return found as T;
}
function node<K extends keyof HTMLElementTagNameMap>(tag: K, className: string, text = ''): HTMLElementTagNameMap[K] {
  const item = document.createElement(tag);
  item.className = className;
  item.textContent = text;
  return item;
}
function button(label: string, className: string, action: () => void): HTMLButtonElement {
  const item = node('button', className, label);
  item.type = 'button';
  item.addEventListener('click', action);
  return item;
}

interface Machine {
  id: string; address: PairingAddress; remember: boolean; name: string; roster?: Roster;
  status: ConnectionStatus; error: string; link: Connection; collapsed: Set<string>;
}
const storageKey = 'termio.web.machines.v1';
const machines = new Map<string, Machine>();
let selected: { machineID: string; sessionID: string; alias: string } | undefined;
let terminal: TerminalSession | undefined;
let forgetID: string | undefined;
const pairDialog = element<HTMLDialogElement>('pair-dialog');
const pairInput = element<HTMLInputElement>('pair-address');
const rememberInput = element<HTMLInputElement>('remember-machine');
const forgetDialog = element<HTMLDialogElement>('forget-dialog');
const terminalViewport = element('terminal-viewport');
const sessionReconnect = element<HTMLButtonElement>('reconnect-session');
const screenReader = element<HTMLInputElement>('screen-reader');
const app = element('app');
const sidebar = element('sidebar');
const sidebarToggle = element<HTMLButtonElement>('toggle-sidebar');
const terminalPane = document.querySelector<HTMLElement>('.terminal-pane');
let sidebarAnimation: Animation | undefined;
const touchKeyboard = new TouchKeyboard(app, element('terminal-surface'), element('touch-keys'),
  element<HTMLButtonElement>('toggle-keyboard'), () => terminal, () => {
    if (matchMedia('(max-width: 760px)').matches && !app.classList.contains('sidebar-collapsed')) sidebarToggle.click();
  });

sidebarToggle.addEventListener('click', (event) => {
  const previousLeft = terminalPane?.getBoundingClientRect().left ?? 0;
  sidebarAnimation?.cancel();
  const animated = event.detail !== 0 && !matchMedia('(prefers-reduced-motion: reduce)').matches;
  app.dataset.instantSidebar = String(!animated);
  const collapsed = app.classList.toggle('sidebar-collapsed');
  sidebar.inert = collapsed;
  sidebar.setAttribute('aria-hidden', String(collapsed));
  sidebarToggle.setAttribute('aria-expanded', String(!collapsed));
  const label = collapsed ? 'Expand Sidebar' : 'Collapse Sidebar';
  sidebarToggle.setAttribute('aria-label', label);
  sidebarToggle.title = label;
  // Resize the terminal once, then move the pane with the drawer without resizing every frame.
  if (animated && terminalPane) {
    const offset = previousLeft - terminalPane.getBoundingClientRect().left;
    sidebarAnimation = terminalPane.animate([
      { transform: `translateX(${offset}px)` }, { transform: 'translateX(0)' },
    ], { duration: 180, easing: 'cubic-bezier(0.23, 1, 0.32, 1)' });
  }
});

function showPairError(message: string): void {
  element('pair-error').textContent = message;
  element('pair-error').hidden = !message;
}
function showPairing(): void {
  pairInput.value = '';
  rememberInput.checked = false;
  showPairError('');
  pairDialog.showModal();
  pairInput.focus();
}
function save(): void {
  try {
    localStorage.setItem(storageKey, JSON.stringify([...machines.values()].filter((machine) => machine.remember)
      .map((machine) => ({ url: machine.address.url, name: machine.name }))));
  } catch {
    element('connection-notice').textContent = 'This browser couldn’t save connections. They will stay connected for this visit.';
    element('connection-notice').hidden = false;
  }
}

function addMachine(address: PairingAddress, remember: boolean, name = address.host): void {
  const previous = [...machines.values()].find((machine) => machine.address.endpoint === address.endpoint);
  if (previous) {
    if (selected?.machineID === previous.id) detach();
    previous.link.close();
    machines.delete(previous.id);
  }
  const machine = {
    id: crypto.randomUUID(), address, remember, name, status: 'Connecting…', error: '', collapsed: new Set<string>(),
  } as Machine;
  machine.link = new Connection(address, {
    status: (status, error = '') => {
      machine.status = status;
      machine.error = error;
      renderMachines();
    },
    message: (message) => {
      if (message instanceof Uint8Array) return;
      if (message.t === 'roster') {
        machine.roster = parseRoster(message);
        machine.name = machine.roster.macName || machine.name;
        // A new tunnel URL may identify a Mac already in the list.
        for (const other of machines.values()) {
          if (other.id !== machine.id && machine.roster.macID && other.roster?.macID === machine.roster.macID) {
            if (selected?.machineID === other.id) detach();
            other.link.close();
            machines.delete(other.id);
          }
        }
        if (selected?.machineID === machine.id) {
          const session = machine.roster.projects.flatMap((project) => project.sessions).find((session) => session.id === selected?.sessionID);
          if (session) element('session-title').textContent = session.title;
          else detach();
        }
        save();
        renderMachines();
      } else if (message.t === 'error') {
        machine.error = refusal(message);
        renderMachines();
      }
    },
  });
  machines.set(machine.id, machine);
  machine.link.connect();
  save();
  renderMachines();
}

function renderMachines(): void {
  const container = element('machines');
  const focused = document.activeElement instanceof HTMLElement ? document.activeElement.dataset.focusKey : undefined;
  container.replaceChildren();
  if (!machines.size) {
    const empty = node('div', 'empty-machines');
    empty.append(node('p', '', 'Connect your Mac to see its machines and sessions.'), button('Add Machine', 'text-button', showPairing));
    container.append(empty);
  }
  for (const machine of machines.values()) {
    const section = node('section', 'paired-machine');
    const heading = node('div', 'paired-heading');
    const name = node('h2', '', machine.name);
    name.title = machine.name;
    const forget = button('×', 'icon-button forget-machine', () => {
      forgetID = machine.id;
      forgetDialog.returnValue = 'cancel';
      element('forget-description').textContent = `Remove ${machine.name} and its saved connection from this browser?`;
      forgetDialog.showModal();
    });
    forget.setAttribute('aria-label', `Forget ${machine.name}`);
    forget.dataset.focusKey = `forget-${machine.id}`;
    heading.append(node('span', `connection-dot ${machine.status === 'Connected' ? 'online' : ''}`), name, forget);
    section.append(heading);
    const state = node('div', 'machine-state');
    state.append(node('span', '', machine.status));
    const reconnect = button(machine.status === 'Connected' ? 'Disconnect' : 'Reconnect', 'text-button', () => {
      if (machine.status === 'Connected') {
        machine.link.close();
        machine.status = 'Disconnected';
        machine.error = '';
        if (selected?.machineID === machine.id) detach();
        renderMachines();
      } else machine.link.connect();
    });
    reconnect.dataset.focusKey = `connection-${machine.id}`;
    state.append(reconnect);
    section.append(state);
    if (machine.error) section.append(node('p', 'machine-error', machine.error));
    if (machine.roster) {
      const groups = machineSections(machine.roster.projects);
      if (!groups.length) section.append(node('p', 'empty-machines', 'Open a session in Termio on your Mac.'));
      for (const group of groups) {
        const groupName = group.alias || 'This machine';
        const collapsed = machine.collapsed.has(group.alias);
        const groupHeading = button('', 'group-heading', () => {
          if (collapsed) machine.collapsed.delete(group.alias); else machine.collapsed.add(group.alias);
          renderMachines();
        });
        groupHeading.setAttribute('aria-expanded', String(!collapsed));
        groupHeading.dataset.focusKey = `group-${machine.id}-${group.alias}`;
        groupHeading.append(node('span', 'chevron', collapsed ? '›' : '⌄'), node('span', 'group-name', groupName), node('span', 'count', String(group.sessions.length)));
        section.append(groupHeading);
        if (collapsed) continue;
        if (!group.sessions.length) section.append(node('p', 'empty-group', 'Open a session on this machine.'));
        for (const session of group.sessions) {
          const active = selected?.machineID === machine.id && selected.sessionID === session.id;
          const row = button('', `session-row${active ? ' selected' : ''}`, () => openSession(machine, session, group.alias));
          row.dataset.focusKey = `session-${machine.id}-${session.id}`;
          row.setAttribute('aria-pressed', String(active));
          row.disabled = machine.status !== 'Connected';
          const status = session.status === 'needsAttention' ? 'Needs you' : session.status === 'working' ? 'Working' : session.status === 'done' ? 'Done' : 'Idle';
          const statusDot = node('span', `session-dot status-${['working', 'done', 'needsAttention'].includes(session.status) ? session.status : 'idle'}`);
          statusDot.title = status;
          const label = node('span', 'session-label');
          label.append(node('span', 'session-name', session.title), node('span', 'session-detail', session.subtitle || `${session.agent || 'terminal'} · ${status}`));
          row.append(statusDot, label);
          section.append(row);
        }
      }
    }
    container.append(section);
  }
  if (focused) [...container.querySelectorAll<HTMLElement>('[data-focus-key]')].find((item) => item.dataset.focusKey === focused)?.focus();
  element('connect-empty').hidden = machines.size > 0;
  const emptyTitle = element('empty-terminal').querySelector('h2');
  const emptyDescription = element('empty-terminal').querySelector('p');
  if (emptyTitle) emptyTitle.textContent = machines.size ? 'Select a session' : 'Your sessions, here.';
  if (emptyDescription) emptyDescription.textContent = machines.size ? 'Choose a session from the machines on the left.' : 'Connect a machine, then select a session.';
}

function setSessionStatus(status: string, error = ''): void {
  element('session-status').textContent = status;
  element('session-status').classList.toggle('online-text', status === 'Connected');
  element('terminal-error').textContent = error;
  element('terminal-error').hidden = !error;
  sessionReconnect.hidden = status === 'Connected' || !selected;
  touchKeyboard.refresh();
}

function openSession(machine: Machine, session: Session, alias: string): void {
  if (selected?.machineID === machine.id && selected.sessionID === session.id) { terminal?.focus(); return; }
  terminal?.dispose();
  selected = { machineID: machine.id, sessionID: session.id, alias };
  element('session-title').textContent = session.title;
  element('session-context').textContent = `${machine.name} / ${alias || 'This machine'}`;
  element('empty-terminal').hidden = true;
  terminalViewport.hidden = false;
  element('detach-session').hidden = false;
  element('terminal-caption').textContent = 'Type in the terminal to control this session';
  terminal = new TerminalSession(machine.address, session.id, element('terminal-surface'), setSessionStatus,
    (size) => { element('terminal-size').textContent = size; }, screenReader.checked, () => touchKeyboard.refresh());
  renderMachines();
  terminal.focus();
}

function detach(): void {
  terminal?.dispose();
  terminal = undefined;
  selected = undefined;
  element('session-title').textContent = 'Terminal';
  element('session-context').textContent = '';
  element('terminal-size').textContent = '';
  element('terminal-caption').textContent = 'Connected directly to your Mac';
  element('empty-terminal').hidden = false;
  terminalViewport.hidden = true;
  element('detach-session').hidden = true;
  setSessionStatus('');
  renderMachines();
}

element('add-machine').addEventListener('click', showPairing);
element('connect-empty').addEventListener('click', showPairing);
element('cancel-pair').addEventListener('click', () => pairDialog.close());
pairDialog.addEventListener('close', () => { pairInput.value = ''; });
element('pair-form').addEventListener('submit', (event) => {
  event.preventDefault();
  try {
    const address = pairingAddress(pairInput.value);
    addMachine(address, rememberInput.checked);
    pairDialog.close();
  } catch (error) { showPairError(error instanceof Error ? error.message : 'Couldn’t connect to this address.'); }
});
forgetDialog.addEventListener('close', () => {
  if (forgetDialog.returnValue === 'forget' && forgetID) {
    const machine = machines.get(forgetID);
    machine?.link.close();
    if (selected?.machineID === forgetID) detach();
    machines.delete(forgetID);
    save();
    renderMachines();
  }
  forgetID = undefined;
});
element('detach-session').addEventListener('click', detach);
sessionReconnect.addEventListener('click', () => terminal?.reconnect());
screenReader.addEventListener('change', () => terminal?.setScreenReaderMode(screenReader.checked));
window.addEventListener('pagehide', () => { terminal?.dispose(); machines.forEach((machine) => machine.link.close()); });
window.addEventListener('pageshow', (event) => { if (event.persisted) location.reload(); });

try {
  const saved: unknown = JSON.parse(localStorage.getItem(storageKey) ?? '[]');
  if (!Array.isArray(saved)) throw new Error('Invalid saved connections');
  saved.forEach((machine: unknown) => {
    if (!machine || typeof machine !== 'object' || !('url' in machine) || typeof machine.url !== 'string') throw new Error('Invalid saved connection');
    addMachine(pairingAddress(machine.url), true, 'name' in machine && typeof machine.name === 'string' ? machine.name : undefined);
  });
} catch {
  showPairing();
  showPairError('Couldn’t restore saved connections. Copy an address from Settings → Mobile to connect again.');
}
renderMachines();
