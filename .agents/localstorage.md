# localStorage Convention

Browser localStorage usage in this project follows a per-feature versioning scheme. There is no cross-feature compatibility matrix — each feature owns its namespace and versions independently.

## Rules

1. **Namespace per feature.** Every key lives under `phx:<feature>:...`. Examples: `phx:sortrev:42:alphabetical`, `phx:collapse:3:7`.
2. **Version sentinel.** Each namespace stores `phx:<feature>:_v` (integer as string). Current version is a constant in the owning hook.
3. **Check on mount.** The hook that owns the namespace calls `ensureStorageVersion(namespace, currentVersion)` early in `mounted()`. Mismatch (or absent sentinel) → drop every key under that prefix, write the new version.
4. **Bump deliberately.** Increment the version constant only when key shape, value encoding, or semantics change. Never bump for a bug fix that leaves the data shape unchanged.
5. **Don't read other namespaces.** A hook never reads or writes outside its own `phx:<feature>:...` prefix. This is what makes (1)–(4) compose without a cross-feature matrix.

## Helper

`assets/js/app.js` exports `ensureStorageVersion(namespace, currentVersion, opts)`. Use it; don't reimplement.

`opts.grandfather: true` — when introducing the version check to a namespace whose existing keys already match the version you're declaring, pass this so an absent sentinel is stamped without wiping. Real version mismatches still wipe. Only valid at the introduction event; once stamped, future bumps go through the strict path.

Set `grandfather: true` only when you've personally read the existing key shape and value encoding and confirmed both match the version you're declaring. When unsure, omit it and accept the one-time wipe.

## Adding a new feature

1. Pick a short kebab-case `<feature>` slug.
2. In the hook's `mounted()`, call `ensureStorageVersion("phx:<feature>", 1)` before any reads or writes.
3. Use `phx:<feature>:...` for every key the hook touches.
4. When you later change the key shape or semantics, bump the constant in that hook.

## Notes

- Introducing the version check on a namespace that already has unversioned data wipes that data on first mount unless `grandfather: true` is set. Use the flag only when you've verified shape compatibility.
- A future global wipe across all features (e.g. renaming the `phx:` prefix) would need its own top-level sentinel. Not needed today.
