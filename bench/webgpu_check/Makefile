# webgpu_check — WebGPU の PC の実装（Dawn）を Flix から WebGpu の interface を通して確かめる門の入口。
#   make run      … ウィンドウなしの門（公開の入口と誤りの道・上限・三角形と面の向き・readRgba・式の行・firstInstance の 20,000 本・device の取り直し）
#   make window   … GLFW のウィンドウの門（描き先の形・120 コマ・present の前の読み戻し・Retina の倍率・大きさの作り直し）
#   make two      … ウィンドウなしの門を 2 プロセス同時に（空の置き場から 3 回・書き出し済みの置き場で 1 回）
#   make check    … 型検査だけ
# 先にエンジンの root で make sync-engine-full（lib の engine は fpkg）。

.PHONY: run window two check

run:
	../../bin/flix run

window:
	WEBGPU_CHECK=window ../../bin/flix run

# WhyNot: flix run を 2 つ並べるだけにしない — コンパイルの長さが揃わず、device を開く時刻が数秒ずれて取り合いにならない。
# jar を 1 本作って 2 つ起こし、device を開く直前で同じファイルを待たせてから一斉に放す。
# WhyNot: 既定の置き場（~/Library/Caches）を使わない — 空の時を作るには消すことになり、動いている別のゲームのネイティブまで消える。
JAR := artifact/webgpu_check.jar
# WhyNot: LWJGL の置き場を既定のままにしない — fat jar から起こすと LWJGL が版を読めず、作業フォルダの .lwjgl へ書き出す。
JAVA_OPTS := -Dorg.lwjgl.system.SharedLibraryExtractDirectory=$(CURDIR)/build/lwjgl
two:
	@mkdir -p build
	../../bin/flix build-fatjar
	@for round in empty1 empty2 empty3 filled; do \
		case $$round in empty*) dir=$$(mktemp -d "$$PWD/build/natives.XXXXXX");; esac; \
		gate="$$PWD/build/two-$$round.go"; rm -f "$$gate"; \
		WEBGPU_NATIVE_DIR="$$dir" WEBGPU_BARRIER="$$gate" java $(JAVA_OPTS) -jar $(JAR) > build/two-$$round-a.log 2>&1 & a=$$!; \
		WEBGPU_NATIVE_DIR="$$dir" WEBGPU_BARRIER="$$gate" java $(JAVA_OPTS) -jar $(JAR) > build/two-$$round-b.log 2>&1 & b=$$!; \
		sleep 2; touch "$$gate"; \
		wait $$a; ra=$$?; wait $$b; rb=$$?; \
		if [ $$ra -eq 0 ] && [ $$rb -eq 0 ]; then echo "RESULT two-process-$$round OK exit=$$ra,$$rb"; \
		else echo "RESULT two-process-$$round NG exit=$$ra,$$rb (build/two-$$round-*.log)"; exit 1; fi; \
	done

check:
	../../bin/flix check
