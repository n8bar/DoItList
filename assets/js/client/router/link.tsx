// A link that stays a link (m04.01 item 3.2).
//
// It renders a real `<a href>`, so the status bar shows where it goes, the
// context menu offers "open in new tab", and middle-click, ctrl/cmd-click and
// shift-click all do what the browser does. Only the plain left-click — the one
// case the client can serve instantly — is intercepted; `click.ts` owns that
// decision and is unit-tested.

import type { AnchorHTMLAttributes } from "react";

import { handledLocally } from "./click.ts";
import { useRouter } from "./router.tsx";

export interface LinkProps extends Omit<AnchorHTMLAttributes<HTMLAnchorElement>, "href"> {
  /** An absolute in-app path, e.g. `/app/initiatives/12`. */
  to: string;
  /** Replace the current history entry instead of pushing a new one. */
  replace?: boolean;
}

export function Link({ to, replace, onClick, ...rest }: LinkProps) {
  const { navigate } = useRouter();

  return (
    <a
      {...rest}
      href={to}
      onClick={(event) => {
        onClick?.(event);
        if (!handledLocally(event, to, event.currentTarget.getAttribute("target"))) return;
        event.preventDefault();
        navigate(to, replace === true ? { replace: true } : undefined);
      }}
    />
  );
}
