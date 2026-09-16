// The one place the mark-all-read operation is written down (m04.01 item 4.6.3).
//
// Three things send this payload: the bell, the browser harness's assertion
// about what the bell sent, and an ExUnit test that POSTs it at the real engine.
// They must be the same bytes, or the client ships a request the server answers
// with 422 and nobody finds out until a user with an unread notification opens
// the flyout — which is exactly what happened once.
//
// So it lives in ONE module, and it is plain JavaScript rather than TypeScript
// on purpose: the client bundles it, the client's Node suite imports it, and
// `bin/cdp/check_client.mjs` — which runs on whatever Node the operator's box
// has, with no type stripping — imports it too.
//
// The shape is the operations engine's envelope (`DoItWeb.Api.Operations`):
// `op` is the verb, `type` is the entity, and everything else rides in `data`.

/**
 * The operation that marks every one of the caller's notifications read.
 *
 * A fresh object each time: callers hand it to JSON.stringify, and a frozen
 * shared literal would only invite someone to mutate it and find out later.
 *
 * @returns {{op: "update", type: "notification", data: {all: true}}}
 */
export function markAllReadOperation() {
  return { op: "update", type: "notification", data: { all: true } };
}

/**
 * The whole request body for `POST /app/api/operations`.
 *
 * @returns {{operations: Array<{op: "update", type: "notification", data: {all: true}}>}}
 */
export function markAllReadRequest() {
  return { operations: [markAllReadOperation()] };
}
