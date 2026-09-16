// The notifications bell (m04.01 item 4.6.3).
//
// Where the LiveView header has it — immediately left of the account menu, a
// top-level item at every breakpoint, never folded into the hamburger, because
// notifications should be one tap away on a phone too.
//
// The dot is the only thing that changes when something arrives, and it is
// drawn INSIDE the bell's own box (absolutely positioned), so a notification
// landing cannot make the control wider and shove the header around (item 4.4).
//
// Opening is local and instant; marking read is optimistic (guardrails §6): the
// dot clears the moment the flyout opens, the `update notification` operation —
// the one the LiveView and the agent API already use — follows, and if it fails
// the dot comes back and a notice says so. There is no second write path.

import { useCallback, useEffect, useRef } from "react";

import { useServices } from "../services.tsx";
import type { DomainState } from "../state/domain.ts";
import { updateNotifications } from "../state/domain.ts";
import type { NotificationRow, NotificationsState } from "../state/notifications.ts";
import { loaded, markAllRead } from "../state/notifications.ts";
import { pushNotice } from "../state/ui.ts";
import { useStoreValue } from "../state/use_store.ts";
import { Icon } from "../ui/icon.tsx";
import type { MenuItemModel } from "../ui/menu_model.ts";
import { Menu } from "../ui/menu.tsx";

const selectNotifications = (state: DomainState): NotificationsState => state.notifications;

interface NotificationsPayload {
  recent: readonly NotificationRow[];
  unread: number;
}

const TRIGGER_CLASS = [
  "relative inline-flex min-h-11 min-w-11 items-center justify-center rounded-lg",
  "border border-transparent text-zinc-600 transition-colors",
  "hover:bg-zinc-100 hover:text-zinc-900 motion-reduce:transition-none",
  "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-600",
  "dark:text-zinc-300 dark:hover:bg-zinc-800 dark:hover:text-zinc-50",
  "dark:focus-visible:ring-emerald-400",
  "sm:min-h-9 sm:min-w-9",
].join(" ");

export function Bell({ className }: { className?: string }) {
  const { api, stores } = useServices();
  const { recent, unread, loaded: hasRead } = useStoreValue(stores.domain, selectNotifications);
  const alive = useRef(true);

  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  // The bell paints before this comes back — an empty flyout with the words for
  // it, never a spinner standing between the user and the control (§6.7).
  useEffect(() => {
    void api.get<NotificationsPayload>("/notifications").then((result) => {
      if (!alive.current || !result.ok) return;
      updateNotifications(stores.domain, (state) =>
        loaded(state, result.data.recent, result.data.unread),
      );
    });
  }, [api, stores.domain]);

  const markRead = useCallback(() => {
    const before = stores.domain.get().notifications;
    if (before.unread === 0) return;

    // Optimistic first, request second.
    updateNotifications(stores.domain, markAllRead);

    void api
      .post("/operations", {
        operations: [{ type: "update", entity: "notification", all: true }],
      })
      .then((result) => {
        if (result.ok || !alive.current) return;
        // Never leave the user believing something happened that didn't.
        updateNotifications(stores.domain, () => before);
        pushNotice(stores.ui, {
          kind: "error",
          message: "Couldn’t mark your notifications read. They’re still waiting for you.",
        });
      });
  }, [api, stores.domain, stores.ui]);

  const items: readonly MenuItemModel[] = recent.map((row) => ({
    id: String(row.id),
    label: row.line,
    href: row.href,
    ...(row.read ? {} : { unseen: true }),
  }));

  const withMarkAll: readonly MenuItemModel[] =
    unread > 0 ? [...items, { id: "mark-all-read", label: "Mark all read" }] : items;

  return (
    <Menu
      id="client-bell"
      label={unread > 0 ? `Notifications (${unread} unread)` : "Notifications"}
      items={withMarkAll}
      empty={hasRead ? "Nothing yet" : "Loading…"}
      panelClassName="w-72"
      triggerClassName={TRIGGER_CLASS}
      onOpenChange={(open) => {
        if (open) markRead();
      }}
      onSelect={(itemId) => {
        if (itemId === "mark-all-read") markRead();
      }}
      {...(className === undefined ? {} : { className })}
      trigger={
        <span className="relative inline-flex">
          <Icon name="bell" className="size-5 flex-none" />
          {unread > 0 ? (
            <span
              data-notif-dot
              aria-label="Unread notifications"
              className="absolute -right-0.5 -top-0.5 size-2.5 rounded-full bg-red-500 ring-2 ring-white dark:ring-zinc-900"
            />
          ) : null}
        </span>
      }
    />
  );
}
