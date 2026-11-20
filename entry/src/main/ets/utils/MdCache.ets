// =====================================================================
// utils/MdCache.ets — render-side cache for model/Markdown parsing
// (design v1.6 §R12 first slice, S10a).
//
// Problem it fixes: ChatPage.mdView() re-parsed the FULL assistant text on
// every build (parseMarkdownBlocks is O(n)); while streaming, streamText
// changes per chunk, so one 3000-char answer was parsed hundreds of times
// during typing (overall O(n²)) and dropped frames.
//
// Three rules (all mandatory — see TASK paw-S10a):
//   1. cache key = callerKey + '|' + text.length  → same length is a HIT,
//      no parsing at all (streaming a chunk that does not change length
//      costs nothing).
//   2. LRU capacity 8 — not an unbounded Map (would grow with the session);
//      8 covers the bubbles visible while scrolling a personal chat.
//   3. throttle 500ms — if the text length under the same callerKey changed
//      within 500ms of the last parse, return the PREVIOUS blocks instead of
//      re-parsing (streaming lags at most 500ms, frame rate wins). Past
//      500ms the text is parsed again.
//
// The parser semantics live in model/Markdown.ets and are NOT touched here.
// =====================================================================
import { MdBlock, parseMarkdownBlocks } from '../model/Markdown';

/** Hard cap of cached callers (rule 2). */
const MD_CACHE_CAP: number = 8;
/** Minimum interval between two parses of the same caller key (rule 3). */
const MD_THROTTLE_MS: number = 500;

/** One cached parse. `key` is the full cache key (caller key + length). */
interface MdCacheEntry {
  key: string; // callerKey + '|' + String(text.length)
  callerKey: string; // stable per-bubble identity (caller key, no length)
  blocks: MdBlock[]; // parsed blocks
  parsedAt: number; // Date.now() of the last real parse (throttle clock)
  usedAt: number; // Date.now() of the last get() (LRU clock)
}

export class MdCache {
  /** Aging list; length never exceeds MD_CACHE_CAP after a get(). */
  private entries: MdCacheEntry[] = [];

  /** Cache lookup. Hit → cached blocks. Miss → parse, store, return.
   *  A miss on the full key but a hit on the caller key with a fresh
   *  parse (< MD_THROTTLE_MS) returns the stale blocks untouched, so the
   *  throttle clock keeps the original parse time. */
  get(key: string, text: string): MdBlock[] {
    const full: string = key + '|' + String(text.length);
    const now: number = Date.now();
    const hit: number = this.indexOfKey(full);
    if (hit >= 0) {
      this.entries[hit].usedAt = now;
      return this.entries[hit].blocks;
    }
    // Miss on the exact key: same caller, changed length?
    const prev: number = this.indexOfCaller(key);
    if (prev >= 0) {
      const old: MdCacheEntry = this.entries[prev];
      old.usedAt = now;
      if (now - old.parsedAt < MD_THROTTLE_MS) {
        // rule 3: still inside the throttle window → serve previous blocks.
        return old.blocks;
      }
      // past the window → re-parse and swap the entry in place.
      const blocks: MdBlock[] = parseMarkdownBlocks(text);
      this.entries.splice(prev, 1);
      this.insert(full, key, blocks, now);
      return blocks;
    }
    const fresh: MdBlock[] = parseMarkdownBlocks(text);
    this.insert(full, key, fresh, now);
    return fresh;
  }

  /** Drop everything (session switch / new session / message delete).
   *  Without this, blocks from the old conversation would leak into the
   *  new one whenever a createdAt key collides. */
  clear(): void {
    this.entries = [];
  }

  private indexOfKey(full: string): number {
    for (let i: number = 0; i < this.entries.length; i++) {
      if (this.entries[i].key === full) {
        return i;
      }
    }
    return -1;
  }

  private indexOfCaller(callerKey: string): number {
    for (let i: number = 0; i < this.entries.length; i++) {
      if (this.entries[i].callerKey === callerKey) {
        return i;
      }
    }
    return -1;
  }

  /** Append a new entry and evict the least recently used one past the cap. */
  private insert(key: string, callerKey: string, blocks: MdBlock[], now: number): void {
    const entry: MdCacheEntry = {
      key: key,
      callerKey: callerKey,
      blocks: blocks,
      parsedAt: now,
      usedAt: now
    };
    this.entries.push(entry);
    while (this.entries.length > MD_CACHE_CAP) {
      let lru: number = 0;
      for (let i: number = 1; i < this.entries.length; i++) {
        if (this.entries[i].usedAt < this.entries[lru].usedAt) {
          lru = i;
        }
      }
      this.entries.splice(lru, 1);
    }
  }
}