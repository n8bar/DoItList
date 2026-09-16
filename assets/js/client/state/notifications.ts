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

/** Newest first: by when it happened, and by id when two share a moment. */
function newestFirst(a: NotificationRow, b: NotificationRow): number {
  if (a.inserted_at === b.inserted_at) return b.id - a.id;
  return a.inserted_at < b.inserted_at ? 1 : -1;
}

/**
 * The answer to `GET /app/api/notifications`, merged with what we already hold.
 *
 * The socket is joined before this read comes back, so a notification can
 * arrive BEFORE the answer describing the world without it. Taking the answer
 * verbatim would throw that row away, and the bell would go quiet about
 * something the user was already told about. So the server's rows win wherever
 * the two overlap, and anything we hold that the server's snapshot never saw is
 * kept — counted, if it is unread.
 */
export function loaded(
  state: NotificationsState,
  recent: readonly NotificationRow[],
  unread: number,
): NotificationsState {
  const fromServer = new Set(recent.map((row) => row.id));
  const ours = state.recent.filter((row) => !fromServer.has(row.id));

  return {
    recent: [...recent, ...ours].sort(newestFirst).slice(0, MAX_RECENT),
    unread: unread + unreadCount(ours),
    loaded: true,
  };
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

/**
 * Undo an optimistic `markAllRead` after the write failed.
 *
 * It does NOT put a whole earlier snapshot back: rows can arrive over the
 * socket during the round trip, and restoring a value from before the request
 * would erase them. Only the read flags we set are unset, and only for the rows
 * that were unread when we set them.
 */
export function restoreUnread(
  state: NotificationsState,
  unreadIds: readonly number[],
): NotificationsState {
  const wasUnread = new Set(unreadIds);
  if (!state.recent.some((row) => wasUnread.has(row.id) && row.read)) return state;

  const recent = state.recent.map((row) =>
    wasUnread.has(row.id) && row.read ? { ...row, read: false } : row,
  );
  return { recent, unread: unreadCount(recent), loaded: state.loaded };
}
