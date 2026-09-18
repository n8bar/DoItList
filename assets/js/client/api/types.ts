// The `/app/api` read shapes, as TypeScript (m04.01 worklist 3).
//
// Mirrors `DoItWeb.Api.Serializer` — snake_case keys, integer ids, ISO-8601 UTC
// timestamps — so the server's documented shape and the client's type are one
// thing to keep in step, not two. Only the fields the client actually reads are
// declared; the serializer is free to send more.
//
// Arc 2 renders these: `TaskNode` carries every field the tree draws, and
// `tree/model.ts` flattens the nested read into the client's own model.

export type Role = "owner" | "editor" | "viewer";
export type ProgressCalc = "leaf_average" | "single_level";
export type TaskStatus = "open" | "in_progress" | "done";
export type Priority = "high" | "normal" | "low";

/** A sibling-ordering rule (`DoIt.Tasks.Sort`). `null` on a task means inherit. */
export type SortMode = "manual" | "alphabetical" | "completion" | "priority" | "created" | "updated";

/** One end of a `%<id>` cross-reference, resolved to the live label. */
export interface CrossReference {
  target_id: number;
  target_index: string;
  target_title: string;
}

/** The other end: a task that points at this one. */
export interface ReferencedBy {
  source_id: number;
  source_index: string;
  source_title: string;
}

/** A row of `GET /app/api/initiatives`. */
export interface InitiativeSummary {
  id: number;
  name: string;
  subtitle: string | null;
  /** The card's second line. `null` when the Initiative has none. */
  description: string | null;
  role: Role;
  /** Rolled-up progress, 0..100. */
  progress: number;
  unit_count: number;
  root_task_id: number;
  version: number;
  /** This user's manual position in the index, or `null` before a drag. */
  sort_order: number | null;
  archived: boolean;
  created_at: string;
  updated_at: string;
}

/** A row of the user's Archived list: the summary plus their own `hidden` flag. */
export interface ArchivedInitiative extends InitiativeSummary {
  hidden: boolean;
}

/** A row of the owner's Trash. */
export interface TrashedInitiative extends InitiativeSummary {
  hidden: boolean;
  trashed_at: string;
}

/** `GET /app/api/initiatives/archive` — what the Archived and Trash drawer shows. */
export interface InitiativeArchive {
  archived: ArchivedInitiative[];
  trashed: TrashedInitiative[];
  /** How many days Trash keeps a row before the sweep deletes it. */
  retention_days: number;
}

/** A node of the nested tree. */
export interface TaskNode {
  id: number;
  title: string;
  description: string | null;
  index: string;
  position: number;
  parent_id: number;
  depth: number;
  progress: number;
  manual_progress: number;
  status: TaskStatus;
  done: boolean;
  leaf: boolean;
  priority: Priority;
  assignee_id: number | null;
  co_assignee_ids: number[];
  comment_count: number;
  cross_references: CrossReference[];
  referenced_by: ReferencedBy[];
  /**
   * The branch's own sibling-ordering rule, or `null` to inherit it from the
   * nearest ancestor that set one. The serializer starts sending this pair with
   * the tree read that follows this arc's model; a read that predates it is
   * read as `null` / `false`, which is what inheriting from the root means.
   */
  sort_mode: SortMode | null;
  sort_reverse: boolean;
  version: number;
  children: TaskNode[];
}

/**
 * One row of `GET /app/api/initiatives/:id/members` (`Serializer.member/1`).
 * Only the fields the tree draws are declared: who they are, and what they may
 * do. The avatar's colour comes from `user_id`, the same way the server derives
 * it (`frame/avatar_model.ts`).
 */
export interface Member {
  user_id: number;
  role: Role;
  name: string | null;
  username: string;
}

/** `GET /app/api/initiatives/:id` — header plus the nested tree. */
export interface InitiativeTree {
  id: number;
  name: string;
  subtitle: string | null;
  role: Role;
  progress: number;
  progress_calc: ProgressCalc;
  unit_count: number;
  index_style: string;
  root_task_id: number;
  version: number;
  tasks: TaskNode[];
}
