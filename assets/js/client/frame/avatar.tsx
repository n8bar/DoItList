// A user, drawn (m04.01 item 4.5).
//
// The M02 initials disc, not a new one: the colour and the letters come from
// `avatar_model.ts`, which mirrors `DoItWeb.CoreComponents.avatar/1` value for
// value, so the same person looks the same in the client header as on every
// LiveView page.
//
// Decoration on top of a name, never the name itself: `aria-hidden`, because
// whatever it sits beside — the account menu's trigger — is already named in
// words (guardrails §4.1).

import type { BootstrapUser } from "../boot.ts";
import { avatarBackground, avatarForeground, initials } from "./avatar_model.ts";

export interface AvatarProps {
  user: BootstrapUser;
  /** Size and text size. The default is the header's. */
  className?: string;
}

export function Avatar({ user, className }: AvatarProps) {
  return (
    <span
      aria-hidden="true"
      data-avatar
      className={`avatar-emboss relative inline-flex flex-none items-center justify-center rounded-full font-semibold select-none ${
        className ?? "size-5 text-[10px]"
      }`}
      style={{ backgroundImage: avatarBackground(user.id), color: avatarForeground(user.id) }}
    >
      {initials(user)}
    </span>
  );
}
