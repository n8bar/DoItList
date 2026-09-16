// The user's initials disc, derived the same way the server derives it
// (m04.01 item 4.5).
//
// The product has drawn a user as a coloured disc of their initials since M02
// (`DoItWeb.CoreComponents.avatar/1`): no uploads, and the colour comes from
// the user id, so the same person looks the same everywhere they appear. The
// account menu's avatar has to be that same disc — a second derivation would
// give the header a different-coloured version of the same user.
//
// So the palettes and the initials rule are ported value for value, and
// `avatar_model.test.ts` reads the Elixir source to hold them to it.

/** Just enough of a user to draw one. */
export interface AvatarUser {
  readonly name: string | null;
  readonly username: string;
}

// Four deterministic channels, exactly as `core_components.ex` has them: dark
// gradient start, dark gradient end, gradient angle (the 137° golden step), and
// a pale text tint. Sizes are pairwise coprime, so ids walk a long way before a
// look repeats.
const BACKGROUNDS = [
  "#059669",
  "#0284c7",
  "#7c3aed",
  "#e11d48",
  "#d97706",
  "#4f46e5",
  "#0d9488",
  "#c026d3",
  "#ea580c",
  "#65a30d",
];

const GRADIENTS = [
  "#2563eb",
  "#9333ea",
  "#dc2626",
  "#ca8a04",
  "#0891b2",
  "#db2777",
  "#16a34a",
  "#4338ca",
  "#b45309",
];

const FOREGROUNDS = ["#a7f3d0", "#bae6fd", "#ddd6fe", "#fecdd3", "#fde68a", "#f5d0fe", "#d9f99d"];

const pick = (palette: readonly string[], id: number): string =>
  palette[((id % palette.length) + palette.length) % palette.length] as string;

/** The disc's `background-image`. */
export function avatarBackground(id: number): string {
  return `linear-gradient(${((id * 137) % 360 + 360) % 360}deg, ${pick(BACKGROUNDS, id)}, ${pick(
    GRADIENTS,
    id,
  )})`;
}

/** The initials' colour. */
export function avatarForeground(id: number): string {
  return pick(FOREGROUNDS, id);
}

// Generational/honorific suffixes are ignored when picking the surname initial
// ("Alvin Cubbins III" → AC). Bare "i" stays off the list — too likely to be a
// real trailing initial.
const SUFFIXES = new Set([
  "jr",
  "jnr",
  "sr",
  "snr",
  "esq",
  "ii",
  "iii",
  "iv",
  "v",
  "vi",
  "vii",
  "viii",
  "ix",
  "x",
]);

function dropTrailingSuffixes(words: string[]): string[] {
  const last = words[words.length - 1];
  if (last === undefined || words.length <= 1) return words;
  const normalised = last.replace(/\.+$/, "").toLowerCase();
  return SUFFIXES.has(normalised) ? dropTrailingSuffixes(words.slice(0, -1)) : words;
}

/** The user's initials: first name, last name, upper case. Never empty. */
export function initials(user: AvatarUser): string {
  const words = dropTrailingSuffixes((user.name ?? "").split(/\s+/).filter((w) => w !== ""));
  const letters = words.map((word) => word[0] as string);

  if (letters.length === 0) return fromUsername(user.username);
  if (letters.length === 1) return (letters[0] as string).toUpperCase();
  return ((letters[0] as string) + (letters[letters.length - 1] as string)).toUpperCase();
}

// `initials_from_username/1` in `core_components.ex`: the username's first two
// characters, upper-cased — "dana" is DA, not D. A username is never blank in
// practice; if one ever were, a "?" says so rather than drawing an empty disc.
function fromUsername(username: string): string {
  const trimmed = username.trim().slice(0, 2);
  return trimmed === "" ? "?" : trimmed.toUpperCase();
}
