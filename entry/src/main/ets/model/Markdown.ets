// model/Markdown.ets
// P4⑦: lightweight, zero-dependency Markdown renderer for assistant text
// (spec §9-7, mirrors iHermes simple_markdown — no third-party lib).
//
// Deliberate NARROW subset:
//   heading (# ## ### …) / image (![alt](url)) / table (| … |) / bold (**…**) / link ([text](url))
// Deliberately NOT supported (avoids a heavy Markdown lib):
//   code fences, ordered/unordered lists, blockquote, inline code, strikethrough.
//
// Pure + stateless: the FULL text is re-parsed on every render, so streaming
// half-content degrades safely — an unclosed ** or an open table row render as
// plain text (no crash, no half-bold). This is what makes it streaming-tolerant.

/** Inline segment of a paragraph: a run of text, optionally bold or a link. */
export interface MdSeg {
  text: string;
  bold: boolean;
  link: string; // non-empty = this segment is a link (text shown, link = url)
}

/** A rendered block: heading | image | table | para. Fields unused by a given
 *  type are zero/empty (level=0, url='', rows=[], segs=[]). */
export interface MdBlock {
  type: string; // 'heading' | 'image' | 'table' | 'para'
  level: number; // heading level 1-6, else 0
  text: string; // heading text, or para full text
  url: string; // image url
  rows: string[][]; // table cells (row of cells)
  segs: MdSeg[]; // para inline segments
}

/** Parse a paragraph into inline segments: bold (**…**) and link ([text](url)).
 *  Unclosed ** or [text](url) render as literal (streaming-safe). O(n). */
export function parseInline(text: string): MdSeg[] {
  let segs: MdSeg[] = [];
  let i: number = 0;
  let buf: string = '';
  let n: number = text.length;
  while (i < n) {
    let ch: string = text.charAt(i);
    // bold: **...**
    if (ch === '*' && i + 1 < n && text.charAt(i + 1) === '*') {
      let close: number = text.indexOf('**', i + 2);
      if (close !== -1) {
        if (buf !== '') {
          segs.push({ text: buf, bold: false, link: '' });
          buf = '';
        }
        segs.push({ text: text.substring(i + 2, close), bold: true, link: '' });
        i = close + 2;
        continue;
      }
    }
    // link: [text](url)
    if (ch === '[') {
      let rb: number = text.indexOf(']', i + 1);
      if (rb !== -1 && rb + 1 < n && text.charAt(rb + 1) === '(') {
        let rp: number = text.indexOf(')', rb + 2);
        if (rp !== -1) {
          if (buf !== '') {
            segs.push({ text: buf, bold: false, link: '' });
            buf = '';
          }
          segs.push({ text: text.substring(i + 1, rb), bold: false, link: text.substring(rb + 2, rp) });
          i = rp + 1;
          continue;
        }
      }
    }
    buf = buf + ch;
    i++;
  }
  if (buf !== '') {
    segs.push({ text: buf, bold: false, link: '' });
  }
  return segs;
}

/** Extract the url from an image line `![alt](url)`, or '' if not a complete image. */
function parseImageUrl(line: string): string {
  if (line.substring(0, 2) !== '![') {
    return '';
  }
  let rb: number = line.indexOf(']');
  if (rb === -1 || rb + 1 >= line.length || line.charAt(rb + 1) !== '(') {
    return '';
  }
  let rp: number = line.indexOf(')', rb + 2);
  if (rp === -1) {
    return '';
  }
  return line.substring(rb + 2, rp).trim();
}

/** Split a table row `| a | b |` into cells ['a','b']. */
function splitTableRow(line: string): string[] {
  let t: string = line.trim();
  if (t.charAt(0) === '|') {
    t = t.substring(1);
  }
  if (t.length > 0 && t.charAt(t.length - 1) === '|') {
    t = t.substring(0, t.length - 1);
  }
  let parts: string[] = t.split('|');
  let cells: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    cells.push(parts[i].trim());
  }
  return cells;
}

/** A separator row: every cell empty or only dashes/colons/spaces, with ≥1 dash. */
function isSeparatorRow(cells: string[]): boolean {
  let anyDash: boolean = false;
  for (let i = 0; i < cells.length; i++) {
    let c: string = cells[i];
    if (c === '') {
      continue;
    }
    let ok: boolean = true;
    for (let j = 0; j < c.length; j++) {
      let cc: string = c.charAt(j);
      if (cc !== '-' && cc !== ':' && cc !== ' ') {
        ok = false;
        break;
      }
    }
    if (!ok) {
      return false;
    }
    if (c.indexOf('-') !== -1) {
      anyDash = true;
    }
  }
  return anyDash;
}

/** Parse the full text into blocks. Line-oriented:
 *  - leading `#` (1-6, followed by space or EOL) = heading
 *  - `![alt](url)` = image
 *  - a line containing `|` = table row (consecutive rows grouped; separator rows skipped)
 *  - a blank line = boundary (flush para + table)
 *  - otherwise = paragraph (consecutive non-blank lines joined by space)
 */
export function parseMarkdownBlocks(text: string): MdBlock[] {
  let blocks: MdBlock[] = [];
  if (text === '') {
    return blocks;
  }
  let lines: string[] = text.split('\n');
  let para: string[] = [];
  let tableBuf: string[][] = [];

  // flush pending paragraph (join lines, parse inline)
  let flushPara = (): void => {
    if (para.length > 0) {
      let joined: string = para.join(' ').trim();
      if (joined !== '') {
        blocks.push({ type: 'para', level: 0, text: joined, url: '', rows: [], segs: parseInline(joined) });
      }
      para = [];
    }
  };
  // flush pending table (copy rows before clearing the buffer)
  let flushTable = (): void => {
    if (tableBuf.length > 0) {
      let rows: string[][] = [];
      for (let i = 0; i < tableBuf.length; i++) {
        rows.push(tableBuf[i]);
      }
      blocks.push({ type: 'table', level: 0, text: '', url: '', rows: rows, segs: [] });
      tableBuf = [];
    }
  };

  for (let li = 0; li < lines.length; li++) {
    let trimmed: string = lines[li].trim();
    // heading: # / ## / … (1-6 hashes, then space or EOL)
    if (trimmed.charAt(0) === '#') {
      let level: number = 0;
      while (level < trimmed.length && trimmed.charAt(level) === '#') {
        level++;
      }
      if (level >= 1 && level <= 6 && (level === trimmed.length || trimmed.charAt(level) === ' ')) {
        flushPara();
        flushTable();
        let htext: string = (level < trimmed.length) ? trimmed.substring(level).trim() : '';
        blocks.push({ type: 'heading', level: level, text: htext, url: '', rows: [], segs: [] });
        continue;
      }
    }
    // image: ![alt](url)
    if (trimmed.substring(0, 2) === '![') {
      let url: string = parseImageUrl(trimmed);
      if (url !== '') {
        flushPara();
        flushTable();
        blocks.push({ type: 'image', level: 0, text: '', url: url, rows: [], segs: [] });
        continue;
      }
    }
    // table row: contains |
    if (trimmed.indexOf('|') !== -1) {
      flushPara();
      let cells: string[] = splitTableRow(trimmed);
      if (isSeparatorRow(cells)) {
        continue; // skip |---|---| separator row
      }
      tableBuf.push(cells);
      continue;
    }
    // blank line: boundary
    if (trimmed === '') {
      flushPara();
      flushTable();
      continue;
    }
    // plain line: ends any open table group, joins the paragraph
    flushTable();
    para.push(trimmed);
  }
  flushPara();
  flushTable();
  return blocks;
}
