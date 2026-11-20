// =====================================================================
// store/TokenVault.ets — secure token storage (HUKS AES-256-GCM, M1)
//
// Decision basis (plan §4.5, 2026-10-27): Asset Store Kit from M1
// (wrap with HUKS if the API is available); minAPI = API 12 where the
// ASCK token-storage API is not yet available -> HUKS self-managed CMK
// (this file). M6: upgrade to Asset Store Kit (system-side audit /
// key rotation).
//
// Security properties (plan §4.5 "no preferences plaintext"):
//   - CMK is a HUKS key (TEE-resident, non-exportable), alias
//     hermespaw_cmk_v1 (v2 = M6 rotation)
//   - AES-256-GCM; fresh random 12-byte nonce per encryption, never reused
//   - stored value is an envelope '1:GCM:<b64 nonce>:<b64 ciphertext||16B tag>'
//     in preferences; no plaintext token anywhere on disk
//   - plaintext token exists only in memory after loadToken (caller =
//     ApiClient.configure); never written to logs or diagnostics
//
// batch2-r5 (HUKS hardening): every HUKS / cryptoFramework /
// preferences call site is wrapped in try/catch and rethrown as a
// structured vault error (op name + numeric code only — never
// envelope or token data). ArkTS exposes no public SystemCapability
// query API, so the "minimum version gate" is runtime: isAvailable()
// probes once, and on a device lacking the HUKS syscap every vault op
// fails safe with a clear message instead of an uncaught crash. The 2
// createRandom/generateRandom call sites are themselves try/caught
// (r5); the remaining 2 compile-time syscap availability WARNs are
// compiler-level advisories that try/catch cannot remove (known
// residual since r5, non-blocking).
//
// batch2-r9 (real-device fix): on a fresh install isKeyItemExist
// REJECTS with 12000011 (OH_HUKS_ERR_CODE_ITEM_NOT_EXIST) instead of
// resolving false — documented HUKS behavior. ensureKey() now treats
// that code as "key missing" and falls through to generateKeyItem;
// isAvailable() treats it as "HUKS available, probe key not created
// yet" (a false negative would wrongly block the token path).
// =====================================================================

import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { LogSafe } from '../utils/LogSafe';

const TAG: string = 'TokenVault';

/** HUKS key alias (TEE-resident, non-exportable) */
const KEY_ALIAS: string = 'hermespaw_cmk_v1';
/** OH_HUKS_ERR_CODE_ITEM_NOT_EXIST — isKeyItemExist rejects with this
 * code when the key file does not exist (fresh install) instead of
 * resolving false; treat as "key missing", never as a HUKS failure
 * (batch2-r9, real-device report). */
const HUKS_ERR_ITEM_NOT_EXIST: number = 12000011;
/** preferences store name (holds only ciphertext envelopes) */
const PREF_NAME: string = 'token_vault';
/** preferences key prefix: key = KEY_PREFIX + tokenRef */
const KEY_PREFIX: string = 'vault_';
/** GCM nonce length (bytes, standard 12) */
const NONCE_LEN: number = 12;

/** Base64 alphabet (local implementation; avoids depending on helper wrap behavior) */
const B64_CHARS: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** Uint8Array -> standard base64 (no line wrapping) */
function b64Encode(bytes: Uint8Array): string {
  let out: string = '';
  let len: number = bytes.length;
  let i: number = 0;
  while (i + 3 <= len) {
    let n: number = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += B64_CHARS.charAt((n >> 18) & 63);
    out += B64_CHARS.charAt((n >> 12) & 63);
    out += B64_CHARS.charAt((n >> 6) & 63);
    out += B64_CHARS.charAt(n & 63);
    i += 3;
  }
  let rem: number = len - i;
  if (rem === 1) {
    let n: number = bytes[i] << 16;
    out += B64_CHARS.charAt((n >> 18) & 63);
    out += B64_CHARS.charAt((n >> 12) & 63);
    out += '==';
  } else if (rem === 2) {
    let n: number = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out += B64_CHARS.charAt((n >> 18) & 63);
    out += B64_CHARS.charAt((n >> 12) & 63);
    out += B64_CHARS.charAt((n >> 6) & 63);
    out += '=';
  }
  return out;
}

/** base64 -> Uint8Array (skips padding/whitespace/unknown chars defensively) */
function b64Decode(s: string): Uint8Array {
  let acc: number = 0;
  let bits: number = 0;
  let tmp: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let c: string = s.charAt(i);
    if (c === '=' || c === '\n' || c === '\r' || c === ' ') {
      continue;
    }
    let v: number = B64_CHARS.indexOf(c);
    if (v < 0) {
      continue; // envelope is self-produced; unknown char should not occur
    }
    acc = (acc << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      tmp.push((acc >> bits) & 0xFF);
    }
  }
  let out: Uint8Array = new Uint8Array(tmp.length);
  for (let i = 0; i < tmp.length; i++) {
    out[i] = tmp[i];
  }
  return out;
}

/** cryptographically random bytes (cryptoFramework, never math.random).
 *  generateRandom returns Promise<DataBlob> — await is mandatory
 *  (batch2-r4 P0-04). Both call sites wrapped in try/catch and mapped
 *  to a vault error (batch2-r5). */
async function randomBytes(len: number): Promise<Uint8Array> {
  let rnd: cryptoFramework.Random;
  try {
    rnd = cryptoFramework.createRandom();
  } catch (err) {
    throw vaultErr('createRandom', err as BusinessError);
  }
  let blob: cryptoFramework.DataBlob;
  try {
    blob = await rnd.generateRandom(len);
  } catch (err) {
    throw vaultErr('generateRandom', err as BusinessError);
  }
  return blob.data;
}

/** Best-effort in-memory plaintext scrub (batch2-r2 P1-06: the declared
 *  clearText). TypedArray memory can be copied by the runtime, so this
 *  shortens the plaintext lifetime; it is defense-in-depth, not a
 *  memory-safety guarantee. */
function clearText(bytes: Uint8Array): void {
  for (let i: number = 0; i < bytes.length; i++) {
    bytes[i] = 0;
  }
}

/** Map a low-level failure (HUKS / cryptoFramework / preferences) to a
 * structured, log-safe vault error: op name + numeric code only — never
 * envelope or token data (batch2-r5 HUKS hardening). Every TokenVault
 * caller already wraps its call in try/catch, so this rethrow surfaces
 * as a user-visible hint, never an uncaught crash. */
function vaultErr(op: string, e: BusinessError): Error {
  let code: number = -1;
  if (e !== undefined && typeof e.code === 'number') {
    code = e.code;
  }
  LogSafe.e(TAG, 'vault op failed: %{public}s code=%{public}d', op, code);
  return new Error('vault: ' + op + ' failed (code=' + String(code) + ')');
}

export class TokenVault {
  /** ensure the CMK exists (idempotent) */
  static async ensureKey(): Promise<void> {
    let exists: boolean;
    try {
      exists = await huks.isKeyItemExist(KEY_ALIAS, { properties: [] });
    } catch (err) {
      // Fresh-install behavior (documented): when the key file does
      // not exist, isKeyItemExist rejects with 12000011
      // (OH_HUKS_ERR_CODE_ITEM_NOT_EXIST) instead of resolving false —
      // treat as "missing" and fall through to generateKeyItem
      // (batch2-r9). Any other code = real failure.
      let e = err as BusinessError;
      if (typeof e.code === 'number' && e.code === HUKS_ERR_ITEM_NOT_EXIST) {
        exists = false;
      } else {
        throw vaultErr('isKeyItemExist', e);
      }
    }
    if (exists) {
      return;
    }
    let props: Array<huks.HuksParam> = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE }
    ];
    let options: huks.HuksOptions = { properties: props };
    try {
      await huks.generateKeyItem(KEY_ALIAS, options);
    } catch (err) {
      throw vaultErr('generateKeyItem', err as BusinessError);
    }
    LogSafe.i(TAG, 'CMK created (alias=%{public}s, aes-256-gcm)', KEY_ALIAS);
  }

  /**
   * Encrypt and store (overwrites any previous envelope of the same ref).
   * @param ref tokenRef (typically ServerProfile.id); must be non-empty
   * @param token plaintext token (never persisted, never logged)
   */
  static async saveToken(ctx: common.Context, ref: string, token: string): Promise<void> {
    if (ref === '') {
      throw new Error('vault: empty tokenRef');
    }
    await TokenVault.ensureKey();
    let nonce: Uint8Array = await randomBytes(NONCE_LEN);
    let te: util.TextEncoder = util.TextEncoder.create();
    let plain: Uint8Array = te.encodeInto(token);

    let props: Array<huks.HuksParam> = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce }
    ];
    let options: huks.HuksOptions = { properties: props, inData: plain };
    let session: huks.HuksSessionHandle;
    try {
      session = await huks.initSession(KEY_ALIAS, options);
    } catch (err) {
      // Session never created: abortSession would be invalid. Scrub the
      // plaintext and rethrow as a vault error (batch2-r5).
      clearText(plain);
      throw vaultErr('initSession(encrypt)', err as BusinessError);
    }
    let result: huks.HuksReturnResult;
    let finished: boolean = false;
    try {
      result = await huks.finishSession(session.handle, options);
      finished = true;
    } catch (err) {
      // finally still runs abortSession (session exists, op failed) and
      // scrubs the plaintext (batch2-r5).
      throw vaultErr('finishSession(encrypt)', err as BusinessError);
    } finally {
      // Official HUKS lifecycle: abortSession is failure-path cleanup
      // (any of initSession/updateSession/finishSession erroring); it
      // must NOT run after a successful finishSession (batch2-r2 P1-06).
      if (!finished) {
        huks.abortSession(session.handle, options).catch((err: Error): void => {
          // best-effort cleanup; never log session internals
        });
      }
      clearText(plain);
    }
    if (result.outData === undefined) {
      throw new Error('vault: encrypt produced no output');
    }
    // outData = ciphertext || 16-byte GCM tag (stored together;
    // loadToken splits the trailing 16B AE_TAG before decrypting)
    let envelope: string = '1:GCM:' + b64Encode(nonce) + ':' + b64Encode(result.outData);
    let pref: preferences.Preferences;
    try {
      pref = await preferences.getPreferences(ctx, PREF_NAME);
    } catch (err) {
      throw vaultErr('getPreferences', err as BusinessError);
    }
    try {
      await pref.put(KEY_PREFIX + ref, envelope);
    } catch (err) {
      throw vaultErr('put', err as BusinessError);
    }
    try {
      await pref.flush();
    } catch (err) {
      throw vaultErr('flush', err as BusinessError);
    }
  }

  /**
   * Load and decrypt. Returns '' when no token is stored for ref.
   * Throws on corrupted envelope / decrypt failure (caller shows
   * "re-enter token" guidance; never logs the token itself).
   */
  static async loadToken(ctx: common.Context, ref: string): Promise<string> {
    if (ref === '') {
      return '';
    }
    let pref: preferences.Preferences;
    try {
      pref = await preferences.getPreferences(ctx, PREF_NAME);
    } catch (err) {
      throw vaultErr('getPreferences', err as BusinessError);
    }
    let v: preferences.ValueType;
    try {
      v = await pref.get(KEY_PREFIX + ref, '');
    } catch (err) {
      throw vaultErr('get', err as BusinessError);
    }
    if (v === null || typeof v !== 'string' || (v as string) === '') {
      return '';
    }
    let envelope: string = v as string;
    // envelope: '1:GCM:<b64(nonce)>:<b64(ciphertext||16B tag)>'
    // (stored together; loadToken splits the trailing 16-byte AE_TAG
    // before decrypting — GCM decrypt requires HUKS_TAG_AE_TAG)
    let parts: string[] = envelope.split(':');
    if (parts.length !== 4 || parts[0] !== '1' || parts[1] !== 'GCM') {
      throw new Error('vault: bad envelope format');
    }
    let nonce: Uint8Array = b64Decode(parts[2]);
    if (nonce.length !== NONCE_LEN) {
      throw new Error('vault: bad nonce length');
    }
    // Envelope = ciphertext || 16-byte GCM tag (see saveToken). GCM
    // decryption contract (openharmony docs, huks-encryption-decryption-
    // overview: "AAD is optional, but NONCE and AEAD are mandatory"):
    // inData = ciphertext ONLY, plus HUKS_TAG_AE_TAG = expected 16-byte
    // tag for authentication. Missing AE_TAG makes initSession(decrypt)
    // fail 401 on every device — home E2E 2026-11-02, P0.
    let tagLen: number = 16;
    let blob: Uint8Array = b64Decode(parts[3]);
    if (blob.length < tagLen) {
      throw new Error('vault: ciphertext too short');
    }
    let cipher: Uint8Array = blob.subarray(0, blob.length - tagLen);
    let gcmTag: Uint8Array = blob.subarray(blob.length - tagLen);
    await TokenVault.ensureKey();
    let props: Array<huks.HuksParam> = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce },
      { tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: gcmTag }
    ];
    let options: huks.HuksOptions = { properties: props, inData: cipher };
    let session: huks.HuksSessionHandle;
    try {
      session = await huks.initSession(KEY_ALIAS, options);
    } catch (err) {
      throw vaultErr('initSession(decrypt)', err as BusinessError);
    }
    let result: huks.HuksReturnResult;
    let finished: boolean = false;
    try {
      result = await huks.finishSession(session.handle, options);
      finished = true;
    } catch (err) {
      throw vaultErr('finishSession(decrypt)', err as BusinessError);
    } finally {
      // Official HUKS lifecycle: abortSession is failure-path cleanup
      // (any of initSession/updateSession/finishSession erroring); it
      // must NOT run after a successful finishSession (batch2-r2 P1-06).
      if (!finished) {
        huks.abortSession(session.handle, options).catch((err: Error): void => {
          // best-effort cleanup; never log session internals
        });
      }
    }
    if (result.outData === undefined) {
      throw new Error('vault: decrypt produced no output');
    }
    let td: util.TextDecoder = util.TextDecoder.create('utf-8');
    let token: string = td.decodeToString(result.outData);
    clearText(result.outData);
    return token;
  }

  /** whether a token is stored for ref */
  static async hasToken(ctx: common.Context, ref: string): Promise<boolean> {
    if (ref === '') {
      return false;
    }
    let pref: preferences.Preferences;
    try {
      pref = await preferences.getPreferences(ctx, PREF_NAME);
    } catch (err) {
      throw vaultErr('getPreferences', err as BusinessError);
    }
    let v: preferences.ValueType;
    try {
      v = await pref.get(KEY_PREFIX + ref, '');
    } catch (err) {
      throw vaultErr('get', err as BusinessError);
    }
    return v !== null && typeof v === 'string' && (v as string) !== '';
  }

  /** delete the stored token (profile removal / token reset) */
  static async deleteToken(ctx: common.Context, ref: string): Promise<void> {
    if (ref === '') {
      return;
    }
    let pref: preferences.Preferences;
    try {
      pref = await preferences.getPreferences(ctx, PREF_NAME);
    } catch (err) {
      throw vaultErr('getPreferences', err as BusinessError);
    }
    try {
      await pref.delete(KEY_PREFIX + ref);
    } catch (err) {
      throw vaultErr('delete', err as BusinessError);
    }
    try {
      await pref.flush();
    } catch (err) {
      throw vaultErr('flush', err as BusinessError);
    }
  }

  /**
   * Runtime availability probe — the "minimum version gate"
   * (batch2-r5). ArkTS exposes no public SystemCapability query API, so
   * HUKS presence is probed with a no-op key-existence check: true on
   * HarmonyOS NEXT (HUKS universal), false on a device lacking the
   * syscap. Callers may surface a "安全存储不可用" hint; every vault op
   * already fails safe regardless of the probe result.
   */
  static async isAvailable(): Promise<boolean> {
    try {
      await huks.isKeyItemExist(KEY_ALIAS, { properties: [] });
      return true;
    } catch (err) {
      // 12000011 = probe key not created yet (fresh install): HUKS
      // itself is available — a false negative here would wrongly
      // block the token path (batch2-r9).
      let e = err as BusinessError;
      if (typeof e.code === 'number' && e.code === HUKS_ERR_ITEM_NOT_EXIST) {
        LogSafe.i(TAG, 'probe key absent (fresh install): HUKS available');
        return true;
      }
      LogSafe.w(TAG, 'HUKS unavailable on this device (probe)');
      return false;
    }
  }
}
