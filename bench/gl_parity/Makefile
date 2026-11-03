# gl_parity — GL 描画と SoftRaster 描画の突き合わせ harness の入口。
#   make run   … 隠しウィンドウで GL を焼き、SoftRaster と画素比較する（不一致で exit 1）
#   make cpu-time … 全部の scene を CPU で温めてから何回か描き、1 枚の時間の中央値を build/cpu-time.tsv へ（窓は開かない）
#   make diff-dirs A=<フォルダ> B=<フォルダ> … 2 つのフォルダの同じ名前の PNG の「成分の差の最大・違う画素の数」を 1 行ずつ出す
#                （相対のフォルダはこの bench/gl_parity から読む。知らせるだけで exit は 0）
#   make check … 型検査だけ走らせる
#
# debug/ を毎回消すのは、前回の frame-*.png が残ると通し番号の対応がずれて
# 別の scene と比較してしまうため。FLIX_GE_SPLASH_SHOT を消すのは、起動画面の
# 途中経過 PNG が混ざると枚数が実行タイミングで揺れ、決定性検証が成り立たないため。

.PHONY: run cpu-time diff-dirs check

run:
	rm -rf debug/gl debug/soft debug/diff
	unset FLIX_GE_SPLASH_SHOT; FLIX_GE_HIDDEN=1 FLIX_GE_FRAME_SHOT=debug/gl ../../bin/flix run

cpu-time:
	@mkdir -p build
	../../bin/flix run --entrypoint ParityMain.timeSoft

# WhyNot: python で比べない — PIL の無い機械が多く、PNG の読み方も harness の PixelDiff と同じ物にそろえたい。
diff-dirs:
	@if [ -z "$(A)" ] || [ -z "$(B)" ]; then echo "usage: make diff-dirs A=<フォルダ> B=<フォルダ>"; exit 2; fi
	DIFF_A="$(abspath $(A))" DIFF_B="$(abspath $(B))" ../../bin/flix run --entrypoint PixelDiff.diffDirs

check:
	../../bin/flix check
