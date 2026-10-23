# エージェント共通指針（エンジン公式・全ゲーム共有）

エンジンの agents-pack から配られる共通部。ゲーム固有の方針は同じフォルダの `AGENTS.local.md` に書く。
lint・フック・make の口で止まる決まりはここに書かない（止まった所で hint が代わりの道具を示す）。

## やりたいこと → 道具（早見表。まずここを引く）

1 行 1 件・80 字まで。行には名前だけ置き、詳しい所は `--help`・engine の docs・モジュール冒頭の doc へ。
表に無ければ `make module Q=<やりたいことの語>`、型と引数は `make api Q=<名前>`。ゲーム固有は `AGENTS.local.md`。

| やりたいこと | 使う道具 |
|---|---|
| 物を重ねる・手前と奥を決める | `ZStack.of` / `leaf` の木を根で `SortingLayer.compose` |
| 必ず手前に出す（確認の窓・ポーズ） | `ZStack.topLayer(層, 木)`・層は `SortingLayer` の enum |
| 見下ろしで人が木の裏に回る | `ZStack.zIndex(Depth.orderAt(足元のy), leaf(人))` |
| 画面ごと動かす・縮める・薄める | `ZStack.mapItems(Render.scaledAllAround(..))` |
| 閉じるボタンで「終了しますか？」・ゲームから終了 | `App.withCloseRequest` + `App.quitWhen` |
| パッドの Start でメニュー・ポーズを開く・パッドの機種（Steam か）で案内の絵を替える | Start は `Key.Menu`（`Enter` ではない）・Select は `Key.Backspace`・機種は `frame#padKind`（engine の `docs/gamepad.md`） |
| 隠れてはいけない表示（スコア・案内） | `App.withHudView` |
| 押す物を見た目の手前から選ぶ（窓の奥を押させない） | 描く木に `ZStack.hit` / `modal` → `SortingLayer.pickFrom` |
| UI のクリックを描いた所で当てる（字の下に並ぶボタン・字だけの項目） | `UiFocus.hitTestUiWith(atlasOf, ..)`・`UiFocusNav.targetsOfUiWith`（atlasOf は描く時と同じ） |
| 説明の窓をはみ出さず置く | `UiTooltip` + `ZStack.topLayer` |
| 演出の時刻表を書く・描く・鳴らす | `Timeline.build`+`withSound` → `soundsBetween`（時計は `soundsOnClock`）→ `App.withAudio` |
| ポーズ・ヒットストップで止める・遅くする（遊びと実時間を分ける） | `App.addClock` + `Clock.Pace`・`frame#realNow` |
| 規則の奥の出来事で鳴らす（固定刻みでも 1 回） | `Emit.emit` → `Emit.collectInto` で World に溜め `Emit.since` |
| 粒（花びら・火の粉）に触れたかを規則で取る | `Fx.particlesOfAll(now, bursts)`（絵と同じ式の番号と中心）+ `Fx.touches` |
| どう遊んでも崩れない決まりを確かめる（性質テスト） | `PropertyTest.forAll`（画面なしで `App.trace` と同じ道） |
| e2e・動画の手順を書いて画面なしで流す（失敗は行番号つき） | `e2e/<名前>.flow` + `App.withFlow`・`bin/fge flow check`・`make flow` |
| 好きな場面から起動・テスト・遊んだ通りに再生 | `App.withStarts`（`START=`・`startOrBug`）・記録は `make flow` で再生 |
| 曲の拍・小節に乗せる | `Duration.Bars` / `ToNextBar` / `ToPickup` + `Timeline.tempo` |
| 演出の長さ・待ち・溜めの目安 | engine の `docs/pacing.md` |
| 音の名前を型で止める（一発と鳴り続ける音を取り違えない） | `Sfx[s]` / `Loop[s]` + `Sfx.collect` / `Loop.collect` |
| 曲の頭を 1 回だけ鳴らし本編をループ | `SfxSynth.renderLooped` + `App.withSustained` |
| 効果音・曲を作る・直す（音割れも検査） | 台本 `*.snd.star` か `*.sndsrc.json` を `bin/fge snd build` |
| 会話を人が書く・台詞と選択肢を順に出す・会話の中で数えて分ける | `*.yarn`（`<<declare>>` `<<set>>` `<<if>>` `{$x}` `visited`）を `bin/fge yarn build` → `Yarn.loadOr` + `YarnRunner.start` / `step`・値は `YarnRunner.valueOf` / `startWith` / `YarnStorage`・選べない選択肢は `DialogueOption` の `available` |
| 会話の行を本物の画面で見る・起動中のゲームをその行へ（変数の値を決めて） | Studio の会話・`bin/fge talk shot` / `goto`（始まり `talk node= line=`・`'$名前=値'` は `YarnStorage.withArgs` → `YarnRunner.startAtWith`） |
| Doc が壊れたら既定値で続けて知らせる | `DocJson.loadOr` + `Log.fellBackThen` / `warnThen` |
| 直した後に絵を確かめる | `make render SHOT=<場面>` → 仕上げ `make reference-check` |
| 描き出しの字の被り・z の外れを止める | `make render-lint`（許す物は `text-audit.local.json`） |
| 直す前と後の絵・音・動画を比べる | `make compare BASE=<ref>` |
| 動画が最後まで撮れたか（途中で止まった動画を見つける） | `bin/fge videos status`（Studio のギャラリーの動画） |
| 動画のコマ・自前のギャラリーで同じ絵を塗り直さない | `RenderCache.writeFramePng`（`SoftRaster.render*` は自動。docs/render-cache.md） |
| 人が見る動画・会話のプレビューを GPU で塗る | 動画 `VideoOut.writeFrames`・1 枚 `GpuShot.shotOf`（`FGE_GPU`） |
| 描き出しに ShaderDoc の面と追加フォントを一緒に渡す（字の縁は本ごとに） | `HeadlessRender.renderPngFull(cfg, scene, name)`（`Scene` の `fonts`・本ごとの字の縁は `fontAntialias`） |
| 遊ぶ起動を速くする（src を変えていない 2 回目からコンパイルしない） | `make run` / `make debug`（engine の headless-run `--window main` が描き出しと同じ jar から流す）・裏で作るだけは `--build-only` |
| 描き出しを続けて流すたびの JVM の立ち上げを省く（render・reference-check・会話の撮り） | `HEADLESS_RESIDENT=1`（窓なしのゲームを常駐・入口は `<名前>Job(req): Int32` と `jobs()`）・`bin/fge resident status` / `verify` |
| F8 のチケット・閉じる | `debug/annotations/` の README → `world.json`・`bin/fge tickets close` |
| 直しが別の不具合を生んだ率 | `bin/fge tickets stats`（前の直しの候補は `suspects`） |
| ゲームの定義を引く | `make src Q=<名前>` |
| 文書が消えた名前・無いファイルを指していないか | `make lint-doc-refs`（古い記録は `doc-refs.local.json` の skip） |
| 名前の使われ所・呼び手を探す（grep より先に・読むのは道具が出した行だけ） | `bin/fge refactor usages <名前>` |
| 使われない pub・use を探して消す・pub を外す | `bin/fge refactor usages --unused` → `remove-dead`・`make-private`・`remove-use` |
| record の欄の直の読み書きを口の関数へ替える（口が無ければ作る） | `bin/fge refactor field-to-accessor` |
| 欄の読みを別の引数の同じ欄へ（`w#x` → `res#x`） | `bin/fge refactor retarget-field` |
| 関数・型 alias を別の mod へ移す（呼ぶ所の修飾名と use も） | `bin/fge refactor move --def Mod.f --to Mod2` |
| record の型に欄を足し、組み立てる所すべてに値を入れる | `bin/fge refactor add-field` |
| 同じ形の式をまとめて書き替える（lint の規則の直しなど） | `bin/fge refactor rewrite --from --to`・`--rule <規則>` |
| 式を関数に出す・同じ形の写しも呼び出しへ | `bin/fge refactor extract-function <範囲> --name Mod.f --all` |
| record の型に名前を付け、同じ欄の組の所を全部その名前へ | `bin/fge refactor extract-type-alias --name Mod.T` |
| `case _` を書き出す・record や case の欄・引数を足す・消す・替える | `bin/fge refactor --help` |
| 重い処理を順に流す | `bin/fge heavy <コマンド>`（`--help`・`--status`・`--history`） |
| 作業場を別の版のエンジンへ一時的に向ける | `bin/fge use-engine <版かパス>`・戻すは `--restore` |
| 案を並べて依頼主に選んでもらう | `reports/<名前>/proposal.json` → `bin/fge proposal` |
| ドット絵を描く・直す（台本・絵の種類で検査が決まる） | `/pixel-art` → `*.px.star` か `*.pxsrc.json`（`"kind"`）を `bin/fge px build` |
| 絵の周回を残す・戻す（次の手は next・止め時は stop） | `bin/fge px snap` / `rounds snap` / `restore`（出る案内に従う） |
| AI が素材（絵・音）を作る・直す | `atelier/` に書く（`assets/` はスロット。採用は swap） |
| 道具の選び方が文書で伝わるか測る | `make agent-eval`（お題は `agent-eval/*.json`） |

新しい仕組みを入れる人は、この表（ゲーム固有なら `AGENTS.local.md`）に 1 行と `agent-eval/` のお題を 1 本足し、
`make agent-eval ONLY=<お題>` で当たるのを確かめる。**足すのと対で、まとめられる行はまとめ、使われなくなった行は消す**。

## 判断の向き（機械では止められない物）

- **エンジンにある物（メニュー・スクロール・文字折り・当たり判定・地形・音のバス・長押し…）を自前で書かない**。ゲームに
  自前の物があってもエンジンの物を選ぶ。早見表で道具が決まればそのまま使い、表に無い時だけ `make module` / `make api` で引く。
  使い方はモジュール冒頭の doc と `templates/` が正。「一番高い API で書けたか」を疑う。
- **言葉は業界の語**（カタカナか英語）で、説明は平易に。造語・比喩・このリポだけの意味を作らない。
  名前は業界の語 → 他のエンジン（迷ったら Bevy）の順に探す。動詞は `load`/`fetch` 外から取る（失敗しうる）・
  `build`/`compute` 計算して作る・`with` 新しい値を返す・`to` 作り直す / `as` 見方だけ変える（`is`/`get` は lint が見る）。
- **取り違えは型で止める**。外から作らせない値は pub mod の中の非 pub の enum + `pub type alias`、音の名前は
  `Sfx[Shot]` / `Loop[Hum]`（`/flix-docs`）。新しく作る型と、直すついでの所から使う（一度に全部は替えない）。
- **データは Doc・振る舞いはコード**。調整する数値・rows・色・**プレイヤーの目に入る文言**は Doc（コードには既定値だけ）。
  描き方・演出の形・ルールはコード。ロジックを JSON に書き始めたら設計の匂い。
- **テストはルール・進行・収支と、JSON とコードの橋渡しだけ**。期待値は Doc の既定値から導く（`/quality-assurance`）。
- 生成したコードは初学者が読める形に（読む順の README・毎フレームの流れの doc は `templates/` にある形を保つ）。
- 区切りごとに `NOTES.md` の先頭へ「今どこまで・次やること」を 3 行。広い探索はサブエージェントに任せ、結論だけ返させる。
- 絵を描く前に `.claude/rules/drawing.md` を読む。入口はドット絵 `/pixel-art`・格子に乗らない絵 `/smooth-render`。
  絵を委ねる親は prompt に「N 周まで」と文で書かず、drawing.md の「絵の周回」を指す（周を任せる時は snap の `--max N`）。
- 作業に入る前に当たるスキル（一覧は末尾）を読む。サブエージェントには rules とスキルの自動読みが効かないので、
  委ねる親は読ませる rules とスキルを prompt で名指しする。
- フックの無いエージェントは手で: 最初に `make status`・`.flix` を直すたび `make check`・clone ごとに `make hooks`。
  スキルの実体は `.claude/skills/<名前>/SKILL.md`（Codex は `.agents/skills/`・`.codex/hooks.json` は project trust の後に効く）。
- 「engine の `docs/…`」はゲームの `Makefile` の `ENGINE` が指す所にある。
