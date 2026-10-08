export const wireVersion = 3;

export interface PairingAddress { url: string; token: string; endpoint: string; host: string }
export interface Session { id: string; title: string; agent: string; status: string; subtitle: string }
export interface Project { id: string; workspaceID: string; deviceAlias: string; sessions: Session[] }
export interface Roster { wire: number; macID: string; macName: string; projects: Project[] }
export type Control = Record<string, unknown> & { t: string };

export function pairingAddress(raw: string, pageProtocol = location.protocol): PairingAddress {
  let address: URL;
  try { address = new URL(raw.trim()); } catch {
    throw new Error('Enter the connection address from Settings → Mobile on your Mac.');
  }
  if (address.protocol === 'termio:') {
    throw new Error('Turn off Direct Attach in Settings → Mobile, then copy the WebSocket address.');
  }
  if (!['ws:', 'wss:', 'http:', 'https:'].includes(address.protocol) || !address.hostname || address.username || address.password || address.port === '0') {
    throw new Error('Enter a ws:// or wss:// address from Settings → Mobile.');
  }
  address.protocol = address.protocol === 'https:' || address.protocol === 'wss:' ? 'wss:' : 'ws:';
  if (pageProtocol === 'https:' && address.protocol === 'ws:') {
    throw new Error('Use a secure wss:// address with this HTTPS page, or open the standalone HTML file directly.');
  }
  const tokens = address.searchParams.getAll('t');
  if (tokens.length !== 1 || !tokens[0].trim()) throw new Error('The address has no valid pairing token. Copy it again from your Mac.');
  address.hash = '';
  const url = address.href;
  address.searchParams.delete('t');
  address.searchParams.sort();
  return { url, token: tokens[0], endpoint: address.href, host: address.host };
}

export function parseControl(text: string): Control {
  const value: unknown = JSON.parse(text);
  if (!value || typeof value !== 'object' || !('t' in value) || typeof value.t !== 'string') {
    throw new Error('The Mac sent an unreadable message. Update Termio and reconnect.');
  }
  return value as Control;
}

const string = (value: unknown, fallback = '') => typeof value === 'string' ? value : fallback;
const records = (value: unknown): Record<string, unknown>[] => Array.isArray(value)
  ? value.filter((item) => item && typeof item === 'object') : [];

export function parseRoster(message: Control): Roster {
  if (typeof message.wire !== 'number' || message.wire < 2) {
    throw new Error('Update Termio on your Mac to connect this browser.');
  }
  return {
    wire: message.wire,
    macID: string(message.macID), macName: string(message.macName),
    projects: records(message.projects).filter((project) => string(project.id)).map((project) => ({
      id: string(project.id), workspaceID: string(project.workspaceID), deviceAlias: string(project.deviceAlias),
      sessions: records(project.sessions).filter((session) => string(session.id)).map((session) => ({
        id: string(session.id), title: string(session.title, 'Session'), agent: string(session.agent),
        status: string(session.status), subtitle: string(session.subtitle),
      })),
    })),
  };
}

export function machineSections(projects: Project[]): { alias: string; sessions: Session[] }[] {
  const sections = new Map<string, Map<string, Session>>();
  for (const project of projects) {
    const sessions = sections.get(project.deviceAlias) ?? new Map<string, Session>();
    project.sessions.forEach((session) => sessions.set(session.id, session));
    sections.set(project.deviceAlias, sessions);
  }
  return [...sections].sort(([left], [right]) => Number(!!left) - Number(!!right))
    .map(([alias, sessions]) => ({ alias, sessions: [...sessions.values()] }));
}

export function refusal(message: Control): string {
  if (message.code === 'unauthorized') return 'This pairing token was refused. Copy a new address from Settings → Mobile.';
  if (message.code === 'client_too_old') return 'Update the web companion to connect to this Mac.';
  return string(message.message, 'The Mac refused the request. Reconnect to try again.');
}

export function validGrid(columns: unknown, rows: unknown): columns is number {
  return Number.isInteger(columns) && Number.isInteger(rows)
    && Number(columns) >= 1 && Number(columns) <= 4096 && Number(rows) >= 1 && Number(rows) <= 2048;
}
