# shader_cache_soak — シェーダープログラムのキャッシュの上限を実機の GL で確かめる harness の入口。
#   make run   … 隠しウィンドウで別々の Spec を大量に投げ、頭打ちにならなければ exit 1
#   make check … 型検査だけ走らせる
#
# FLIX_GE_FRAME_SHOT は渡さない。ここで見たいのは追い出しの記録だけで、フレームごとの
# PNG 書き出しと画面の読み出しを起こすと 1 回の実行が数分に伸びる。
# FLIX_GE_SPLASH_SHOT を消すのは、起動画面の途中経過 PNG が混ざると実行時間が
# タイミングで揺れるため。

.PHONY: run check

run:
	unset FLIX_GE_SPLASH_SHOT; FLIX_GE_BACKEND=gl FLIX_GE_HIDDEN=1 ../../bin/flix run

check:
	../../bin/flix check
