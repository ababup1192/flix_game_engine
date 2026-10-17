# ゲーム開発の入口。
#   make        … ゲームを起動する（ウィンドウが開く）
#   make help   … 共通の口の一覧（run / test / check / 描き出し / status …）
#   make palette … Studio 用の色の写し(assets/internet_dungeon.palette.json)を無条件に作り直す
#   make atelier-preview … atelier/ の候補と assets/ の現行を debug/atelier/ に描き出す
#   make art-gate … ドット絵の色の門（python3 bin/px.py gate。決まりは art/internet_dungeon.colorgate.json）
#   make pxkit-test … ドット絵の部品集（bin/pxkit/）のテスト
#   make battle-video … 戦いの画面を動かした動画を debug/video/ に描き出す（採用判断用）
#   make chip-render NAME=<名前> … assets/music/<名前>.chip.json（チップチューンのトラッカー譜面）を debug/chip/ に WAV で書き出す（NAME 無しで全曲）
#   make match3-video [M3_ONLY=名前,…] … 3 マッチの手ざわり（入れ替え・ヒント・テンポ・特殊な駒・1 日の通し）を今の puzzle.json のまま同じ盤・同じ手順で debug/video/match3/ に描き出す
#   make puzzle-video … 昼のパズルで駒が連鎖して消える場面の動画を debug/video/ に描き出す（採用判断用）
#   make feed-video … 夜のホームの引っ張って更新の動画を debug/video/ に描き出す（-sfx で効果音付き）
#   make deck-video … 出撃前のデッキ一覧をキーで見て回る動画を debug/video/deck.mp4 に描き出す（採用判断用）
#   make pick-video … カードを取る画面（効果の行の ▲ / ⊘・「いま → 取った後」の欄・型の予告）を候補の上で動かした動画を debug/video/pick.mp4 に描き出す
#   make opening-video … 「はじめから」のオープニングを音つきで debug/video/opening.mp4 に描き出す（絵コンテ）
#   make talk-turn-video … 場面が変わる会話の送り（op_post → op_avatar）を debug/video/talk_turn*.mp4 に描き出す
#   make lose-turn-video … 負けた後（LOSE → op_lose → X のホーム）を debug/video/lose_turn.mp4 に描き出す
#   make diffuse-video … オープニングの「データが広がる」演出を音つき（等速 + 0.5 倍速）で描き出す
#   make count-land-video … 広がる演出の数え上げの前後だけ（止まった拍の跳ねと光の帯）を 60fps・音つきで debug/video/count_land.mp4 に描き出す
#   make fight-loss-video … オープニングのカードなしの負け戦を音つきで debug/video/fight_loss.mp4 に描き出す
#   make event-intro-video … イベント戦の入り（会話の最後の行 → WARNING と溜め → VS → ターン 1）を音つきで debug/video/event_intro.mp4 に描き出す
#   make end-fx-video … LOSE の帯（色が抜けて沈む）と決着の窓（負け = 負けの曲つき / 勝ち = 欠片のハート）の動画を debug/video/endfx/ に描き出す
#   make battle-fx-video … 空振り（解除・浄化）・盾の数え下がりと割れ・加速と減速の当たりの動画を debug/video/bfx_*.mp4 に描き出す
#   make replay-video … 戦いの録画（負けの 1 戦を操作して見せる / 勝つ見本のトドメのスロー）の動画を debug/video/replay/ に描き出す
#   make replay-fight-probe … 録画を描き出す「同じ戦い」の拍・決め手・クリップの列を 1 行ずつ書く
#   make fight-video FOE=lizard HP=14 DECK=ATK_002,DEF_001 NAME=x … 指定の 1 戦を音つきで debug/video/fight_x.mp4 に描き出す
#   make entry-video … デッキ一覧 → 回るスマホ → 戦いの入りのカットイン → 戦いの頭を音と曲つきの動画に描き出す
#   make transition-video … 昼夜の境目の切り替わり（スマホを置く / スマホに吸い込まれる）を音入りの動画に描き出す
#   make sim … 夜の 3 戦の勝率（遊び方ごと・型 × 敵・4 つの戦い）を数えて debug/sim/ に CSV で書く（SIM_RUNS=100）
#   make novice-sim NOVICE_RUNS=300 … 初見の雑なプレイヤーがデモのクリアまで何回目の挑戦か（救済の段ごとの勝率・どの敵で負けるか）
#   make sim-trace FOE=lizard HP=20 DECK=ATK_002,DEF_001 NAME=x … 1 戦を 1 ターン 1 行で debug/sim/trace_x.csv に書く
#   make sim-forecast … 予報の画面の見本用トレース（3 体 × 手元 3 枚 + 候補 1 枚）を debug/sim/forecast/ に書く
#   make weak-cards WEAK_SPEC=spec.txt WEAK_STRIP=ID,ID … 弱いカードを戦闘だけで比べる（基準デッキの差し替え・2 枚組・量の試し。debug/weakcards/）
#   make lab-cache LAB_RUNS=1000 … バランス・ラボの盤の結果を置く（debug/lab/cache_*.jsonl。盤 3 段 × 走行）
#   make lab LAB_SET="enemy.lizard.attack=4" / LAB_SETS="案A;案B" … 置いた盤から選び方と戦いだけ回して比べる（debug/lab/<LAB_NAME>/index.html）
#   make combo-lab LAB_SETS="…" / make combo-sweep COMBO_FOE=lizard … コンボの大きさを腕前 × 案で測る / 3 枚の組み合わせを総当たり / make combo-style = 堅実型と一撃型のリスクとリターン（debug/lab/<LAB_NAME>/）
#   make lab-verify … 置いた盤から回した結果が、通しのシム（同じ種）と一致するか
#   make sim-server … Studio の戦闘シミュレータ用の常駐サーバ（127.0.0.1:8790 の /sim）
#   make lint   … 下ごしらえ検査（View・色票・ドット絵・コマ・UI のはみ出し・描く順）
#   make clean  … build/ を消す（Windows で「同じ名前の別クラス」に当たったとき用）
#
# エンジンや java の場所はマシンごとに違うので、git に入れない local.mk に書く
# （このリポを clone したら 1 度だけ書く）:
#   ENGINE := /abs/path/to/flix_game_engine   （Studio 同梱なら …/resources/engine）
#   JAVA   := /abs/path/to/java.exe           （Windows のみ。Studio 同梱 JRE の java.exe）
# 一時的な上書きは `make run ENGINE=... JAVA=...` でもできる。
-include local.mk

# Studio 用の色の写し。入力（テーマ・sprite の Doc と、色を解く側のコード）が
# 写しより新しいときだけ作り直す。flix run は 1 回ごとにパッケージ全体をコンパイルし直すので、
# render のたびに無条件で走らせると、絵を描くのと同じだけのコンパイル時間を二重に払う。
# 入力の洗い出しに漏れがあったときは `make palette` で無条件に作り直す。
PALETTE      := assets/internet_dungeon.palette.json
PALETTE_DEPS := assets/internet_dungeon.theme.json assets/internet_dungeon.puzzle.sprite.json \
                assets/internet_dungeon.battle.sprite.json assets/internet_dungeon.feed.sprite.json \
                assets/internet_dungeon.day.sprite.json \
                src/Palette.flix src/ThemeDoc.flix
# 描き出せる場面の名前（使い方に出す一覧）。正は SceneRender.shotNames で、reference/SHA256SUMS.txt は
# make reference-update がその全場面から書くので、手で写さずそこから引く。
SHOTS := $(shell awk '{ sub(/\.png$$/, "", $$2); print $$2 }' reference/SHA256SUMS.txt)
RENDER_NOTE := 下見（gallery の外）: make atelier-preview
# bin/fge heavy が長い物（engine 0.35.33 から枠 1〜2 の 2 本まで）と見るゲーム固有の口。--long を付け忘れても短い物だけの枠を塞がない（engine 0.35.30 から）。
HEAVY_LONG := z-audit-videos lab lab-cache lab-verify combo-lab combo-sweep sim novice-sim render-board-gifs

# ENGINE の場所が違うと include ごと落ち、make は「そんなファイルは無い」としか言わない。
# 先に自前で見て、直し方の 1 行を出してから止める（この検査が無いと make status も塞がる）。
ifeq ($(shell test -f "$(ENGINE)/mk/game.mk" && echo ok),)
$(error ENGINE が見当たりません ($(ENGINE)/mk/game.mk が無い) — local.mk に「ENGINE := /abs/path/to/flix_game_engine」を書くか、make <対象> ENGINE=... で指定してください。Studio 同梱なら …/resources/engine)
endif

# 共通の口（run / test / check / 描き出し / status …）はエンジンが持つ。
# 写しではないので、エンジンを上げると直しがそのまま届く。
# include は make の構文でクォートが効かず、空白でパスが分割される。
# Studio 同梱の engine は "/Applications/Flix GE Studio.app/…" と空白を含むので、
# 空白を退避してから渡す（レシピの中の $(ENGINE) は "" で括ってあるのでそのままでよい）。
space := $(subst ,, )
include $(subst $(space),\$(space),$(ENGINE))/mk/game.mk

.PHONY: chip-render assist-video card-timing-video shine-video lab lab-cache lab-verify combo-lab combo-sweep combo-style sim sim-trace novice-sim weak-cards sim-forecast sim-server atelier-preview render-board-gifs battle-video battle-video-sfx match3-video puzzle-video puzzle-video-sfx \
        feed-video feed-video-sfx feed-result-video relic-video end-video deck-video pick-video transition-video entry-video opening-video tutorial-video diffuse-video count-land-video talk-turn-video lose-turn-video fight-loss-video event-intro-video fight-video battle-fx-video end-fx-video replay-fight-probe replay-video lint clean \
        lint-view lint-palette lint-sprite lint-anim art-gate pxkit-test lint-ui-overflow lint-zorder z-audit-videos

# 戦闘シミュレータの常駐サーバ（127.0.0.1:8790 の /sim と /health）。ウィンドウは開かない。
# Studio の「戦闘シミュレータ」プラグインが /bake/wake 経由でこれを起こす。
sim-server:
	JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" $(FLIX) run --entrypoint SimServer.serve

atelier-preview:
	$(HEADLESS_RUN) SceneRender.atelier

# チュートリアルの固定盤（board.json）を動かした GIF を debug/board_<id>.gif に焼く。
render-board-gifs:
	$(HEADLESS_RUN) BoardGifRender.all

# 動画の口の共通部: 連番のフォルダを消す → 入口を流す → フォルダごとに mp4 へ束ねる（bin/mix-video-sfx.py）。
#   $(call video,入口,debug/video/ の下のフォルダ…,fps,mix-video-sfx.py へのオプション,出力名の後ろに足す字)
#   音を乗せない口は --mute、曲も乗せるなら --bgm、0.5 倍速も書くなら --with-slow（<出力>_slow.mp4）。
#   入口へ渡す環境変数は、口ごとに VIDEO_ENV を target-specific に置く（tutorial-video・fight-video）。
#   描き直さずに連番を束ね直すだけなら $(call mix,フォルダ…,fps,オプション,出力名の後ろに足す字)。
#   入口を流す前置き HEADLESS_RUN はエンジンの game.mk にある（jar を 1 回だけ作って使い回す）。
SOUNDS = $(HEADLESS_RUN) SceneRender.sounds
define mix
	for r in $(1); do python3 bin/mix-video-sfx.py debug/video/$${r} $(2) debug/video/$${r}$(4).mp4 $(3) || exit 1; done
endef
define video
	rm -rf $(addprefix debug/video/,$(2))
	$(VIDEO_ENV) $(HEADLESS_RUN) $(1)
	$(call mix,$(2),$(3),$(4),$(5))
endef
tutorial-video: VIDEO_ENV = TUT_FPS=$(TUT_FPS) TUT_SCALE=$(TUT_SCALE)
fight-video: VIDEO_ENV = FIGHT_FOE=$(FOE) FIGHT_HP=$(HP) FIGHT_DECK=$(DECK) FIGHT_NAME=$(NAME) FIGHT_FPS=$(FPS)

# 戦いの画面を動かした動画（連番 PNG → H.264）を debug/video/ に書き出す。
# 相手ごとの戦い = battle.mp4（スライム・60fps）/ battle_zombie.mp4 / battle_lizard.mp4（30fps）、
# スライム戦の 0.5 倍速 = battle_slow.mp4（battle と同じ連番を 30fps で束ねる）、3 体の戦いの右半分を横に並べた = enemies.mp4。
VIDEO_RUNS := battle_zombie battle_lizard
battle-video:
	rm -rf $(addprefix debug/video/,$(VIDEO_RUNS))
	$(call video,BattleVideo.frames,battle,60,--mute --with-slow)
	$(call mix,$(VIDEO_RUNS),30,--mute)
	ffmpeg -y -loglevel error -i debug/video/battle.mp4 -i debug/video/battle_zombie.mp4 \
		-i debug/video/battle_lizard.mp4 \
		-filter_complex "[0]crop=400:400:560:140[a];[1]crop=400:400:560:140[b];[2]crop=400:400:560:140[c];[a][b][c]hstack=3" \
		-c:v libx264 -pix_fmt yuv420p -crf 18 -movflags +faststart debug/video/enemies.mp4

# スライム戦をバトルスタートのカットインから 60fps で描き出し、Sfx が鳴らす効果音を同じ拍で乗せる
# = debug/video/battle_sfx.mp4（勝つ戦い・クリティカルあり）/ battle_lose_sfx.mp4（負ける戦い）と、
# それぞれの 0.5 倍速 *_slow.mp4。
battle-video-sfx:
	$(call video,BattleVideo.slime,battle battle_lose,60,--with-slow,_sfx)

# 発動の拍の継ぎ目: 満了したカードがスタンバイの扇から抜ける拍と、真ん中へ飛んで回る拍の
# つながりを、効果音と曲つき・等速・60fps で = debug/video/card_timing.mp4。
# はやさの段ごとのコマごとの拍の中身は debug/video/card_timing/timing_<はやさ>.txt。
card-timing-video:
	$(call video,BattleVideo.cardTiming,card_timing,60,--bgm --crf 28)

# 戦いから戦いの後の画面（拡散したポストのカード）まで、効果音と曲を乗せて 30fps で描き出す
# = debug/video/end_win.mp4（勝ち → 戦果）/ end_lose.mp4（負け → 削除されたポスト）/
# end_speed4.mp4（はやさ ×4 の戦い。組み直した風切りと HP の帯の流れ落ち）。
END_VIDEO_RUNS := end_win end_lose end_speed4
end-video:
	$(call video,BattleVideo.endScreens,$(END_VIDEO_RUNS),30,--bgm)

match3-video:
	M3_ONLY="$(M3_ONLY)" $(HEADLESS_RUN) Match3Video.frames
	for dir in debug/video/match3/*/; do run=$$(basename $$dir); \
		ffmpeg -y -loglevel error -framerate 30 -i $$dir/f%04d.png \
			-c:v libx264 -pix_fmt yuv420p -crf 30 -movflags +faststart debug/video/match3/$$run.mp4; done

# 昼のパズルの消える演出（水風船のしぶき）を、実機と同じ描画で動かした動画
# = debug/video/puzzle.mp4（等速・60fps）/ puzzle_slow.mp4（同じ連番を 30fps で束ねた 0.5 倍速）。
puzzle-video:
	$(call video,PuzzleVideo.frames,puzzle,60,--mute --with-slow)

# 「入れ替えればそろう」駒に通る光の帯を等速 60fps で撮る（マウスでそろう → そろわない → キーでつかむ）。
shine-video:
	$(call video,PuzzleVideo.shineFrames,shine,60,--mute)

# 出撃前のデッキ一覧（↑↓ で属性の行・←→ でカードを選ぶ）を、実機と同じ描画で動かした動画。
deck-video:
	$(call video,DeckVideo.frames,deck,30,--mute)

# カードを取る画面を、実機と同じ描画と入力で候補の上にカーソルを動かして描き出す
# = debug/video/pick.mp4（960×600・15fps。⊘ と ▲ の混ざるカード → 全部 ▲ で型が変わるカード →
# 取らない → 取る → 2 回目の候補で全部 ⊘ のカード）。
pick-video:
	$(call video,PickVideo.frames,pick,15,--mute)

# puzzle-video の連番に、Sfx が鳴らす効果音を同じ拍で乗せる = debug/video/puzzle_sfx.mp4（等速）。
puzzle-video-sfx: puzzle-video
	$(call mix,puzzle,60,,_sfx)

# 夜のホームの「引っ張って更新」（引っ張る → 輪が回る → シュポッ → 新着が 1 件ずつ並ぶ）を、
# 実機と同じ描画で動かした動画（等速 = feed.mp4・60fps / 同じ連番を 30fps で束ねた 0.5 倍速 = feed_slow.mp4）。
# 夜の頭の 1 回と、帰還 → ピルを押す、の 2 幕。
feed-video:
	$(call video,FeedVideo.frames,feed,60,--mute --with-slow)

# エゴサーチ（アーティファクトの 3 択）の動画を 60fps・効果音付きで描き出す
# = debug/video/relic_flow.mp4（投稿を開いて HP を払い 3 択で選び、入手の演出まで）/ relic_cost_hit.mp4
# （リザードマン戦の頭に通知オンのルーレットが回り、止まったカードの COST を 1 下げる）。
RELIC_VIDEO_RUNS := relic_flow relic_cost_hit
relic-video:
	$(call video,RelicVideo.all,$(RELIC_VIDEO_RUNS),60,--crf 28)

# 等速 + 0.5 倍速の両方に、Sfx が鳴らす効果音を同じ拍で乗せる
# = debug/video/feed_sfx.mp4 / debug/video/feed_sfx_slow.mp4（feed-video の連番を使う）。
feed-video-sfx: feed-video
	$(call mix,feed,60,--with-slow,_sfx)

# フィードのイベントの結果の窓（応援に返信 → 手数の鉛筆が奥から転がってきて止まる / 罠 → 鉛筆が奥へ
# 転がって消え HP が削れる / いいね → ハートが飛んできて欠片が増える）を、効果音付き・等速で
# = debug/video/feed_result.mp4。
feed-result-video:
	$(call video,FeedVideo.result,feed_result,30,)

# 昼と夜の境目の切り替わり（夜のホーム →「スマホを置く」→ 盤の会話 / デッキ一覧 →「スマホに
# 吸い込まれる」→ バトルスタートの帯）を、効果音と曲（2 本の曲の重なりも）入りの mp4 に描き出す
# = debug/video/transition_sfx.mp4（等速）と transition_sfx_slow.mp4（0.5 倍）。
transition-video:
	$(call video,TransitionVideo.frames,transition,60,--bgm --with-slow --crf 28,_sfx)

# デッキ一覧で「Z でバトル開始」→ スマホが上がって回りながら大きくなり、その画面の中で戦いの入りの
# カットインが始まる → 画面いっぱいで VS → バトルスタートの帯 → 戦いの頭 8 秒を、効果音と曲入りで
# = debug/video/entry.mp4（等速）と entry_slow.mp4（0.5 倍）。
entry-video:
	$(call video,TransitionVideo.entry,entry,60,--bgm --with-slow --crf 28)

# 「はじめから」のオープニング（机の後ろからの引き → 投稿 → データが夜のネットへ広がる → クソリプ →
# アンチ → カードなしの戦い → 負けた後の会話 → X のホーム → 盤）を、実機と同じ描画で動かし、
# 効果音と曲を乗せた動画 = debug/video/opening.mp4（全編・等速・20fps）。会話は字数ぶん待って自動で送る。
opening-video:
	$(call video,OpeningVideo.frames,opening,20,--bgm)

# 最初のパズルのパートのチュートリアル（負けた後の会話 → X のホーム → 盤のページ送り → 自分で遊ぶ →
# カード選びのページ送り → 1 枚取る）を、実機と同じ描画で動かし、効果音と曲を乗せた動画 = debug/video/tutorial.mp4（既定 15fps・480×300。TUT_FPS / TUT_SCALE で替える）。
# 撮り終えた動画のうち TUT_FRAMES="始め-終わり" のコマだけを描き直して束ね直す（音の表はそのまま）。
TUT_FPS ?= 15
TUT_SCALE ?= 1
tutorial-redraw:
	TUT_FRAMES="$(TUT_FRAMES)" TUT_FPS=$(TUT_FPS) TUT_SCALE=$(TUT_SCALE) $(HEADLESS_RUN) TutorialVideo.frames
	$(call mix,tutorial,$(TUT_FPS),--bgm)

tutorial-probe:
	JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" $(FLIX) run --entrypoint TutorialVideo.probe

tutorial-video:
	$(call video,TutorialVideo.frames,tutorial,$(TUT_FPS),--bgm)

# オープニングの「データが夜のネットへ広がる」演出（光の河をくだる）を、投稿の拍の頭から広がり終えるまで
# 30fps で = debug/video/diffuse_A.mp4（音つき）と diffuse_A_slow.mp4（0.5 倍速）。
diffuse-video:
	$(call video,OpeningVideo.diffuse,diffuse_A,30,--bgm --with-slow)

# 広がる演出の数え上げの前後だけ = debug/video/count_land.mp4（音と曲つき・60fps）。
# 数え上げが止まった拍に数が跳ねて光の帯が通る所を確かめる。
# 場面が変わる会話の送り（op_post → クソリプの拍 → op_antis → 這い出し → op_avatar）を、読んでから押す人
# （talk_turn.mp4）と 0.3 秒ごとに連打する人（talk_turn_mash.mp4）の 2 本で debug/video/ に描き出す（20fps・音つき）。
talk-turn-video:
	$(call video,OpeningVideo.talkTurn,talk_turn talk_turn_mash,20,--bgm)

# 負けた後（LOSE の帯 → 会話 op_lose → ブラウン管が切れて X のホームが点く）を debug/video/lose_turn.mp4 に（20fps・音つき）。
lose-turn-video:
	$(call video,OpeningVideo.loseTurn,lose_turn,20,--bgm)

count-land-video:
	$(call video,OpeningVideo.countLand,count_land,60,--bgm)

# カードなしの負け戦（始まり → 負け → 「あぁ……っ！」）= debug/video/fight_loss.mp4（音つき・30fps）。
fight-loss-video:
	$(call video,OpeningVideo.fightLoss,fight_loss,30,--bgm)

# イベント戦の入り（アバター登場の会話の最後の行 → 会話が裂ける → WARNING → 溜め → 無音 → VS →
# バトルスタート → ターン 1）= debug/video/event_intro.mp4（音と曲つき・30fps）。
event-intro-video:
	$(call video,OpeningVideo.eventIntro,event_intro,30,--bgm)

# 指定の 1 戦（相手・持ち込む体力・デッキ）を、相手の体力も Doc のままカットインから決着 →
# 戦いの後の画面まで音と曲つき・等速・30fps（FPS=60 で 60fps）で = debug/video/fight_<NAME>.mp4（バランス調整の確かめ用）。
#   make fight-video FOE=lizard HP=14 DECK=ATK_002,DEF_001,INT_003 NAME=lizard_win
#   DECK の :1 / :2 は 4 個消し / 5 個消しの強化（SimServer と同じ書き方）。
FOE ?= lizard
HP ?= 20
DECK ?= ATK_002,DEF_001
NAME ?= custom
FPS ?= 30
# 空振り・盾・加速と減速の当たりの演出（cue.json の battleFx）が起きる戦いを、60fps・効果音つきで描き出す
# = debug/video/bfx_<miss|shield|pace>.mp4。場面は src/render/BattleFxVideo.flix。
BFX_RUNS := miss shield pace
battle-fx-video:
	$(SOUNDS)
	$(call video,BattleFxVideo.frames,$(addprefix bfx_,$(BFX_RUNS)),60,--crf 26)

# LOSE の帯（色が抜けて沈む）と決着の窓の動画（60fps・効果音と曲つき）。debug/video/endfx/lose.mp4（負けの 1 戦の終わり →
# 力尽きた窓。負けの曲 bgmLose）・win.mp4（勝つ見本の戦果の窓。欠片のハート）。
# 負けの曲は BGM_LOSE で別の WAV（atelier/ の候補など）に差し替えて聴き比べられる。
BGM_LOSE ?= assets/sfx/bgmLose.wav
end-fx-video:
	$(SOUNDS)
	$(call video,EndFxVideo.frames,endfx/lose endfx/win,60,--bgm --sub bgmLose=$(BGM_LOSE) --crf 26)

# 負けた後の救済の演出の動画（力尽きた窓 →「やりなおす」→ 救済の演出 → 盤）。debug/video/endfx/assist.mp4。
assist-video:
	$(SOUNDS)
	$(call video,EndFxVideo.assistFrames,endfx/assist,60,--bgm --sub bgmLose=$(BGM_LOSE) --crf 26)

fight-video:
	$(call video,BattleVideo.custom,fight_$(NAME),$(FPS),--bgm)

# 夜の 3 戦のバランスを数える（実機の Battle / Puzzle / Cards をそのまま回す。乱数なしで決定的）。
# 書き出しの読み方は src/render/BalanceSim.flix の冒頭。SIM_RUNS = 遊び方 1 つ・節 1 つあたりの走行数。
SIM_RUNS ?= 100
sim:
	SIM_RUNS=$(SIM_RUNS) $(HEADLESS_RUN) BalanceSim.report

# 戦いの録画（ろくが）の動画（60fps・効果音つき）。debug/video/replay/lose.mp4（負けの 1 戦を開いて
# 頭出し・はやさを操作）・replay/win.mp4（勝つ見本。トドメの止めとスロー）、
# 静止画 still_lose.png。
replay-video:
	$(SOUNDS)
	$(call video,ReplayVideo.frames,replay/lose replay/win,60,--crf 26)

# 録画を描き出す「同じ戦い」（src/render/ReplayFight.flix）の拍を 1 行ずつ書く（会心・盾の割れ・減速に印・クリップの列）。
replay-fight-probe:
	JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" $(FLIX) run --entrypoint ReplayFight.probe

# 1 戦をターンごとに（どのカードが出たか・体力・盾・毒・強化・炎上）。FOE / HP / DECK は fight-video と同じ。
sim-trace:
	TRACE_FOE=$(FOE) TRACE_HP=$(HP) TRACE_DECK=$(DECK) TRACE_NAME=$(NAME) \
		$(HEADLESS_RUN) BalanceSim.trace

# 初見の雑なプレイヤーの通し（盤もカードもでたらめ・負けたら救済の段が上がって同じデッキで再戦。段が尽きたら翌日に盤から）。
# デモのクリアまで何回目の挑戦か。書き出しは debug/sim/novice_fights.csv、表は bin/novice-report.py（読み方は src/render/NoviceRun.flix の冒頭）。
NOVICE_RUNS ?= 300
novice-sim:
	began=$$(date +%s); \
	NOVICE_RUNS=$(NOVICE_RUNS) $(HEADLESS_RUN) NoviceRun.main && \
	python3 bin/novice-report.py debug/sim/novice_fights.csv debug/sim/novice/index.html $$(( $$(date +%s) - began ))

# バランス・ラボ（盤の結果を置いておき、選び方と戦いだけ回し直す。読み方は src/render/BalanceLab.flix の冒頭と NOTES.md）。
# ラボ・シミュの口も描き出しと同じ $(HEADLESS_RUN)（engine の game.mk）で流す: jar は描き出しと共用の 1 本
# （build/headless/）で、src が変わった後の 1 回だけ作り、あとは JVM の起動だけ。ラボは再帰が深いので
# スタックを 64MB に広げる（HEADLESS_JAVA_OPTS は engine 0.35.39 から）。
LAB_RUNS ?=
LAB_NAME ?= latest
# java は JAVA（local.mk でも可）で選べる。headless-run は環境の JAVA を読むので前置きで渡す。
LAB_JAVA_OPTS := HEADLESS_JAVA_OPTS=-Xss64m $(if $(JAVA),JAVA="$(JAVA)")
LAB_RUN  = LAB_RUNS=$(LAB_RUNS) $(LAB_JAVA_OPTS) $(HEADLESS_RUN) BalanceLab.main
lab-cache:
	LAB_MODE=cache $(LAB_RUN)
lab:
	LAB_MODE=lab LAB_NAME=$(LAB_NAME) LAB_SET="$(LAB_SET)" LAB_SETS="$(LAB_SETS)" LAB_NOTES="$(LAB_NOTES)" $(LAB_RUN)
# コンボの大きさ（こちらの 1 手番の合計ダメージ）を腕前 × 案で測る / 組み合わせを総当たりする（src/render/ComboLab.flix）。
# 報告は bin/combo-report.py が debug/lab/<LAB_NAME>/combo.json と sweep.json から作る。
COMBO_RUN = LAB_RUNS=$(LAB_RUNS) LAB_NAME=$(LAB_NAME) LAB_SETS="$(LAB_SETS)" LAB_SET="$(LAB_SET)" $(LAB_JAVA_OPTS) $(HEADLESS_RUN) ComboLab.main
combo-lab:
	COMBO_MODE=lab $(COMBO_RUN)
combo-sweep:
	COMBO_MODE=sweep COMBO_FOE=$(COMBO_FOE) COMBO_PICKS=$(COMBO_PICKS) COMBO_CARDS="$(COMBO_CARDS)" $(COMBO_RUN)
combo-style:
	COMBO_MODE=style $(COMBO_RUN)
COMBO_FOE ?= lizard
COMBO_PICKS ?= 3
lab-verify:
	LAB_MODE=verify LAB_VERIFY_RUNS=$(LAB_VERIFY_RUNS) $(LAB_RUN)

# 弱いカードを戦闘だけで比べる（基準デッキ × WEAK_SPEC の試し方。読み方は src/render/WeakCards.flix の冒頭）。
WEAK_OUT ?= debug/weakcards
weak-cards:
	WEAK_OUT=$(WEAK_OUT) WEAK_SPEC=$(WEAK_SPEC) WEAK_SEEDS=$(WEAK_SEEDS) WEAK_STRIP=$(WEAK_STRIP) WEAK_PRESET=$(WEAK_PRESET) $(HEADLESS_RUN) WeakCards.main

# チップチューンの譜面（assets/music/*.chip.json）を WAV に書き出す。書き方は src/ChipDoc.flix の冒頭、
# 楽器は assets/music/internet_dungeon.instrument.json。ループのある曲はループ点ぴったりで切る。
# 採用前の候補（atelier/music）は CHIP_DIR=atelier/music。
CHIP_DIR ?= assets/music
chip-render:
	CHIP_DIR=$(CHIP_DIR) CHIP_NAME=$(if $(filter command line,$(origin NAME)),$(NAME),) JAVA_TOOL_OPTIONS="-Djava.awt.headless=true" $(FLIX) run --entrypoint ChipRender.main

# 予報の画面の見本: 各節の敵 × (手元の 3 枚 / 盾・毒・解除の候補を 1 枚足した 3 通り)。
sim-forecast:
	$(HEADLESS_RUN) BalanceSim.forecast

lint: lint-view lint-palette lint-sprite lint-anim art-gate pxkit-test lint-ui-overflow lint-zorder

# 絵の検査は bin/fge（エンジンの Go）が持つ。前は bin/lint-*.py を呼んでいたが、その台本は Go へ移って無い。
# sprite は debug/（git の外の試し描き）まで降りないよう、見るファイルを名指しする。
lint-view:
	bin/fge view

lint-palette:
	bin/fge palette

lint-sprite:
	bin/fge sprite $(wildcard assets/*.sprite.json atelier/*.sprite.json)

lint-anim:
	bin/fge anim

# ドット絵の色の門（昼は Pear36 だけ・夜は 3 色だけ・#000000 なし。例外は art/internet_dungeon.colorgate.json）。
art-gate:
	python3 bin/px.py gate

# コミットのゲート（engine の bin/fge precommit）が呼ぶゲーム固有の口。STAGED_FILE はステージしたファイルを
# 1 行 1 つ書いた一時ファイル。ドット絵の Doc・色票・色の門の決まりを触ったときだけ art-gate を流す
# （make lint を流し忘れても色の決まりで止まる）。
.PHONY: precommit-local
precommit-local:
	@if grep -qE '\.(sprite|spritesrc|palette|theme)\.json$$|colorgate\.json$$' "$(STAGED_FILE)"; then python3 bin/px.py gate; fi

# ドット絵の部品集（bin/pxkit/）のテスト。移した台本が今の素材とバイトで同じ物を出すかも見る。
pxkit-test:
	python3 -m unittest bin/pxkit/test_pxkit.py

# 画面の字の被り・はみ出し。make render-all（か make render SHOT=...）が場面ごとに字の置き場所を
# 測って debug/ui-overflow.tsv に書き（src/render/TextAudit.flix）、ここがそれを読む。
# 許す物は bin/lint-ui-overflow.json の allow に理由つきで書く。字を幅の決まった所に置く側の
# 決まりは src/TextFit.flix（省略 / 折り返し / 決めた 1 段小さい字。最後は必ず「…」）。
lint-ui-overflow:
	$(PYTHON) bin/lint-ui-overflow.py

# 描く順（z）。make render-all（か make render SHOT=...）が場面ごとに描画物の z を確かめ
# （src/render/ZAudit.flix）、その場面で描いてよい層（src/ZOrder.flix の allowedLayers）の外の物を
# debug/z-audit.tsv に書いて描き出しを止める。ここは同じ表を後から読み直す口。
lint-zorder:
	$(PYTHON) bin/lint-zorder.py
	$(PYTHON) bin/gen-video-entries.py --check

# 撮っていない瞬間の重なり。全部の動画の入口を PNG を描かずに流し（VIDEO_AUDIT=only）、コマごとに
# 上と同じ z の見回りと字の被りの検査をかける（src/render/VideoAudit.flix）。表は debug/z-audit-videos.tsv、
# 続いたコマを束ねた一覧は bin/z-audit-videos.py（許した物は bin/z-audit-videos.json に理由つき）。
# 1 本だけ見るなら Z_VIDEOS=<入口>（例 Z_VIDEOS=DeckVideo.frames）。描きながら見るなら
# rm -f debug/z-audit-videos.tsv; VIDEO_AUDIT=1 make <動画の口>（表は足していくだけなので先に消す）。
# 見るだけの回も音の表・時刻の表・アトラスの PNG は書き直すが、同じ World の列から作るので中身は前と同じ
# （前に描いた連番を $(call mix,…) で束ね直しても絵と音はずれない）。
# 流す入口は上の動画の口の $(call video,入口,…) の行から bin/gen-video-entries.py が
# src/render/VideoAuditEntries.flix へ書き出す（入口を 2 か所に書かない）。$(call video) を通らない口の入口は
# Z_VIDEOS_EXTRA に足し、流さない入口は Z_VIDEOS_SKIP に理由と一緒に書く。
# Z_VIDEOS_SKIP: BattleVideo.custom は相手とデッキを引数で選ぶ 1 戦（既定の引数の 1 戦は battle-video と同じ）。
Z_VIDEOS_EXTRA := Match3Video.frames
Z_VIDEOS_SKIP := BattleVideo.custom
Z_VIDEOS ?= VideoAudit.all
z-audit-videos:
	$(PYTHON) bin/gen-video-entries.py
	rm -f debug/z-audit-videos.tsv
	VIDEO_AUDIT=only $(HEADLESS_RUN) $(Z_VIDEOS)
	$(PYTHON) bin/z-audit-videos.py

clean:
	rm -rf build
