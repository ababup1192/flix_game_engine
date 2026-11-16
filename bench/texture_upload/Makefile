# texture_upload の入口。
#   make run   … ベンチを起動する（区間を走り切って自動終了・統計は stdout）
#   make check … 型検査だけ走らせる

.PHONY: run check

# WhyNot: FLIX_GE_BACKEND を外すだけにしない — このベンチは GL を直に呼んで絵を上げ、既定の WebGPU の窓には GL の文脈が無い。
run:
	FLIX_GE_BACKEND=gl ../../bin/flix run

check:
	../../bin/flix check
