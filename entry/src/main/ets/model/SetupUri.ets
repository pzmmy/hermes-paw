// =====================================================================
// model/SetupUri.ets — QR setup URI parse (S1, m2-qr-design v0.3.2)
//
// Payload contract (tools/hermes-paw-qr build_uri, 2026-10-31):
//   hermespaw://setup/1?n=<name>&a=<host:port>[,...]&k=<key>
//     &pf=<profile>&t=lan&min_app=<ver>
// Encoding: n= / k= / pf= are percent-encoded (urllib quote), a= keeps
//   ':' and ',' raw (safe=':,'). The parser percent-decodes all values
//   (ASCII-safe values pass through unchanged).
// Rules:
//   - scheme hermespaw://, path setup/1 (other versions rejected)
//   - n / a / k required; a splits into ordered hosts, trimmed, deduped
//   - pf: absent -> '', 'default' -> '' (normPf)
//   - t must be 'lan' (the only v1 transport; others rejected)
//   - min_app optional; absent = no check (caller runs checkMinApp)
//   - unknown params ignored (forward-compat with future fields)
// Pure string logic; never throws; no key material in logs.
// =====================================================================
import { Msg } from '../utils/Msg';
import { util } from '@kit.ArkTS';

/** Decoded setup URI (one QR / one pasted string). */
export class SetupUri {
  /** display name (n=, decoded) */
  name: string = '';
  /** candidate hosts in payload order (a=, comma-split, trimmed, deduped) */
  hosts: string[] = [];
  /** profile key (k=); caller stores via TokenVault, never logs it */
  key: string = '';
  /** profile prefix, normalized ('' = no /p/ prefix) */
  pf: string = '';
  /** transport (t=; only 'lan' accepted) */
  transport: string = '';
  /** minimum app version (min_app=; '' = absent, no check) */
  minApp: string = '';
}

/** Parse outcome: uri on success, else a user-facing error hint. */
export class SetupParseResult {
  uri: SetupUri | null = null;
  /** '' on success; otherwise the user-facing failure reason */
  error: string = '';
}

const SCHEME: string = 'hermespaw://';
const PATH_PREFIX: string = 'setup/';
const SUPPORTED_VERSION: string = '1';

/**
 * Percent-decode a query value (UTF-8). Values without '%' pass
 * through untouched. A malformed escape returns the input as-is
 * (never throw on user-supplied strings).
 */
function pctDecode(v: string): string {
  if (v.indexOf('%') < 0) {
    return v;
  }
  let bytes: number[] = [];
  let i: number = 0;
  while (i < v.length) {
    if (v.charAt(i) === '%' && i + 2 < v.length) {
      let n: number = parseInt(v.substring(i + 1, i + 3), 16);
      if (Number.isNaN(n)) {
        return v;
      }
      bytes.push(n);
      i += 3;
    } else {
      bytes.push(v.charCodeAt(i));
      i += 1;
    }
  }
  let u8: Uint8Array = new Uint8Array(bytes.length);
  for (let j: number = 0; j < bytes.length; j++) {
    u8[j] = bytes[j];
  }
  let dec: util.TextDecoder = util.TextDecoder.create('utf-8');
  return dec.decodeToString(u8);
}

/**
 * Parse and validate a setup URI (camera scan / album decode / paste).
 * First occurrence of a repeated param wins.
 */
export function parseSetupUri(raw: string): SetupParseResult {
  let res: SetupParseResult = new SetupParseResult();
  let s: string = raw.trim();
  if (s === '') {
    res.error = Msg.t('m_setup_empty');
    return res;
  }
  if (!s.startsWith(SCHEME)) {
    res.error = Msg.t('m_setup_not_hermespaw');
    return res;
  }
  let rest: string = s.substring(SCHEME.length);
  let q: number = rest.indexOf('?');
  let path: string = q >= 0 ? rest.substring(0, q) : rest;
  let query: string = q >= 0 ? rest.substring(q + 1) : '';
  if (!path.startsWith(PATH_PREFIX)) {
    res.error = Msg.t('m_setup_unknown_path');
    return res;
  }
  let ver: string = path.substring(PATH_PREFIX.length);
  if (ver !== SUPPORTED_VERSION) {
    res.error = Msg.t('m_setup_version_prefix') + ver + Msg.t('m_setup_version_suffix');
    return res;
  }
  let name: string = '';
  let aVal: string = '';
  let key: string = '';
  let pf: string = '';
  let t: string = '';
  let minApp: string = '';
  let seen: string[] = [];
  let parts: string[] = query.split('&');
  for (let i: number = 0; i < parts.length; i++) {
    let kv: string = parts[i];
    if (kv === '') {
      continue;
    }
    let eq: number = kv.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    let k: string = kv.substring(0, eq);
    if (seen.indexOf(k) >= 0) {
      continue; // first occurrence wins
    }
    seen.push(k);
    let v: string = kv.substring(eq + 1);
    if (k === 'n') {
      name = pctDecode(v);
    } else if (k === 'a') {
      // P0-1 修（真机实测 2026-11-18）：服务端脚本按标准把 ':' 编码为 %3A，
      // 原实现唯独漏了 a 的解码，aVal 变成 "192.0.2.10%3A8377" → 探活必败（示例地址取 RFC5737 文档段）。
      // 与 n / k / pf 三个参数保持一致，统一 pctDecode。
      aVal = pctDecode(v);
    } else if (k === 'k') {
      key = pctDecode(v);
    } else if (k === 'pf') {
      pf = pctDecode(v);
    } else if (k === 't') {
      t = v;
    } else if (k === 'min_app') {
      minApp = v;
    }
    // unknown params: ignored
  }
  if (name === '') {
    res.error = Msg.t('m_setup_missing_n');
    return res;
  }
  if (aVal === '') {
    res.error = Msg.t('m_setup_missing_a');
    return res;
  }
  if (key === '') {
    res.error = Msg.t('m_setup_missing_k');
    return res;
  }
  if (t !== 'lan') {
    res.error = Msg.t('m_setup_bad_transport') + (t === '' ? Msg.t('m_setup_blank') : t);
    return res;
  }
  let hosts: string[] = [];
  let hs: string[] = aVal.split(',');
  for (let i: number = 0; i < hs.length; i++) {
    // P0-1 兜底解码：兼容「整串未编码但单个 host 被编码」与「整串编码」两种
    // 历史串——整串已在上方解码，这里对无 '%' 的 host 是恒等操作（pctDecode 首行短路）。
    let h: string = pctDecode(hs[i].trim());
    if (h !== '' && hosts.indexOf(h) < 0) {
      hosts.push(h);
    }
  }
  if (hosts.length === 0) {
    res.error = Msg.t('m_setup_addr_blank');
    return res;
  }
  if (pf === 'default') {
    pf = '';
  }
  let u: SetupUri = new SetupUri();
  u.name = name;
  u.hosts = hosts;
  u.key = key;
  u.pf = pf;
  u.transport = t;
  u.minApp = minApp;
  res.uri = u;
  return res;
}

/**
 * Compare dotted versions numerically (0.1.0 style). Returns true when
 * current >= minApp; minApp '' means "no check" (true). Non-numeric
 * segments count as 0.
 */
export function checkMinApp(minApp: string, current: string): boolean {
  if (minApp === '') {
    return true;
  }
  let a: number[] = splitVer(minApp);
  let b: number[] = splitVer(current);
  let n: number = a.length > b.length ? a.length : b.length;
  for (let i: number = 0; i < n; i++) {
    let x: number = i < a.length ? a[i] : 0;
    let y: number = i < b.length ? b[i] : 0;
    if (x > y) {
      return false; // current below the minimum
    }
    if (x < y) {
      return true;
    }
  }
  return true; // equal
}

function splitVer(v: string): number[] {
  let parts: string[] = v.split('.');
  let out: number[] = [];
  for (let i: number = 0; i < parts.length; i++) {
    let n: number = parseInt(parts[i], 10);
    out.push(Number.isNaN(n) ? 0 : n);
  }
  return out;
}
