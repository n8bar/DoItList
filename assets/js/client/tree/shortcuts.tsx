// The keyboard-shortcuts help (m04.02 item 2.2.4).
//
// The same list the LiveView's `shortcuts_overlay/1` shows, in the client's own
// dialog primitive (`ui/dialog.tsx`) rather than a second hand-rolled modal —
// so it gets the platform's focus trap, Escape and top layer for free, and so
// there is one wording of the shortcuts rather than two.

import { SHORTCUTS } from "./keyboard_model.ts";
import { Dialog } from "../ui/dialog.tsx";

export function ShortcutsOverlay({ open, onClose }: { open: boolean; onClose: () => void }) {
  return (
    <Dialog id="shortcuts-overlay" open={open} title="Keyboard shortcuts" onCancel={onClose}>
      <dl className="space-y-2">
        {SHORTCUTS.map(([keys, label]) => (
          <div key={keys} className="flex items-baseline justify-between gap-4">
            <dt className="flex-none">
              <kbd className="px-1.5 py-0.5 rounded border border-zinc-300 dark:border-zinc-600 bg-zinc-50 dark:bg-zinc-800 text-xs font-medium text-zinc-700 dark:text-zinc-200">
                {keys}
              </kbd>
            </dt>
            <dd className="text-sm text-zinc-600 dark:text-zinc-300 text-right">{label}</dd>
          </div>
        ))}
      </dl>
    </Dialog>
  );
}
