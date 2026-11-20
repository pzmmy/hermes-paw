// =====================================================================
// model/ToolStep.ets — one tool invocation in the in-flight run (S1)
//
// Wire shapes (evidence/sse-run*.jsonl, 2026-10-27/29):
//   tool.started:   {tool, preview, tool_call_id, seq, timestamp}
//   tool.completed: {tool, tool_call_id, duration (s), error (bool), seq}
//
// Steps pair started->completed via tool_call_id. Transient: shown
// only while the run is in flight (not persisted — plan §4.5 keeps
// rendered text; tool metadata is re-derivable from the SSE replay).
// =====================================================================

export class ToolStep {
  /** tool_call_id from tool.started (pairing key; may be '' if absent). */
  toolCallId: string = '';
  /** tool name (e.g. "terminal", "read_file"). */
  tool: string = '';
  /** command preview from tool.started (truncated server-side). */
  preview: string = '';
  /** duration in seconds from tool.completed; -1 = still running. */
  durationSec: number = -1;
  /** 'running' | 'ok' | 'error'. */
  state: string = 'running';
}
