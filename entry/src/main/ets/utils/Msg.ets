import { resourceManager } from '@kit.LocalizationKit';

/**
 * utils/Msg.ets —— 运行时文案取用（S11 i18n 收口）
 * EN: runtime string lookup. All user-facing text lives in
 *     resources/{base,zh_CN,en_US}/element/string.json — the same table the
 *     declarative UI already uses via $r(). View-model / net layers cannot use
 *     $r(), so they go through this facade instead of hardcoding Chinese.
 *
 * 用法：入口 Ability 启动时 Msg.init(this.context.resourceManager)；
 *      其余位置一律 Msg.t('some__key')。
 * 回退策略：未初始化或 key 不存在时返回 key 本身（可见即缺陷，便于自测发现）。
 */
let RM: resourceManager.ResourceManager | null = null;

export class Msg {
  static init(rm: resourceManager.ResourceManager): void {
    RM = rm;
  }

  /** 按 key 取当前语言文案。 */
  static t(key: string): string {
    if (RM === null) {
      return key;
    }
    try {
      return RM.getStringByNameSync(key);
    } catch (e) {
      return key;
    }
  }
}
