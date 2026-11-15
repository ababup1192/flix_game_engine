# gl_parity — GL 描画と SoftRaster 描画の突き合わせ harness の入口。
#   make run   … 隠しウィンドウで GL を焼き、SoftRaster と画素比較する（不一致で exit 1）
#   make webgpu … V1 の scene を WebGPU の描き手で流して SoftRaster と GL に比べる（make webgpu-v1-check の一部）
#   make wgsl-rows … ShaderDoc の面と 3D の材質を GL と WebGPU（WGSL）で 1 行ずつ塗って値を比べる
#   make cpu-time … 全部の scene を CPU で温めてから何回か描き、1 枚の時間の中央値を build/cpu-time.tsv へ（窓は開かない）
#   make diff-dirs A=<フォルダ> B=<フォルダ> … 2 つのフォルダの同じ名前の PNG の「成分の差の最大・違う画素の数」を 1 行ずつ出す
#                （相対のフォルダはこの bench/gl_parity から読む。知らせるだけで exit は 0）
#   make check … 型検査だけ走らせる
#
# debug/ を毎回消すのは、前回の frame-*.png が残ると通し番号の対応がずれて
# 別の scene と比較してしまうため。FLIX_GE_SPLASH_SHOT を消すのは、起動画面の
# 途中経過 PNG が混ざると枚数が実行タイミングで揺れ、決定性検証が成り立たないため。

.PHONY: run webgpu wgsl-rows cpu-time diff-dirs check

# WhyNot: sh のままにしない — webgpu の口が tee の前の終わりの番号（PIPESTATUS）を見る。
SHELL := /bin/bash

run:
	rm -rf debug/gl debug/soft debug/diff
	unset FLIX_GE_SPLASH_SHOT; FLIX_GE_HIDDEN=1 FLIX_GE_FRAME_SHOT=debug/gl ../../bin/flix run

# WebGPU の描き手（FLIX_GE_BACKEND=webgpu）で V1 が描く scene だけを画面口で流し、SoftRaster と比べる（run と同じ表）。
# 続けて同じ scene を GL でも画面口で撮り、GL と WebGPU を bin/fge pixel-diff で比べる（許す差は 0）。起動のログに WebGPU で起動した行が無ければ止める。
# 絵は debug/webgpu と debug/gl-screen に残す。
# WhyNot: passChain・texField・passMask・3D の scene を入れない — 面（ShaderDoc）・mask・3D の場面を使い、V1 の WebGPU は描かない。
V1_SCENES := boxes,spriteNearest,passPaste,radial,veil
webgpu:
	@# WhyNot: debug/soft を消さない — 選んだ scene しか描き直さないので、git に入っているほかの scene の items.tsv が消える。
	rm -rf debug/gl debug/diff debug/webgpu debug/gl-screen
	@mkdir -p build
	unset FLIX_GE_SPLASH_SHOT FLIX_GE_WEBGPU_FAIL; PARITY_SCENES=$(V1_SCENES) PARITY_VIA_SCREEN=1 FLIX_GE_BACKEND=webgpu FLIX_GE_HIDDEN=1 FLIX_GE_FRAME_SHOT=debug/gl \
		../../bin/flix run 2>&1 | tee build/parity-webgpu.log; test $${PIPESTATUS[0]} -eq 0
	@grep -q '\[backend\] webgpu:' build/parity-webgpu.log || { echo "[parity-webgpu] WebGPU で起動していない（build/parity-webgpu.log）"; exit 1; }
	mv debug/gl debug/webgpu
	unset FLIX_GE_SPLASH_SHOT FLIX_GE_BACKEND; PARITY_SCENES=$(V1_SCENES) PARITY_VIA_SCREEN=1 FLIX_GE_HIDDEN=1 FLIX_GE_FRAME_SHOT=debug/gl ../../bin/flix run
	mv debug/gl debug/gl-screen
	@bad=; for s in $$(echo $(V1_SCENES) | tr , ' '); do \
		../../bin/fge pixel-diff debug/gl-screen/$$s.png debug/webgpu/$$s.png --name $$s --out debug/diff/webgpu-$$s.png || bad="$$bad $$s"; \
	done; [ -z "$$bad" ] || { echo "[parity-webgpu] GL と違う:$$bad"; exit 1; }; echo "[parity-webgpu] OK"

# ShaderDoc の面と 3D の材質を GL（GLSL）と WebGPU（WGSL・Dawn）で 1 行ずつ塗り、8 bit に丸める前の値を比べる（src/WgslRows.flix）。上限を超えたら exit 1。
wgsl-rows:
	unset FLIX_GE_SPLASH_SHOT FLIX_GE_BACKEND; PARITY_WGSL_ROWS=1 FLIX_GE_HIDDEN=1 ../../bin/flix run

cpu-time:
	@mkdir -p build
	../../bin/flix run --entrypoint ParityMain.timeSoft

# WhyNot: python で比べない — PIL の無い機械が多く、PNG の読み方も harness の PixelDiff と同じ物にそろえたい。
diff-dirs:
	@if [ -z "$(A)" ] || [ -z "$(B)" ]; then echo "usage: make diff-dirs A=<フォルダ> B=<フォルダ>"; exit 2; fi
	DIFF_A="$(abspath $(A))" DIFF_B="$(abspath $(B))" ../../bin/flix run --entrypoint PixelDiff.diffDirs

check:
	../../bin/flix check
