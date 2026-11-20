// =====================================================================
// net/SseParser.ets — incremental SSE frame parser (M1)
//
// Wire format (evidence-verified, evidence/sse-run*.jsonl, 2026-10-27):
//   - UTF-8 text; frames separated by a blank line; "data: <json>" lines
//   - the outer "event:" line is blank in practice -> NOT parsed (M0a)
//   - business event name = data JSON "event" field (fallback "type")
//   - known events: message.delta / tool.started / tool.completed /
//     approval.request / approval.settled / run.completed / run.failed /
//     run.cancelled / run.interrupted
// =====================================================================
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogSafe } from '../utils/LogSafe';

const TAG: string = 'SseParser';

/** One parsed SSE business event. */
export class SseEvent {
  /** business event name (payload "event", fallback "type"); '' if unparseable */
  event: string = '';
  /** raw data payload text (the JSON as received) */
  raw: string = '';
  /** parsed payload; null when JSON.parse failed or payload not an object */
  data: Record<string, Object> | null = null;
}

/** JSON Object -> string (null/undefined safe). */
function strFrom(v: Object | null | undefined): string {
  if (v === null || v === undefined) {
    return '';
  }
  return String(v);
}

/** JSON Object -> number (NaN/missing -> 0). */
function numFrom(v: Object | null | undefined): number {
  if (v === null || v === undefined) {
    return 0;
  }
  let n: number = Number(v);
  return Number.isNaN(n) ? 0 : n;
}

/**
 * Returns the length of the prefix that ends on a whole UTF-8 character.
 * A lead byte whose sequence is not fully buffered is left for the next feed.
 */
function findUtf8Boundary(bytes: Uint8Array): number {
  let len: number = bytes.length;
  if (len === 0) {
    return 0;
  }
  let i: number = len - 1;
  while (i > 0 && (bytes[i] & 0xC0) === 0x80) {
    i--;
  }
  let lead: number = bytes[i];
  let expected: number = 1;
  if ((lead & 0x80) === 0x00) {
    expected = 1;
  } else if ((lead & 0xE0) === 0xC0) {
    expected = 2;
  } else if ((lead & 0xF0) === 0xE0) {
    expected = 3;
  } else if ((lead & 0xF8) === 0xF0) {
    expected = 4;
  } else {
    expected = 1;
  }
  if (i + expected <= len) {
    return len;
  }
  return i;
}

/** Conduit 借鉴：估算 JSON 嵌套深度（防 DoS）。
 *  用正则数开括号/花括号最大值，O(n) 不递归。
 *  跨机收到的数据可能被中间设备注入恶意嵌套 JSON，深度超限直接丢弃。 */
function jsonDepth(raw: string): number {
  let maxD: number = 0;
  let cur: number = 0;
  for (let i: number = 0; i < raw.length; i++) {
    let c: string = raw.charAt(i);
    if (c === '{' || c === '[') {
      cur++;
      if (cur > maxD) {
        maxD = cur;
      }
    } else if (c === '}' || c === ']') {
      cur--;
    }
  }
  return maxD;
}

/** Parses one complete SSE frame (blank-line separated). */
function parseFrame(frame: string): SseEvent | null {
  let lines: string[] = frame.split('\n');
  let dataLines: string[] = [];
  for (let i: number = 0; i < lines.length; i++) {
    let line: string = lines[i];
    if (line.startsWith('data:')) {
      let payload: string = line.substring(5);
      if (payload.startsWith(' ')) {
        payload = payload.substring(1);
      }
      dataLines.push(payload);
    }
  }
  if (dataLines.length === 0) {
    return null;
  }
  let raw: string = dataLines.join('\n');
  if (raw === '') {
    return null;
  }
  let ev: SseEvent = new SseEvent();
  ev.raw = raw;
  try {
    // Conduit 借鉴：JSON 深度校验（防跨机污染/DoS）。嵌套 > 256 层直接丢弃。
    if (jsonDepth(raw) > 256) {
      LogSafe.w(TAG, 'JSON depth > 256, dropping frame (DoS guard)');
      ev.event = '';
      ev.data = null;
      return ev;
    }
    let parsed: Object = JSON.parse(raw);
    if (parsed instanceof Object && !(parsed instanceof Array)) {
      let d: Record<string, Object> = parsed as Record<string, Object>;
      let name: string = strFrom(d['event']);
      if (name === '') {
        name = strFrom(d['type']);
      }
      ev.event = name;
      ev.data = d;
    }
  } catch (err) {
    let e: BusinessError = err as BusinessError;
    // anomaly only: M1 data frames are always JSON; log the parse error,
    // never the payload text (house pattern P1-01)
    LogSafe.w(TAG, 'non-JSON data frame (kept raw): %{public}s', e.message);
    ev.event = '';
    ev.data = null;
  }
  return ev;
}

/** Incremental SSE parser; feed chunks, then call finish() at stream end. */
export class SseParser {
  /** pending bytes (incomplete UTF-8 tail carried across feed() calls) */
  private byteBuf: Uint8Array = new Uint8Array(0);
  /** decoded text awaiting frame cut */
  private textBuf: string = '';
  /** seq dedupe gate (S1): frames with seq <= seqGate are dropped.
   *  After a disconnect/background resubscribe the server replays
   *  the stream from seq 0, so the caller raises the gate to the
   *  last seq already applied (gateSeq). Fresh streams start at -1
   *  (accept everything; seq-less frames pass). */
  private seqGate: number = -1;

  /** Raise the dedupe gate (call before a resubscribed stream's first
   *  feed, with the last seq already applied). Monotonic only. */
  gateSeq(seq: number): void {
    if (seq > this.seqGate) {
      this.seqGate = seq;
    }
  }

  /** Apply the seq gate to a parsed frame (S1). */
  private accept(ev: SseEvent): boolean {
    let d: Record<string, Object> | null = ev.data;
    if (d === null) {
      return true; // no JSON object payload: keep (M1 behavior)
    }
    let n: number = Number(d['seq']);
    if (Number.isNaN(n)) {
      return true; // seq-less frame: keep (defensive)
    }
    if (n <= this.seqGate) {
      return false;
    }
    this.seqGate = n;
    return true;
  }

  /** Feed one raw network chunk; returns complete frames available now. */
  feed(chunk: ArrayBuffer): SseEvent[] {
    let src: Uint8Array = new Uint8Array(chunk);
    let merged: Uint8Array = new Uint8Array(this.byteBuf.length + src.length);
    merged.set(this.byteBuf, 0);
    merged.set(src, this.byteBuf.length);
    this.byteBuf = merged;

    let boundary: number = findUtf8Boundary(this.byteBuf);
    if (boundary > 0) {
      let dec: util.TextDecoder = util.TextDecoder.create('utf-8');
      let text: string = dec.decodeToString(this.byteBuf.subarray(0, boundary));
      let tail: Uint8Array = new Uint8Array(this.byteBuf.length - boundary);
      tail.set(this.byteBuf.subarray(boundary), 0);
      this.byteBuf = tail;
      // A CRLF pair can straddle a chunk boundary (\r decoded here, \n
      // in the next chunk): the per-chunk replace below would miss it,
      // so a \r dangling at the buffer end is dropped when this chunk
      // starts with \n (the \n still provides the line break).
      // batch2 P1-01.
      if (this.textBuf.endsWith('\r') && text.startsWith('\n')) {
        this.textBuf = this.textBuf.substring(0, this.textBuf.length - 1);
      }
      this.textBuf += text.replace(/\r\n/g, '\n');
    }

    let events: SseEvent[] = [];
    let sep: number = this.textBuf.indexOf('\n\n');
    while (sep >= 0) {
      let frame: string = this.textBuf.substring(0, sep);
      this.textBuf = this.textBuf.substring(sep + 2);
      let ev: SseEvent | null = parseFrame(frame);
      if (ev !== null && this.accept(ev)) {
        events.push(ev);
      }
      sep = this.textBuf.indexOf('\n\n');
    }
    return events;
  }

  /**
   * Stream ended: flush any complete bytes still held in byteBuf,
   * emit the trailing partial frame (if any) and reset. A final frame
   * split across a chunk boundary is not lost; an incomplete
   * character tail is dropped with a log (batch2 P1-02).
   */
  finish(): SseEvent[] {
    let events: SseEvent[] = [];
    if (this.byteBuf.length > 0) {
      let boundary: number = findUtf8Boundary(this.byteBuf);
      if (boundary > 0) {
        let dec: util.TextDecoder = util.TextDecoder.create('utf-8');
        // decodeToString: replaces deprecated decode (batch2-r4 P1-01)
        let text: string = dec.decodeToString(this.byteBuf.subarray(0, boundary));
        if (this.textBuf.endsWith('\r') && text.startsWith('\n')) {
          this.textBuf = this.textBuf.substring(0, this.textBuf.length - 1);
        }
        this.textBuf += text.replace(/\r\n/g, '\n');
      }
      if (boundary < this.byteBuf.length) {
        LogSafe.w(TAG, 'finish: dropped %{public}d incomplete trailing byte(s)',
          this.byteBuf.length - boundary);
      }
      this.byteBuf = new Uint8Array(0);
    }
    if (this.textBuf.trim().length > 0) {
      let ev: SseEvent | null = parseFrame(this.textBuf);
      if (ev !== null && this.accept(ev)) {
        events.push(ev);
      }
    }
    LogSafe.d(TAG, 'finish: %{public}d event(s)', events.length);
    this.reset();
    return events;
  }

  /** Reset internal buffers for a new stream. */
  reset(): void {
    this.byteBuf = new Uint8Array(0);
    this.textBuf = '';
  }
}

/** Run terminal set (mirrors model/Run.ets TERMINAL and the selftest). */
export function isTerminalSseEvent(ev: SseEvent): boolean {
  return ev.event === 'run.completed' || ev.event === 'run.failed' ||
    ev.event === 'run.cancelled' || ev.event === 'run.interrupted';
}
