// The `/app/api` read shapes, as TypeScript (m04.01 worklist 3).
//
// Mirrors `DoItWeb.Api.Serializer` — snake_case keys, integer ids, ISO-8601 UTC
// timestamps — so the server's documented shape and the client's type are one
// thing to keep in step, not two. Only the fields the client actually reads are
// declared; the serializer is free to send more.
//
// Arc 2 owns the task tree proper. `TaskNode` is declared here because the tree
// endpoint returns it, but nothing in this arc renders past the header.

export type Role = "owner" | "editor" | "viewer";
export type ProgressCalc = "leaf_average" | "single_level";
export type TaskStatus = "open" | "in_progress" | "done";

/** A row of `GET /app/api/initiatives`. */
export interface InitiativeSummary {
  id: number;
  name: string;
  subtitle: string | null;
  role: Role;
  /** Rolled-up progress, 0..100. */
  progress: number;
  unit_count: number;
  root_task_id: number;
  version: number;
  sort_order: number | null;
  archived: boolean;
  updated_at: string;
}

/** A node of the nested tree. Arc 2 renders these; this arc only carries them. */
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
  version: number;
  children: TaskNode[];
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
