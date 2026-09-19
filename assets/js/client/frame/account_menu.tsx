// The account menu (m04.01 item 4.5).
//
// The avatar in the top right, and behind it the three things the LiveView
// header has behind it: Account details, User Preferences, Sign out. The
// product has had it since M02 and the client had dropped it — the frame is
// supposed to be the same product, not a redesign (Task 6).
//
// It is the shared `ui/menu.tsx`, not a third menu: the same open/close rules,
// the same Escape-returns-focus promise, the same arrow keys. Account details
// and Preferences are real links, so middle-click and "open in new tab" still
// work; Sign out is an action, and it is the frame's existing sign-out flow
// (confirm-if-pending-writes, purge, submit) started through its handle.

import { useMemo, useRef } from "react";

import type { BootstrapUser } from "../boot.ts";
import type { MenuItemModel } from "../ui/menu_model.ts";
import { Menu } from "../ui/menu.tsx";
import { Icon } from "../ui/icon.tsx";
import { Avatar } from "./avatar.tsx";
import type { SignOutHandle } from "./sign_out.tsx";
import { SignOut } from "./sign_out.tsx";
import { unavailableLabel } from "../tree/action_class.ts";
import { useOffline } from "../ui/use_degraded.ts";

// User Preferences still lives on the LiveView account page — the client's own
// Account screen says so in as many words, and it moves here with the account
// arc. So that item leaves the client on purpose; it is a real link and the
// router lets it go, rather than routing it to a screen that hasn't got it.
const ITEMS: readonly MenuItemModel[] = [
  { id: "account", label: "Account details", href: "/app/account" },
  { id: "preferences", label: "User Preferences", href: "/account#account-preferences" },
  { id: "sign-out", label: "Sign out", danger: true },
];

export interface AccountMenuProps {
  user: BootstrapUser;
  /** Extra classes on the wrapper — the breakpoint that hides this instance. */
  className?: string;
}

export function AccountMenu({ user, className }: AccountMenuProps) {
  const signOut = useRef<SignOutHandle | null>(null);
  // Sign out ends a session the server holds (m04.03 5.3): offline it stays
  // in the menu, greyed, saying why — never gone, never a silent no-op.
  const offline = useOffline();
  const items = useMemo(
    () =>
      offline
        ? ITEMS.map((item) =>
            item.id === "sign-out" ? { ...item, label: unavailableLabel(item.label), disabled: true } : item,
          )
        : ITEMS,
    [offline],
  );

  return (
    <>
      <Menu
        id="client-account-menu"
        label={user.name ?? user.username}
        items={items}
        onSelect={(itemId) => {
          if (itemId === "sign-out") signOut.current?.start();
        }}
        {...(className === undefined ? {} : { className })}
        triggerClassName="inline-flex min-h-11 items-center gap-1.5 rounded-lg border border-transparent px-2 py-1.5 text-sm font-medium text-zinc-700 transition-colors hover:bg-zinc-100 hover:text-zinc-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-600 motion-reduce:transition-none dark:text-zinc-200 dark:hover:bg-zinc-800 dark:hover:text-zinc-50 dark:focus-visible:ring-emerald-400 sm:min-h-9"
        panelClassName="w-64"
        trigger={
          <>
            <Avatar user={user} />
            <span className="max-w-32 truncate">{user.name ?? user.username}</span>
            <Icon name="chevron-down" className="size-3 flex-none" />
          </>
        }
      />

      {/* The form that carries the request. It has no control of its own — the
          menu item above is the control — but it must stay in the document,
          because the purge finishes after the menu has closed. */}
      <SignOut idPrefix="client-account" chromeless ref={signOut} />
    </>
  );
}
