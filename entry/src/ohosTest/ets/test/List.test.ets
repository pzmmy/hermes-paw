import { describe, it, expect, TestType, Size, Level } from '@ohos/hypium';
import { firstMeaningfulLine, deriveLocalTitle, fallbackTitle, LOCAL_TITLE_MAX_CHARS } from '../../../main/ets/viewmodel/SessionMerge';
import { nextPollInterval, POLL_START_MS, POLL_MAX_MS } from '../../../main/ets/viewmodel/stream/PollPolicy';
import { slashName, slashArg, findCommand, isKnownUnmapped, SLASH_COMMANDS } from '../../../main/ets/net/SlashCommands';

/**
 * hermes-paw 设备单元测试（hypium，跑在真机/模拟器上）
 *
 * 选测对象的原则：**纯函数、无 UI、无网络**。
 * 这些函数承载的是「和 Hermes 网关对齐」的契约（标题派生、轮询节拍、斜杠命令解析），
 * 一旦漂移，表现为「会话标题不跟随服务端」「长任务假死」「命令被当普通消息发出去」，
 * 都是真机上很难一眼看出的问题，所以用固定用例钉住。
 */
export default function testsuite() {

  // ---------------- 标题派生（与网关 derive_title 对齐） ----------------
  describe('SessionMerge_LocalTitle', () => {

    it('first_line_takes_first_meaningful_line', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(firstMeaningfulLine('\n\n  第一行  \n第二行')).assertEqual('第一行');
    });

    it('first_line_empty_input_is_empty', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(firstMeaningfulLine('')).assertEqual('');
      expect(firstMeaningfulLine('   \n\t\n')).assertEqual('');
    });

    it('derive_collapses_spaces', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(deriveLocalTitle('hello   world')).assertEqual('hello world');
    });

    it('derive_short_text_passthrough', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(deriveLocalTitle('e2e ok')).assertEqual('e2e ok');
    });

    it('derive_long_text_truncates_with_ellipsis', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      // 60 个 "ab " → 必然超 48
      let longText: string = '';
      for (let i = 0; i < 20; i++) {
        longText = longText + 'ab ';
      }
      let t: string = deriveLocalTitle(longText);
      expect(t.endsWith('…')).assertTrue();
      expect(t.length <= LOCAL_TITLE_MAX_CHARS + 1).assertTrue();
    });

    it('derive_empty_input_is_empty', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(deriveLocalTitle('')).assertEqual('');
      expect(deriveLocalTitle('   ')).assertEqual('');
    });
  });

  // ---------------- 空标题兜底（S10a） ----------------
  describe('SessionMerge_FallbackTitle', () => {

    it('empty_title_uses_id_tail6', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(fallbackTitle('', 'api_1795066182_671dd197')).assertEqual('未命名 · 1dd197');
    });

    it('blank_title_treated_as_empty', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(fallbackTitle('   ', 'abcdef123456')).assertEqual('未命名 · 123456');
    });

    it('non_empty_title_passthrough', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(fallbackTitle('e2e ok', 'whatever')).assertEqual('e2e ok');
    });

    it('short_id_does_not_overflow', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(fallbackTitle('', 'abc')).assertEqual('未命名 · abc');
    });
  });

  // ---------------- 轮询节拍（长任务不假死的关键） ----------------
  describe('PollPolicy_Interval', () => {

    it('start_interval_is_2s', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(POLL_START_MS).assertEqual(2000);
      expect(nextPollInterval(POLL_START_MS, 0)).assertEqual(2000);
    });

    it('doubles_only_after_threshold', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(nextPollInterval(2000, 2)).assertEqual(2000);
      expect(nextPollInterval(2000, 3)).assertEqual(4000);
    });

    it('caps_at_max', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(POLL_MAX_MS).assertEqual(5000);
      expect(nextPollInterval(4000, 3)).assertEqual(5000);
      expect(nextPollInterval(5000, 10)).assertEqual(5000);
    });
  });

  // ---------------- 斜杠命令解析（命令被误当消息发出去就靠这层挡） ----------------
  describe('SlashCommands_Parse', () => {

    it('name_extracts_command', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(slashName('/resume 2')).assertEqual('/resume');
      expect(slashName('  /stop  ')).assertEqual('/stop');
    });

    it('name_ignores_non_slash_input', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(slashName('hello')).assertEqual('');
      expect(slashName('')).assertEqual('');
    });

    it('arg_extracts_remainder', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(slashArg('/title 我的会话')).assertEqual('我的会话');
      expect(slashArg('/new')).assertEqual('');
    });

    it('known_command_is_found', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(SLASH_COMMANDS.length).assertEqual(5);
      expect(findCommand('/stop') != null).assertTrue();
      expect(findCommand('/nope') == null).assertTrue();
    });

    it('unmapped_commands_are_declared', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, () => {
      expect(isKnownUnmapped('/undo')).assertTrue();
      expect(isKnownUnmapped('/sessions')).assertTrue();
      // 已映射的命令不能被误判为「不支持」
      expect(isKnownUnmapped('/resume')).assertFalse();
    });
  });
}
