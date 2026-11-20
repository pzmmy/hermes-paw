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
# ArkTS 设备单测（hypium，跑在真机/模拟器上，需 DevEco Studio）：
#   1) DevEco 里 Run 'entry > ohosTest'，或 CLI 打测试包：
#        hvigorw --mode module -p module=entry@ohosTest -p product=default assembleHap
#   2) HDC=<hdc> TARGET=<ip:port> bash tools/ohostest.sh
#   用例在 entry/src/ohosTest/ets/test/List.test.ets（当前 18 个）

PYTHON ?= python3

.PHONY: help test lint scan export l2 clean

help:
	@echo "make test    # 全部静态自测（无设备依赖）"
	@echo "make lint    # arkts-lint"
	@echo "make scan    # 零凭据 / 零内网 IP 扫描"
	@echo "make export  # 生成开源导出包到 OUT=<dir>（默认 ./dist/opensource）"
	@echo "make l2      # L2 门（需 API_SERVER_KEY，无 key 自动 SKIP）"

# 全部静态自测：逐个跑 tools/*selftest*.py，任一失败即整体失败
test:
	@fail=0; \
	for t in tools/*selftest*.py; do \
	  case "$$t" in *testdata*) continue;; esac; \
	  name=$$(basename "$$t"); \
	  if out=$$($(PYTHON) "$$t" 2>&1); then \
	    n=$$(printf '%s\n' "$$out" | grep -cE '^(PASS|OK)'); \
	    echo "PASS  $$name  ($$n 条)"; \
	  else \
	    echo "FAIL  $$name"; printf '%s\n' "$$out" | grep -E '^FAIL' | head -5; fail=$$((fail+1)); \
	  fi; \
	done; \
	echo "----"; \
	echo "自测失败组数: $$fail"; \
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
