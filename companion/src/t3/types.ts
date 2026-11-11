// Companion-side domain types. These are deliberately independent of T3's wire schema so the
// T3 API can change behind T3Client without touching the snapshot/addon code.

export type RawStatus =
  | "idle" | "preparing" | "queued" | "starting" | "running" | "waiting"
  | "completed" | "interrupted" | "failed" | "cancelled" | "rolled_back" | string;

export interface PendingSummary {
  id: string;
  /** T3 kind: command | file-read | file-change | mcp-elicitation | permission | dynamic_tool_call | user_input | auth_refresh */
  kind: string;
  blocking?: boolean;
}

export interface ThreadSummary {
  id: string;
  title: string;
  status: RawStatus;
  pending: PendingSummary | null;
  /** epoch ms */
  startedAt: number | null;
  completedAt: number | null;
  updatedAt: number;
  providerInstanceId: string;
  modelSlug: string;
  projectId: string;
  isSubagent: boolean;
  createdBy: string;
  archived: boolean;
  settled: boolean;
  /**
   * Subagent lineage (VERIFIED live, T3 0.1.8): `lineage.parentThreadId` / `lineage.rootThreadId`.
   * Only threads with `relationshipToParent === "subagent"` are children (forks also carry a parent but
   * are listed like top-level threads). Optional so older fakes/tests stay valid.
   */
  parentId?: string | null;
  rootId?: string | null;
  /** A provider-native subagent thread (Claude `Agent` tool, Codex spawn_agent): `thread:provider:...` ids. */
  native?: boolean;
  /** `activityRunStatus` (non-null while a native subagent's run is live; its `status` stays "idle"). */
  activity?: string | null;
  /** epoch ms */
  createdAt?: number | null;
  /**
   * Built from the focused thread's projection (no shell row): it lacks `status` and run times, so any shell
   * or family row of the same thread wins over it (rev 1.4).
   */
  partial?: boolean;
}

export interface ProjectSummary { id: string; title: string }

/** The model's selectable reasoning effort (T3 option descriptor id "effort"): ids in menu order and the default. */
export interface EffortChoice { values: string[]; def: string }

export interface ModelChoice { id: string; name: string; effort?: EffortChoice }

export interface ProviderSummary {
  instanceId: string;
  displayName: string;
  enabled: boolean;
  models: ModelChoice[];
}

export type Role = "u" | "a" | "t" | "s";

/** An image attached to a T3 message (user_message.attachments[] with type "image"; VERIFIED live). */
export interface ImageRef { id: string; name: string; mimeType: string; sizeBytes: number }

/** An attachment for message.dispatch (an uploaded image: `attachments.createUploadUrl` id). */
export interface AttachmentInput { type: "image"; id: string; name: string; mimeType: string; sizeBytes: number }

/**
 * Ordered message parts (rev 1.4): plain text and links to other T3 threads (subagent/child threads,
 * `t3-thread://` links). When present they replace `text` for the snapshot segments; `text` stays the
 * plain-text form (copy, byte counts).
 */
export type MsgPart = { kind: "text"; text: string } | { kind: "link"; threadId: string; label: string };

export interface ChatMessage {
  /** Stable, monotonic message index (derived from T3 turn-item ordinals). */
  i: number;
  role: Role;
  /** epoch seconds */
  ts: number;
  /** Markdown-ish text. */
  text: string;
  streaming: boolean;
  /** Image attachments (user messages). */
  images?: ImageRef[];
  /** Text + thread links in order (rev 1.4). */
  parts?: MsgPart[];
}

/** A `subagent` turn item of a thread (VERIFIED live): the child thread and the parent's view of its run. */
export interface SubagentRef { childThreadId: string; status: string; title: string; startedAt: number | null; completedAt: number | null }

export interface PendingOption { id: string; label: string }

export interface PendingRequest {
  kind: "approval" | "input";
  requestId: string;
  text: string;
  options: PendingOption[];
  /** For user_input: question ids, and option id -> answer value per question. */
  questions?: { id: string; header: string; question: string; multiSelect: boolean; options: { id: string; label: string; value: string }[] }[];
  /** T3 request kind, e.g. command, user_input. */
  t3Kind: string;
}

export interface ThreadDetail {
  id: string;
  title: string;
  providerInstanceId: string;
  modelSlug: string;
  modelOptions: unknown;
  streaming: boolean;
  activeRunId: string | null;
  pending: PendingRequest | null;
  /** Oldest first. */
  messages: ChatMessage[];
  hasOlder: boolean;
  /** The thread's `subagent` turn items (child thread id + run state as the parent sees it), rev 1.4. */
  subagents?: SubagentRef[];
  /** Lineage of the focused thread itself (from its projection), rev 1.4. */
  parentId?: string | null;
  rootId?: string | null;
}
