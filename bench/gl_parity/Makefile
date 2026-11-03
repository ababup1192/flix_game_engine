# gl_parity — GL 描画と SoftRaster 描画の突き合わせ harness の入口。
#   make run   … 隠しウィンドウで GL を焼き、SoftRaster と画素比較する（不一致で exit 1）
#   make cpu-time … 全部の scene を CPU で温めてから何回か描き、1 枚の時間の中央値を build/cpu-time.tsv へ（窓は開かない）
#   make check … 型検査だけ走らせる
#
# debug/ を毎回消すのは、前回の frame-*.png が残ると通し番号の対応がずれて
# 別の scene と比較してしまうため。FLIX_GE_SPLASH_SHOT を消すのは、起動画面の
# 途中経過 PNG が混ざると枚数が実行タイミングで揺れ、決定性検証が成り立たないため。

.PHONY: run cpu-time check

run:
	rm -rf debug/gl debug/soft debug/diff
	unset FLIX_GE_SPLASH_SHOT; FLIX_GE_HIDDEN=1 FLIX_GE_FRAME_SHOT=debug/gl ../../bin/flix run

cpu-time:
	@mkdir -p build
	../../bin/flix run --entrypoint ParityMain.timeSoft

check:
	../../bin/flix check
