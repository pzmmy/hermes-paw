/*
 * LogSafe — 统一日志出口（S4b / R13 安全闸门）
 * EN: The only logging facade allowed in this repo; masks secrets and long identifiers.
 *
 * 约定（强制）：新增日志必须走 LogSafe，裸 hilog 由 tools/logsafe-selftest.py 拦截
 * （裸 hilog 调用计数必须为 0）。本文件是唯一允许 import hilog 的地方。
 * 本文件不引用 TokenVault / HUKS / 任何业务模块，只做纯字符串脱敏。
 *
 * mask 规则（按顺序执行，纯函数、无 IO、无状态、不抛异常）：
 *   1) key|token|authorization|password|secret 键值对 —— 键名与分隔符保留，值 -> ***
 *      （并吞掉可选的 Bearer/Basic/Digest/Token scheme，避免 scheme 之后残留明文）
 *   2) URL 的 /p/<profile>/ 段 —— host 与 /p/ 保留，profile 段 -> ***
 *   3) 整体形如 [A-Za-z0-9_-]{32,} 的 token —— 前4位...(len=原长度)
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const RE_KV: RegExp =
  new RegExp("\\b(key|token|authorization|password|secret)(\\s*[=:]\\s*)((?:Bearer|Basic|Digest|Token)\\s+)?([^\\s&,\"']+)", "gi");
const RE_PROFILE: RegExp = new RegExp("(https?://[^/\\s]+)/p/([^/\\s]+)", "g");
const RE_TOKEN: RegExp = new RegExp("^[A-Za-z0-9_-]{32,}$");

export class LogSafe {
  static readonly DOMAIN: number = 0xFF00;

  static d(tag: string, fmt: string, ...args: (string | number)[]): void {
    const safe: (string | number)[] = LogSafe.safeArgs(args);
    hilog.debug(LogSafe.DOMAIN, tag, fmt, ...safe);
  }

  static i(tag: string, fmt: string, ...args: (string | number)[]): void {
    const safe: (string | number)[] = LogSafe.safeArgs(args);
    hilog.info(LogSafe.DOMAIN, tag, fmt, ...safe);
  }

  static w(tag: string, fmt: string, ...args: (string | number)[]): void {
    const safe: (string | number)[] = LogSafe.safeArgs(args);
    hilog.warn(LogSafe.DOMAIN, tag, fmt, ...safe);
  }

  static e(tag: string, fmt: string, ...args: (string | number)[]): void {
    const safe: (string | number)[] = LogSafe.safeArgs(args);
    hilog.error(LogSafe.DOMAIN, tag, fmt, ...safe);
  }

  /** string 实参先 mask，number 原样；fmt 本体不掩码（调用方只放常量格式串）。 */
  private static safeArgs(args: (string | number)[]): (string | number)[] {
    const out: (string | number)[] = [];
    for (let idx: number = 0; idx < args.length; idx++) {
      const item: string | number = args[idx];
      if (typeof item === 'string') {
        out.push(LogSafe.mask(item));
      } else {
        out.push(item);
      }
    }
    return out;
  }

  /** 规则1：键值对的值掩码；键名与分隔符（含中间空白）原样保留。
   *  用 $1$2 保留键名+分隔符，值（含可选 scheme）整体丢弃 -> 无回调、无 any。 */
  private static maskKv(src: string): string {
    return src.replace(RE_KV, '$1$2***');
  }

  /** 规则2：/p/<profile>/ 中的 profile 段掩码，host 与后续 path 保留。 */
  private static maskProfile(src: string): string {
    return src.replace(RE_PROFILE, '$1/p/***');
  }

  /** 规则3：整串即一个长 token 时只留前4位与长度。 */
  private static maskWholeToken(src: string): string {
    if (RE_TOKEN.test(src)) {
      return src.substring(0, 4) + '...(len=' + src.length.toString() + ')';
    }
    return src;
  }

  /** 纯函数脱敏。空串进空串出；任何异常都吞掉并返回空串（日志路径不允许抛）。 */
  static mask(v: string): string {
    try {
      if (v.length === 0) {
        return '';
      }
      const step1: string = LogSafe.maskKv(v);
      const step2: string = LogSafe.maskProfile(step1);
      return LogSafe.maskWholeToken(step2);
    } catch (err) {
      return '';
    }
  }
}