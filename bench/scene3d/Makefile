# scene3d — 3D の描き物（Render.Item.Scene3d）の固定の部屋 1 つ（床と壁・家具 12・松明 4）。
#   make still … CPU（SoftRaster）で静止画を 1 枚描く → debug/room.png（窓を開かない）
#   make presets … 部屋に PostStack の preset を 1 つずつ掛けて debug/preset_<名前>.png に書く（preset の値を人が目で見る用・窓を開かない）
#   make haze … 部屋の床から立つ陽炎（PostStack.Distortion の下側の帯）を debug/haze/off.png と on_000〜047.png に書く（窓を開かない）
#   make lighting … 点光源の影・光の量の読み方・ビルボードの影の板の倍率の見比べの静止画を CPU で debug/lighting/ に書く（src/Lighting.flix）。make lighting-frames で動画のコマ
#   make run SCENE=lamps SHADOWS=n … 夜の街灯 8 本の場面で、影を落とす灯りを n 本（0 = 影なし）にして重さを測る（MAPSIZE=512・PCF=1・CROWD=0 で立っている人の板を足す）
#   make cpu-time … CPU で同じ部屋を温めてから何回か描き（回数は Still.timingPlan）、1 枚の時間の中央値を出す（窓を開かない。PNG は書かない）
#   make run   … 実機の窓で毎コマ同じ部屋を描き、カメラを少しずつ回す。区間ごとに 1 行の JSON（[bench] result …。1 コマ・GL へ送る・GPU の時間・
#                draw call・3D の描き手の CPU の区間）を出し、4 区間で閉じる（GL の確かめと重さを測る用。垂直同期は切る）
#   make run SCENE=field … 小さな箱と柱を格子に並べた場面（src/Field.flix）。つまみ:
#                COUNT=1000（物の数）・SHAPES=1（形の種類。each で物ごとに違う形）・MATS=1（材質の種類）・MOVING=100（動く物の %）・
#                ALPHA=0（半透明の物の %）・SHADOW=1（太陽の影）・GROUP=1（動かない物を Scene3d.staticGroup の集まり 1 つで渡す）。FRAMES=240 で 1 区間で測るコマ数・REPEAT=4 で同じ条件を続けて測る回数・
#                VERTS=24（形ごとの頂点の数の目安。箱の面を割って増やす）
#   make run FIRST=1 … 初めての 1 回（src/First.flix）: 物を置かずに回した後に集まりを初めて載せるコマ（区間 first）・同じ名前の別の値の集まりへ替えるコマ（rebuild）の
#                最悪（frame_max・split_max・draw_max）を出す。Field のつまみ（COUNT・SHAPES・MATS・VERTS）が効く。起動し直して 3 回流す
#   make run FIRST=preload … 集まりを App.withPreload3d の groups・scenes で頭から宣言して先に作らせ（区間 ahead）、120 コマ目に初めて載せる（区間 first）
#   make run FIRST=auto [GROUPS=50] … FIRST=1 と同じ場面を、engine が自動で先に作って黒で覆う形で測る（FIRST=1 は自動を切る）。GROUPS で集まりを n 個に分ける
#   make run FIRST=away [AWAY=600] … FIRST=auto と同じ場面で、90 コマ目に集まりを外して AWAY コマの後に同じ値で戻す（区間 return の preload_frames が先に作ったコマ数）
#   ブラウザだけ: ARGS='first=glb&keyed=<0|1>' … 120 コマ目に assets/props_a.glb（retro3d-horror-starter の束 props_1f_a・glb=props_b.glb で後半）を解いて描く（区間 glb の work_max が解く仕事の ms）
#   ブラウザだけ: ARGS='first=glb&deferred=1&warm=1&glb=<props_a|upper_a|girl_student>.glb&fge=deferred:all' … 後回し（web.deferred）の assets/deferred/<glb> を
#                頁が Web Worker で解き、120 コマ目にゲームと同じく読んで Model3d.decode で組む（&fge=deferred:all,noworker でメインで解く前の道・phases=1 で 2 回目の内訳）
#   make run FIRST=skin … 集まりを頭から載せ、途中で骨つきの人物（PERSON=<glb>・既定は retro3d-horror-starter の teacher_woman）を出すコマ（区間 skin）の最悪
#   make run SCENE=orb POST=agx … 光る球の場面（view transform の見比べ。POST は standard / agx / neutral）
#   make run POST=1 … 同じ場面に画面全体の後がけ（App.withPostStack・夕方の屋外の preset）を掛ける（後がけの重さを POST なしと並べる）
#   make run POST=haze … POST=1 に床から立つ陽炎（PostStack.Distortion）を足す（歪みの Pass の重さを POST=1 と並べる）
#   make run POST=fog … POST=1 に床を這う霧（PostStack.HeightFog）を足す
#   make haze-video [LOOK=haze|fog|off] … 陽炎か霧の部屋を VideoOut で書き出す（FGE_GPU=on で GL・FGE_PNG_PAINTER=webgpu で WebGPU・FGE_GPU=off で CPU。src/render/HazeVideo.flix）
#   make run PSX=dither|full|off … 部屋を Design の解像度・板目の床で、PS1 風の描き方（Scene3d.PsxLook）を掛けて描く（off は同じ場面を切って描く。重さを並べる）
#   make psx-video [LOOK=off|dither|full|crt] … （crt は full に PostStack の CRT のにじみ）部屋を PS1 風の描き方（Scene3d.PsxLook）で Design の解像度に書き出す（2 秒の首振り。塗る物の選び方は haze-video と同じ。src/render/PsxVideo.flix）
#   make check … 型検査だけ走らせる
#
# 家具は assets/models/*.obj（fps3d_lab の写し。Blender の 1 m = world の 16）。
# 基準は RESULTS.md。ブラウザ版は engine の根で make bench-web BENCH=scene3d ARGS='scene=field&n=12000'。

.PHONY: common-fresh still presets haze haze-video psx-video cpu-time run check lighting lighting-frames

still:
	../../bin/flix run --entrypoint Still.write

presets:
	../../bin/flix run --entrypoint Still.presets

haze:
	../../bin/flix run --entrypoint Still.haze

psx-video:
	../../bin/flix run --entrypoint PsxVideo.write

haze-video:
	../../bin/flix run --entrypoint HazeVideo.write

cpu-time:
	../../bin/flix run --entrypoint Still.time

lighting:
	mkdir -p debug/lighting
	../../bin/flix run --entrypoint LightingStill.stills

lighting-frames:
	mkdir -p debug/lighting/frames
	../../bin/flix run --entrypoint LightingStill.frames

run: common-fresh
	FLIX_GE_NO_VSYNC=1 FLIX_GE_MUTE=1 ../../bin/flix run

check: common-fresh
	../../bin/flix check

# src の BenchRun.flix・BenchEnv.flix は bench/common の写し。食い違ったまま測らない。
common-fresh:
	@for f in BenchRun.flix BenchEnv.flix; do cmp -s ../common/$$f src/$$f || { echo "src/$$f が bench/common と違う。engine の根で make bench-common"; exit 1; }; done
