// Handshake between the bootstrap document's inline guards and the client.
// The document's watchdog stands down once the client sets `__doit_client_ready`.
export {};

declare global {
  interface Window {
    __doit_client_ready?: boolean;
    __doit_boot_failed?: boolean;
    __doitBootFail?: (kind: "asset" | "slow") => void;
  }
}
