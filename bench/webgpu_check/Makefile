# webgpu_check — WebGPU の PC の実装（Dawn）を Flix から WebGpu の interface を通して確かめる門の入口。
#   make run      … ウィンドウなしの門（上限・三角形と面の向き・readRgba・式の行・firstInstance の 20,000 本・device の取り直し）
#   make window   … GLFW のウィンドウの門（描き先の形・120 コマ・present の前の読み戻し・Retina の倍率・大きさの作り直し）
#   make two      … ウィンドウなしの門を 2 プロセス同時に（ネイティブの置き場が空の時と、書き出し済みの時の 2 回）
#   make check    … 型検査だけ
# 先にエンジンの root で make sync-engine-full（lib の engine は fpkg）。

.PHONY: run window two check

run:
	../../bin/flix run

window:
	WEBGPU_CHECK=window ../../bin/flix run

# WhyNot: 置き場が空の時だけで済ませない — 書き出しの最中にもう 1 つが読む時と、書き出し済みを 2 つが同時に開く時は別の道。
# WhyNot: 既定の置き場（~/Library/Caches）を使わない — 空の時を作るには消すことになり、動いている別のゲームのネイティブまで消える。
two:
	@mkdir -p build
	../../bin/flix build
	@dir=$$(mktemp -d build/natives.XXXXXX); \
	for round in empty filled; do \
		WEBGPU_NATIVE_DIR="$$PWD/$$dir" ../../bin/flix run > build/two-$$round-a.log 2>&1 & a=$$!; \
		WEBGPU_NATIVE_DIR="$$PWD/$$dir" ../../bin/flix run > build/two-$$round-b.log 2>&1 & b=$$!; \
		wait $$a; ra=$$?; wait $$b; rb=$$?; \
		if [ $$ra -eq 0 ] && [ $$rb -eq 0 ]; then echo "RESULT two-process-$$round OK exit=$$ra,$$rb"; \
		else echo "RESULT two-process-$$round NG exit=$$ra,$$rb (build/two-$$round-*.log)"; exit 1; fi; \
	done

check:
	../../bin/flix check
