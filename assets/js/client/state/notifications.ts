// What the bell holds (m04.01 item 4.6.3).
//
// Server records: the user's recent notifications and how many of them are
// unread. They live in the domain store because that is where what the server
// said lives — whether the flyout is OPEN is view state and lives in the
// component (guardrails §7.3).
//
// Every change is a pure function here, so the rules that matter — the newest
// is on top, the same row arriving twice is still one row, the list is bounded,
// and marking read leaves the old value intact so a failed write can put it
// back — are unit-tested without React.

/** One row, exactly as `DoItWeb.Api.NotificationView` serialises it. */
export interface NotificationRow {
  readonly id: number;
  readonly kind: string;
  /** The whole sentence, written on the server. The client never composes it. */
  readonly line: string;
  /** A client path, e.g. `/app/initiatives/3?task=9`. */
  readonly href: string;
  readonly read: boolean;
  readonly inserted_at: string;
}

export interface NotificationsState {
  /** Newest first. */
  readonly recent: readonly NotificationRow[];
  readonly unread: number;
  /** False until the first read comes back — an empty bell is not "nothing". */
  readonly loaded: boolean;
}

/** The same cap `DoIt.Notifications.list_recent/2` applies. */
export const MAX_RECENT = 10;

export const emptyNotifications: NotificationsState = { recent: [], unread: 0, loaded: false };

/** How many of these rows are unread. */
export function unreadCount(rows: readonly NotificationRow[]): number {
  return rows.filter((row) => !row.read).length;
}

/** The answer to `GET /app/api/notifications`, taken verbatim. */
export function loaded(
  _state: NotificationsState,
  recent: readonly NotificationRow[],
  unread: number,
): NotificationsState {
  return { recent: recent.slice(0, MAX_RECENT), unread, loaded: true };
}

/**
 * A row that arrived over the socket. The same row twice — a reconnect replays,
 * or the read lands after the push — is still one row and one count.
 */
export function prepend(state: NotificationsState, row: NotificationRow): NotificationsState {
  if (state.recent.some((existing) => existing.id === row.id)) return state;
  return {
    recent: [row, ...state.recent].slice(0, MAX_RECENT),
    unread: row.read ? state.unread : state.unread + 1,
    loaded: state.loaded,
  };
}

/**
 * Optimistic: the dot clears and every row goes quiet the moment the user opens
 * the bell. The old value is untouched, so a write that fails can be undone by
 * putting it back.
 */
export function markAllRead(state: NotificationsState): NotificationsState {
  if (state.unread === 0 && state.recent.every((row) => row.read)) return state;
  return {
    recent: state.recent.map((row) => (row.read ? row : { ...row, read: true })),
    unread: 0,
    loaded: state.loaded,
  };
}
