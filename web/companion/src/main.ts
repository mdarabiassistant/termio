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
  pendingTerminal?: ReturnType<typeof setTimeout>;
  pendingTerminalName?: string;
  pendingRename?: { requestID: string; session: Session; alias: string; name: string; open: boolean; timeout: ReturnType<typeof setTimeout> };
  pendingClose?: { sessionID: string; timeout: ReturnType<typeof setTimeout> };
  pendingSync?: ReturnType<typeof setTimeout>;
}
const storageKey = 'termio.web.machines.v1';
const machines = new Map<string, Machine>();
let selected: { machineID: string; sessionID: string; alias: string } | undefined;
let terminal: TerminalSession | undefined;
let forgetID: string | undefined;
let openingTerminalMachineID: string | undefined;
const pairDialog = element<HTMLDialogElement>('pair-dialog');
const pairInput = element<HTMLInputElement>('pair-address');
const rememberInput = element<HTMLInputElement>('remember-machine');
const forgetDialog = element<HTMLDialogElement>('forget-dialog');
const nameDialog = element<HTMLDialogElement>('session-name-dialog');
const nameInput = element<HTMLInputElement>('session-name');
const nameSubmit = element<HTMLButtonElement>('save-session-name');
const nameCancel = element<HTMLButtonElement>('cancel-session-name');
let namePrompt: { machineID: string; sessionID?: string; creating: boolean } | undefined;
const sessionMenu = element<HTMLDivElement>('session-menu');
const closeDialog = element<HTMLDialogElement>('close-session-dialog');
const closeSubmit = element<HTMLButtonElement>('confirm-close-session');
const closeCancel = element<HTMLButtonElement>('cancel-close-session');
let menuPrompt: { machineID: string; sessionID: string; anchor: HTMLButtonElement } | undefined;
let closePrompt: { machineID: string; sessionID: string } | undefined;
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

function clearTerminalStart(machine: Machine): void {
  clearTimeout(machine.pendingTerminal);
  machine.pendingTerminal = undefined;
  machine.pendingTerminalName = undefined;
  if (openingTerminalMachineID === machine.id) openingTerminalMachineID = undefined;
}

function nameBusy(machine: Machine): boolean {
  return machine.pendingTerminal !== undefined || machine.pendingRename !== undefined;
}

function sessionBusy(machine: Machine): boolean {
  return nameBusy(machine) || machine.pendingClose !== undefined || machine.pendingSync !== undefined;
}

function clearSync(machine: Machine): void {
  clearTimeout(machine.pendingSync);
  machine.pendingSync = undefined;
}

function syncMachine(machine: Machine): void {
  if (sessionBusy(machine)) return;
  machine.error = '';
  machine.pendingSync = setTimeout(() => {
    clearSync(machine);
    machine.error = 'Couldn’t sync sessions. Check the connection and try again.';
    renderMachines();
  }, 15000);
  // The roster connection authenticates with a fresh list; the terminal has its own socket.
  machine.link.connect();
}

function hideSessionMenu(): void {
  sessionMenu.hidePopover();
  menuPrompt?.anchor.setAttribute('aria-expanded', 'false');
  menuPrompt = undefined;
}

function showSessionMenu(machine: Machine, session: Session, anchor: HTMLButtonElement): void {
  if (sessionBusy(machine) || machine.status !== 'Connected') return;
  const same = menuPrompt?.anchor === anchor && sessionMenu.matches(':popover-open');
  hideSessionMenu();
  if (same) return;
  menuPrompt = { machineID: machine.id, sessionID: session.id, anchor };
  anchor.setAttribute('aria-expanded', 'true');
  sessionMenu.showPopover();
  const bounds = anchor.getBoundingClientRect();
  const menu = sessionMenu.getBoundingClientRect();
  sessionMenu.style.left = `${Math.max(8, Math.min(bounds.right - menu.width, innerWidth - menu.width - 8))}px`;
  sessionMenu.style.top = `${bounds.bottom + menu.height + 4 < innerHeight ? bounds.bottom + 4 : Math.max(8, bounds.top - menu.height - 4)}px`;
  sessionMenu.querySelector<HTMLButtonElement>('button')?.focus();
}

function promptSession(): { machine: Machine; session: Session } | undefined {
  const machine = menuPrompt && machines.get(menuPrompt.machineID);
  const session = machine?.roster?.projects.flatMap((project) => project.sessions).find((session) => session.id === menuPrompt?.sessionID);
  hideSessionMenu();
  return machine && session ? { machine, session } : undefined;
}

element('menu-rename-session').addEventListener('click', () => {
  const prompt = promptSession();
  if (prompt) showSessionName(prompt.machine, prompt.session);
});
element('menu-close-session').addEventListener('click', () => {
  const prompt = promptSession();
  if (!prompt) return;
  closePrompt = { machineID: prompt.machine.id, sessionID: prompt.session.id };
  element('close-session-description').textContent = `Close “${prompt.session.title}”? This stops the shell and any program running in this session on the machine.`;
  showCloseError(prompt.machine, '');
  closeDialog.showModal();
  closeCancel.focus();
});
sessionMenu.addEventListener('toggle', () => {
  if (!sessionMenu.matches(':popover-open')) hideSessionMenu();
});
sessionMenu.addEventListener('keydown', (event) => {
  const items = [...sessionMenu.querySelectorAll<HTMLButtonElement>('button')];
  const index = items.indexOf(document.activeElement as HTMLButtonElement);
  if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
    event.preventDefault();
    items[event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1 :
      (index + (event.key === 'ArrowDown' ? 1 : items.length - 1)) % items.length]?.focus();
  } else if (event.key === 'Escape') {
    event.preventDefault();
    const anchor = menuPrompt?.anchor;
    hideSessionMenu();
    anchor?.focus();
  }
});
window.addEventListener('resize', hideSessionMenu);
element('machines').addEventListener('scroll', hideSessionMenu);

function clearClose(machine: Machine): void {
  clearTimeout(machine.pendingClose?.timeout);
  machine.pendingClose = undefined;
}

function refreshCloseDialog(): void {
  const machine = closePrompt && machines.get(closePrompt.machineID);
  const busy = !!machine?.pendingClose;
  closeSubmit.disabled = busy || machine?.status !== 'Connected' || !!machine && sessionBusy(machine);
  closeSubmit.textContent = busy ? 'Closing…' : 'Close Session';
  closeSubmit.setAttribute('aria-busy', String(busy));
  closeCancel.disabled = busy;
}

function showCloseError(machine: Machine, message: string): void {
  machine.error = message;
  if (closePrompt?.machineID === machine.id) {
    element('close-session-error').textContent = message;
    element('close-session-error').hidden = !message;
    refreshCloseDialog();
  }
}

closeSubmit.addEventListener('click', () => {
  const machine = closePrompt && machines.get(closePrompt.machineID);
  if (!machine || !closePrompt || machine.status !== 'Connected' || sessionBusy(machine)) return;
  const sessionID = closePrompt.sessionID;
  machine.pendingClose = { sessionID, timeout: setTimeout(() => {
    clearClose(machine);
    showCloseError(machine, 'The machine didn’t confirm the close. Sync sessions before trying again.');
    renderMachines();
  }, 15000) };
  showCloseError(machine, '');
  if (!machine.link.send({ t: 'stop', session: sessionID })) {
    clearClose(machine);
    showCloseError(machine, 'Couldn’t close the session. Check the connection and try again.');
  }
  refreshCloseDialog();
  renderMachines();
});
closeCancel.addEventListener('click', () => closeDialog.close());
closeDialog.addEventListener('cancel', (event) => {
  if (closePrompt && machines.get(closePrompt.machineID)?.pendingClose) event.preventDefault();
});
closeDialog.addEventListener('close', () => { closePrompt = undefined; terminal?.focus(); });

function refreshNameDialog(): void {
  const machine = namePrompt && machines.get(namePrompt.machineID);
  const busy = !!machine && nameBusy(machine);
  nameInput.disabled = busy;
  nameCancel.disabled = busy;
  nameSubmit.disabled = busy || machine?.status !== 'Connected' || !!machine && sessionBusy(machine);
  nameSubmit.textContent = busy ? 'Saving…' : namePrompt?.creating && !namePrompt.sessionID ? 'Create Session' : 'Rename';
  nameSubmit.setAttribute('aria-busy', String(busy));
}

function showNameError(machine: Machine, message: string): void {
  machine.error = message;
  if (namePrompt?.machineID === machine.id) {
    element('session-name-error').textContent = message;
    element('session-name-error').hidden = !message;
    refreshNameDialog();
  }
}

function showSessionName(machine: Machine, session?: Session): void {
  if (machine.status !== 'Connected' || sessionBusy(machine)) return;
  if ((machine.roster?.wire ?? 0) < 3) {
    machine.error = 'Update Termio on this Mac to name sessions from the browser.';
    renderMachines();
    return;
  }
  namePrompt = { machineID: machine.id, sessionID: session?.id, creating: !session };
  element('session-name-title').textContent = session ? 'Rename Session' : 'New Session';
  nameInput.value = session?.title ?? 'New Session';
  showNameError(machine, '');
  nameDialog.showModal();
  nameInput.focus();
  nameInput.select();
}

function clearRename(machine: Machine): void {
  clearTimeout(machine.pendingRename?.timeout);
  machine.pendingRename = undefined;
}

function renameSession(machine: Machine, session: Session, alias: string, name: string, open = false): void {
  const requestID = crypto.randomUUID();
  machine.pendingRename = { requestID, session, alias, name, open, timeout: setTimeout(() => {
    clearRename(machine);
    showNameError(machine, 'The machine didn’t confirm the name. Check the session list before trying again.');
    renderMachines();
  }, 15000) };
  if (!machine.link.send({ t: 'renameSession', session: session.id, name, request: requestID })) {
    clearRename(machine);
    showNameError(machine, 'Couldn’t send the session name. Reconnect to this Mac and try again.');
  }
  refreshNameDialog();
  renderMachines();
}

function startTerminal(machine: Machine, name: string): void {
  if (machine.status !== 'Connected' || sessionBusy(machine)) return;
  machine.error = '';
  machine.pendingTerminalName = name;
  openingTerminalMachineID = machine.id;
  machine.pendingTerminal = setTimeout(() => {
    clearTerminalStart(machine);
    showNameError(machine, 'The Mac didn’t confirm the new terminal. Check the session list before trying again.');
    renderMachines();
  }, 15000);
  const workspace = machine.roster?.projects[0]?.workspaceID;
  if (!machine.link.send({ t: 'startTerminal', ...(workspace ? { workspace } : {}) })) {
    clearTerminalStart(machine);
    showNameError(machine, 'Couldn’t request a new terminal. Reconnect to this Mac and try again.');
  }
  refreshNameDialog();
  renderMachines();
}

element('session-name-form').addEventListener('submit', (event) => {
  event.preventDefault();
  const machine = namePrompt && machines.get(namePrompt.machineID);
  if (!machine || machine.status !== 'Connected' || sessionBusy(machine)) return;
  const name = nameInput.value.trim();
  if (!name) { showNameError(machine, 'Enter a session name.'); return; }
  showNameError(machine, '');
  if (namePrompt?.sessionID) {
    const sessionID = namePrompt.sessionID;
    const project = machine.roster?.projects.find((project) => project.sessions.some((session) => session.id === sessionID));
    const session = project?.sessions.find((session) => session.id === sessionID)
      ?? { id: sessionID, title: name, agent: 'terminal', status: 'idle', subtitle: '' };
    renameSession(machine, session, project?.deviceAlias ?? '', name, namePrompt.creating);
  } else startTerminal(machine, name);
});
nameCancel.addEventListener('click', () => nameDialog.close());
nameDialog.addEventListener('cancel', (event) => {
  const machine = namePrompt && machines.get(namePrompt.machineID);
  if (machine && nameBusy(machine)) event.preventDefault();
});
nameDialog.addEventListener('close', () => { namePrompt = undefined; terminal?.focus(); });

function addMachine(address: PairingAddress, remember: boolean, name = address.host): void {
  const previous = [...machines.values()].find((machine) => machine.address.endpoint === address.endpoint);
  if (previous) {
    if (selected?.machineID === previous.id) detach();
    clearTerminalStart(previous);
    clearRename(previous);
    clearClose(previous);
    clearSync(previous);
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
      if (status !== 'Connected') {
        const busy = nameBusy(machine);
        clearTerminalStart(machine);
        clearRename(machine);
        if (machine.pendingClose) {
          clearClose(machine);
          showCloseError(machine, 'Connection lost before the machine confirmed the close. Sync sessions after reconnecting.');
        }
        if (error || status === 'Disconnected') clearSync(machine);
        if (busy) showNameError(machine, 'Connection lost before the machine confirmed the session. Check the session list after reconnecting.');
      }
      refreshNameDialog();
      refreshCloseDialog();
      renderMachines();
    },
    message: (message) => {
      if (message instanceof Uint8Array) return;
      if (message.t === 'roster') {
        machine.roster = parseRoster(message);
        clearSync(machine);
        machine.name = machine.roster.macName || machine.name;
        // A new tunnel URL may identify a Mac already in the list.
        for (const other of machines.values()) {
          if (other.id !== machine.id && machine.roster.macID && other.roster?.macID === machine.roster.macID) {
            if (selected?.machineID === other.id) detach();
            clearTerminalStart(other);
            clearRename(other);
            clearClose(other);
            clearSync(other);
            other.link.close();
            machines.delete(other.id);
          }
        }
        if (selected?.machineID === machine.id) {
          const session = machine.roster.projects.flatMap((project) => project.sessions).find((session) => session.id === selected?.sessionID);
          if (session) element('session-title').textContent = session.title;
          // A roster refresh must leave the terminal and its last output intact, even after an external close.
        }
        const closing = machine.pendingClose?.sessionID;
        if (closing && !machine.roster.projects.some((project) => project.sessions.some((session) => session.id === closing))) {
          clearClose(machine);
          if (closePrompt?.machineID === machine.id && closePrompt.sessionID === closing) closeDialog.close();
          if (selected?.machineID === machine.id && selected.sessionID === closing) detach();
          syncMachine(machine);
        }
        refreshNameDialog();
        refreshCloseDialog();
        save();
        renderMachines();
      } else if (message.t === 'started') {
        if (machine.pendingTerminal === undefined) return;
        const shouldOpen = openingTerminalMachineID === machine.id;
        const name = machine.pendingTerminalName ?? 'New Session';
        clearTerminalStart(machine);
        if (typeof message.session !== 'string' || !message.session.trim()) {
          showNameError(machine, 'The Mac didn’t return a session. Check the session list before trying again.');
          renderMachines();
          return;
        }
        const project = machine.roster?.projects.find((project) => project.sessions.some((session) => session.id === message.session));
        const session = project?.sessions.find((session) => session.id === message.session)
          ?? { id: message.session, title: 'Terminal', agent: 'terminal', status: 'idle', subtitle: '' };
        if (namePrompt?.machineID === machine.id) namePrompt.sessionID = message.session;
        renameSession(machine, session, project?.deviceAlias ?? '', name, shouldOpen);
      } else if (message.t === 'sessionRenamed') {
        const pending = machine.pendingRename;
        if (!pending || message.request !== pending.requestID || message.session !== pending.session.id) return;
        clearRename(machine);
        if (typeof message.error === 'string') {
          showNameError(machine, message.error);
          renderMachines();
          return;
        }
        if (typeof message.name !== 'string' || !message.name.trim()) {
          showNameError(machine, 'The machine returned an unreadable session name. Reconnect and try again.');
          renderMachines();
          return;
        }
        const renamed = { ...pending.session, title: message.name };
        for (const project of machine.roster?.projects ?? []) {
          const session = project.sessions.find((session) => session.id === renamed.id);
          if (session) session.title = renamed.title;
        }
        machine.error = '';
        if (selected?.machineID === machine.id && selected.sessionID === renamed.id) element('session-title').textContent = renamed.title;
        if (namePrompt?.machineID === machine.id && namePrompt.sessionID === renamed.id) nameDialog.close();
        if (pending.open) openSession(machine, renamed, pending.alias);
        else renderMachines();
        syncMachine(machine);
      } else if (message.t === 'error') {
        clearTerminalStart(machine);
        clearRename(machine);
        clearClose(machine);
        clearSync(machine);
        showNameError(machine, refusal(message));
        showCloseError(machine, refusal(message));
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
  hideSessionMenu();
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
    const sync = button('↻', 'icon-button sync-machine', () => syncMachine(machine));
    sync.setAttribute('aria-label', `Sync ${machine.name}`);
    sync.title = 'Sync Sessions';
    sync.disabled = sessionBusy(machine);
    sync.setAttribute('aria-busy', String(machine.pendingSync !== undefined));
    sync.dataset.focusKey = `sync-${machine.id}`;
    heading.append(node('span', `connection-dot ${machine.status === 'Connected' ? 'online' : ''}`), name, sync, forget);
    section.append(heading);
    const state = node('div', 'machine-state');
    state.append(node('span', '', machine.status));
    const reconnect = button(machine.status === 'Connected' ? 'Disconnect' : 'Reconnect', 'text-button', () => {
      if (machine.status === 'Connected') {
        clearTerminalStart(machine);
        clearRename(machine);
        clearClose(machine);
        clearSync(machine);
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
    const newTerminal = button(nameBusy(machine) ? 'Saving…' : 'New Terminal', 'new-terminal', () => showSessionName(machine));
    newTerminal.disabled = machine.status !== 'Connected' || sessionBusy(machine);
    newTerminal.setAttribute('aria-busy', String(nameBusy(machine)));
    newTerminal.dataset.focusKey = `new-terminal-${machine.id}`;
    section.append(newTerminal);
    if (machine.error) {
      const error = node('p', 'machine-error', machine.error);
      error.setAttribute('role', 'alert');
      section.append(error);
    }
    if (machine.roster) {
      const groups = machineSections(machine.roster.projects);
      if (!groups.length) section.append(node('p', 'empty-machines', 'Choose New Terminal to start a session on your Mac.'));
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
          const more = button('⋯', 'icon-button session-menu-button', () => showSessionMenu(machine, session, more));
          more.setAttribute('aria-label', 'Session Actions');
          more.setAttribute('aria-haspopup', 'menu');
          more.setAttribute('aria-expanded', 'false');
          more.setAttribute('aria-controls', 'session-menu');
          more.title = `Actions for ${session.title}`;
          more.disabled = machine.status !== 'Connected' || sessionBusy(machine);
          more.dataset.focusKey = `menu-${machine.id}-${session.id}`;
          const item = node('div', 'session-item');
          item.setAttribute('role', 'group');
          item.setAttribute('aria-label', session.title);
          item.append(row, more);
          section.append(item);
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
  if (emptyDescription) emptyDescription.textContent = machines.size ? 'Choose a session or New Terminal from the machines on the left.' : 'Connect a machine, then select a session.';
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
  openingTerminalMachineID = undefined;
  for (const machine of machines.values()) if (machine.pendingRename) machine.pendingRename.open = false;
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
  openingTerminalMachineID = undefined;
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
    if (machine) { clearTerminalStart(machine); clearRename(machine); clearClose(machine); clearSync(machine); }
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
window.addEventListener('pagehide', () => { terminal?.dispose(); machines.forEach((machine) => { clearTerminalStart(machine); clearRename(machine); clearClose(machine); clearSync(machine); machine.link.close(); }); });
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
