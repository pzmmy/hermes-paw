# HermesPaw — 工具链入口
#
# 面向外部贡献者的三条命令：
#   make test   —— 跑全部静态自测（不需要设备、不需要网关）
#   make scan   —— 零凭据 / 零内网 IP 扫描（push 前必跑）
#   make export —— 生成开源导出包（排除内部材料后再自检一遍）
#
# L2 门（对接真实网关，需 API_SERVER_KEY）：
#   make l2     —— arkts-lint / api-selftest / s2 / s3 / s15 / slash
#                  无 key 时需要网关的两项自动 SKIP（rc=77），不算失败。
#
# 轮询回归（真机 + 可达网关；CI 不跑，需要设备）：
#   HDC="<hdc路径>" TARGET=<ip:port> make poll-verify
#   发一条会长回答的消息，抓 28s hilog，校验 2s -> 4s -> 5s 自适应曲线。

# ArkTS 设备单测（hypium，跑在真机/模拟器上，需 DevEco Studio）：
#   1) DevEco 里 Run 'entry > ohosTest'，或 CLI 打测试包：
#        hvigorw --mode module -p module=entry@ohosTest -p product=default assembleHap
#   2) HDC=<hdc> TARGET=<ip:port> bash tools/ohostest.sh
#   用例在 entry/src/ohosTest/ets/test/List.test.ets（当前 18 个）

PYTHON ?= python3

.PHONY: help test lint scan export l2 clean poll-verify compile

help:
	@echo "make test    # 全部静态自测（无设备依赖）"
	@echo "make lint    # arkts-lint"
	@echo "make compile # 真编译（本机 Windows/DevEco；改 .ets 后必跑，否则 lint 看不到类型错）"
	@echo "make scan    # 零凭据 / 零内网 IP 扫描"
	@echo "make export  # 生成开源导出包到 OUT=<dir>（默认 ./dist/opensource）"
	@echo "make l2      # L2 门（需 API_SERVER_KEY，无 key 自动 SKIP）"
	@echo "make poll-verify HDC=<hdc> TARGET=<ip:port>  # 轮询回归（需真机+网关）"

# 静态自测 + 网关自测：
#   - 逐个跑 tools/*selftest*.py
#   - 退出码 0   → PASS
#   - 退出码 77  → SKIP（需网关 API_SERVER_KEY 的用例；与 run-l2.sh 同一约定，"未测"≠"失败"）
#   - 其他非 0   → FAIL
test:
	@fail=0; skip=0; \
	for t in tools/*selftest*.py; do \
	  case "$$t" in *testdata*) continue;; esac; \
	  name=$$(basename "$$t"); \
	  out=$$($(PYTHON) "$$t" 2>&1); rc=$$?; \
	  if [ $$rc -eq 0 ]; then \
	    n=$$(printf '%s\n' "$$out" | grep -cE '^(PASS|OK)'); \
	    echo "PASS  $$name  ($$n 条)"; \
	  elif [ $$rc -eq 77 ]; then \
	    echo "SKIP  $$name  (需网关 API_SERVER_KEY，本环境未测)"; skip=$$((skip+1)); \
	  else \
	    echo "FAIL  $$name  (rc=$$rc)"; printf '%s\n' "$$out" | tail -25 | sed 's/^/      /'; fail=$$((fail+1)); \
	  fi; \
	done; \
	echo "----"; \
	echo "自测失败组数: $$fail（跳过 $$skip 组：需网关环境）"; \
	[ "$$fail" -eq 0 ]

lint:
	$(PYTHON) tools/arkts-lint.py

# S3 验收 c：push 前零凭据、零内网 IP 扫描（tools/secret-scan.py，扫 git 跟踪文件）
scan:
	$(PYTHON) tools/secret-scan.py

OUT ?= dist/opensource
export:
	bash tools/opensource-export.sh $(OUT)

l2:
	bash tools/run-l2.sh

clean:
	rm -rf dist

# 轮询回归：断言自适应拍距曲线（需要真机）
poll-verify:
	@HDC="$(HDC)" TARGET="$(TARGET)" bash tools/poll-verify.sh

# ── 真编译门禁（2026-11-26）───────────────────────────────────────────────
# 为什么需要它：arkts-lint 与所有静态断言都看不到 ArkTS 的类型/资源错误。
# 实证——加 40 行代码，lint 51 文件 0 findings、resilience-selftest 23 项全绿，
# 真编译却报 arkts-no-structural-typing；另有一次 $r('app.color.primary')
# 引用了不存在的资源，同样只有编译器能发现。
#
# 为什么不在 CI：ArkTS 的 Linux 侧编译要 OpenHarmony SDK，而本项目用了
# @kit.ScanKit / @kit.CoreSpeechKit（华为专有），公开 SDK 无声明；用 stub 兜
# 会造出新的「假绿」（stub 写对了、真签名错了）。所以这条只在本机跑。
#
# 退出码：0 = 编译通过；77 = 本机无 Windows 工程/DevEco（跳过）；其他 = 编译失败。
# 改完 .ets 必须跑一次，再 commit。
WIN_PAW ?= /mnt/c/Users/12442/WorkBuddy/2026-11-15-19-24-25/hermes-paw
WIN_BUILD_DIR ?= /mnt/c/Users/12442
compile:
	@if [ ! -d "$(WIN_PAW)" ] || ! command -v cmd.exe >/dev/null 2>&1; then \
	  echo "SKIP  compile  (本机没有 Windows 工程或 cmd.exe；这是本地专属门禁)"; exit 77; \
	fi; \
	rsync -a --delete entry/src/main/ets/ "$(WIN_PAW)/entry/src/main/ets/" || exit 1; \
	rsync -a --delete entry/src/main/resources/ "$(WIN_PAW)/entry/src/main/resources/" || exit 1; \
	l=$$(find entry/src/main/ets -name '*.ets' | wc -l); \
	w=$$(find "$(WIN_PAW)/entry/src/main/ets" -name '*.ets' | wc -l); \
	if [ "$$l" != "$$w" ]; then \
	  echo "FAIL  compile  ets 数不一致：本机 $$l / Windows $$w（rsync 没同步干净）"; exit 1; \
	fi; \
	out=$$(cd "$(WIN_BUILD_DIR)" && cmd.exe /c build-paw.bat 2>&1 | tr -d '\r'); \
	if printf '%s' "$$out" | grep -q 'BUILD_EXITCODE=0'; then \
	  t=$$(printf '%s' "$$out" | grep -o 'CompileArkTS[^ ]* after [0-9a-z ]*' | head -1); \
	  echo "PASS  compile  ($$l 个 ets；$${t:-CompileArkTS ok})"; \
	else \
	  echo "FAIL  compile"; \
	  printf '%s\n' "$$out" | grep -E 'ERROR|Error Message|BUILD_EXITCODE|FAILED' | head -20 | sed 's/^/      /'; \
	  exit 1; \
	fi
