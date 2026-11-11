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
}

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
}
