// Route → screen (m04.01 item 3.2).
//
// One switch, exhaustive over `Route`, so adding a route is a type error until
// it has a screen. Every branch renders something immediately — the router
// moves focus to a heading right after this, and there is always a heading.

import { useRoute } from "../router/router.tsx";
import { AccountScreen } from "./account.tsx";
import { AssignedScreen } from "./assigned.tsx";
import { InitiativeScreen } from "./initiative.tsx";
import { InitiativesScreen } from "./initiatives.tsx";
import { NotFoundScreen } from "./not_found.tsx";

export function RouteView() {
  const route = useRoute();

  switch (route.kind) {
    case "initiatives":
      return <InitiativesScreen />;
    case "initiative":
      // Keyed: a different Initiative is a different screen, not the same one
      // with new props, so its loading state starts clean.
      return <InitiativeScreen key={route.id} id={route.id} />;
    case "assigned":
      return <AssignedScreen />;
    case "account":
      return <AccountScreen />;
    case "not-found":
      return <NotFoundScreen path={route.path} />;
    case "redirect":
      // In flight for one render: the router replaces this entry immediately.
      return null;
  }
}
