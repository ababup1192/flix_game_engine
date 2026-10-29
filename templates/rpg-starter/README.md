# ルーネの泉

flix_game_engine の王道 RPG のスターター。FC 風の見下ろしのフィールドと正面のコマンドバトル。
山あいの湖の村ルーネの泉が枯れ、村長の依頼を受けたルカが、鉱夫の娘ミナと見習い魔法使いトトを仲間にして
水晶の坑道（3 階層）の奥へ向かう。ボスを倒して帰ると泉がまた湧き、後日談とスタッフの字が流れる。
1 周は人の目安で 20 分台。

村・家・ワールドマップ（32×24）・森の岩穴・坑道 B1〜B3 の 10 マップ、仲間 3 人、雑魚 12 体（色違い 5）・番をする者 3 体・ボス、
呪文 3 つ、道具と装備、店と宿、1 枠のセーブ、仕掛け（岩と床のスイッチ・レバーと鉄格子・トロッコと分かれ目・暗い迷路とたいまつ・
落とし穴・水晶の順番と飛び石）、効果音 34 個と曲 6 本。値はほぼ全部 `assets/` の Doc にあり、保存すると走らせたまま変わる。

## 始め方

Flix コンパイラはエンジンリポの `bin/flix` ラッパ経由で呼ぶので、devbox shell の外でも動きます。
エンジンの場所が既定（生成時に埋め込み）と違うときは `ENGINE=/path/to/flix_game_engine` を付けてください。

| コマンド | 何をするか |
|---|---|
| `make run` | ゲームを起動する（ウィンドウが開く） |
| `make debug` | 保存即反映(watchFile)と F8 を有効にして起動 |
| `make check` | 型検査だけ（一番速い確認） |
| `make test` | テスト（規則・Doc・会話・音の表） |
| `make render SHOT=village` | その場面だけ `debug/village.png` へ描き出す（場面は `title village quest join world cave dungeon1 dungeon2 dungeon3 battle magic item equip boss clear ending`） |
| `make render-all` | ギャラリー PNG を全部 `gallery/` へ描き出す（決定的） |
| `make reference-check` / `make reference-update` | 描き出した絵をリファレンス画像と比べる / いまの絵で更新する |
| `make flow FLOW=e2e/quest_join.flow` | 手順書を画面なしで流す（`e2e/` に村・依頼・店と宿・ワールド・坑道 3 階・戦い・呪文・ボス・報告とエンディング） |
| `make bot` | 自動の通しプレイ。タイトルからエンディングまでを種を変えて流し、`debug/bot.md` に時間・戦った数・Lv を書く（`BOT_RUNS=10`） |
| `make balance` | つり合いのシミュレーション。出会いの組とボスを 500 種ずつ戦わせ、`debug/balance.md` に勝率・ターン・受けるダメージを書く |
| `make video` | 1 周を約 80 秒に縮めた紹介の動画 `debug/video/rune.mp4`（768×720・音つき。手順は `e2e/video.flow`） |
| `make talk-vocab` | 会話（`assets/talk/rune.yarn`）を直した後に木と語彙を書き直す |

## 遊び方

| 操作 | キー |
|---|---|
| 歩く・カーソル | 矢印 / WASD |
| 決定・話す・調べる・文字を出し切る | Z / Enter / Space |
| メニューを開く・取り消す | X / Backspace |
| 終了の確認 | Esc |

キーの割り当ては `assets/rpg.keys.json`。セーブは宿に泊まると `saves/rune.json` に 1 枠書き、「つづきから」は宿の前から始まる。
全滅するとお金が半分になり、宿の前で全快して起きる（宝箱・仕掛け・仲間はそのまま）。

## よく触る所

| やりたいこと | 触る所 |
|---|---|
| 数値（歩く速さ・文字送り・出会いの歩数・戦いの決まり・お礼の額・エンディングの秒） | `assets/rpg.rules.json` |
| マップ（地図の文字・出入口・人・小物・宝箱と仕掛け・出会いの組・曲） | `assets/maps/<名前>.map.json`（足すなら `MapDoc.names` にも 1 行） |
| 会話 | `assets/talk/rune.yarn` を書いて `make talk-vocab`。呼び名とメニューと戦いの伝言とエンディングの字は `assets/rpg.text.json` |
| 敵を足す | `assets/rpg.foes.json` に 1 行・技は `rpg.foe_moves.json`・出る所はマップの `encounter`。色違いは `rpg.recolors.json`。数は `make balance` で確かめる |
| 仲間の数値・覚える呪文・経験値の表 | `assets/rpg.party.json` |
| 道具と装備・店の品と宿代・呪文 | `assets/rpg.items.json`・`rpg.shops.json`・`rpg.spells.json` |
| 仕掛けを置く | マップ Doc の `objects` に 1 行（`lever` と `gate`・`rock` と `plate`・`cart` と `junction`・`crystal` と `bridge`・`chest`・`guard`・`sign`）。新しい種類はコードに足す（`MapDoc.ObjectKind`。手順は `AGENTS.local.md`） |
| 曲を替える・足す | 替えるならマップ Doc の `bgm`。足すなら `art/bgm.snd.star` に 1 曲書いて `bin/fge snd build art/bgm.snd.star` → `assets/bgm` と `project.json` の `sounds`・`Bgm.Track` |
| 効果音を足す | `art/sfx.snd.star` に 1 行 → `bin/fge snd build art/sfx.snd.star` → `assets/sfx` と `project.json` の `sounds`、鳴らすのは `Controls.soundOf` |
| 音量のつり合い | `assets/rpg.mixer.json` |
| ドット絵 | `assets/rpg.*.sprite.json`（色は `assets/rpg.palette.json` の FC の 54 色だけ） |

どれも `project.json` の `editor.resources` に schema 付きで並んでいて、Studio で開けばフォームから触れる。
コードの側で「これをしたい → どのファイル」は `AGENTS.local.md` の早見表が細かい（場面・ウィンドウ・仕掛け・会話・戦い・音・確かめ方）。

## つり合いの数

`make bot`（10 本）では 10 本ともエンディングに着き、人の目安（+ 仕掛けを考える時間）は 21:04〜28:37。全滅は 2 本（ボスの 1 回目・森の岩穴）。ボスの前で Lv 7（10 本のうち 5 本。8 が 4 本）、
ボスは Lv 7 で勝率 84%・12 ターン（たたかうだけでは 1%）。雑魚はその区間のルカの 2〜3 発、受けるダメージは中央値 30% 以下。
数の全部と、そう決めた理由は [docs/balance.md](docs/balance.md)。

## フォルダの地図

| 場所 | 中身 |
|---|---|
| `src/World*.flix` | 遊びの状態と規則（場面ごと: タイトル・フィールド・物・暗転・会話・メニュー・店・戦い）。読み始めは `src/World.flix` の冒頭の図 |
| `src/Battle*.flix`・`Party`・`Bag`・`Progress`・`Quest`・`Talk`・`Saves` ほか | 規則の部品（ダメージの式・経験値・持ち物・依頼の段階・会話の実行・セーブ） |
| `src/*Doc.flix`・`src/Res.flix` | Doc を読んで組む所（描く元はここにあり World には入れない） |
| `src/View*.flix`・`*View.flix`・`FieldScreen` | 絵（World → 描き物）。層の並びは `src/View.flix` の冒頭、重なり順は `src/ZOrder.flix` |
| `src/Main.flix`・`Game.flix`・`Controls.flix`・`Starts.flix`・`E2e.flix` | App の組み立て・入力と音の選び・始まりの場面の表・flow の語彙 |
| `src/render/` | 描き出し（`SceneRender`）と紹介の動画（`VideoRender`） |
| `src/sim/` | 自動の通しプレイ（`Bot*`）とつり合いのシミュレーション（`BalanceSim`） |
| `test/` | テスト（場面は `Fixtures.started`、キーは `Fixtures.play`） |
| `e2e/` | 画面なしで流す手順書（`*.flow`）と語彙 |
| `assets/` | Doc・マップ・会話・ドット絵・色票・効果音と曲・フォント |
| `art/` | 効果音と曲の台本（`*.snd.star`）・マップと絵を作った道具 |
| `reference/` | 退行検知（`SHA256SUMS.txt`・`ITEMS.tsv`）と Studio のジャンルカードの `title.png` |
| `docs/` | 設計（`DESIGN.md`）・つり合い（`balance.md`）・絵の設計（`ART_BRIEF.md`）・作った順の記録（`history.md`。作った時の記録で、写す時は読まなくてよい） |

## 写して自分のゲームにするとき

- 画風は最初に決め直して `AGENTS.local.md` の「この画面の画風」に書く（この FC 風は一例で、引き継ぐ物ではない。決め方は engine の `docs/art-ref/visual-dict.md`）。
- エンディングのスタッフの字（`assets/rpg.text.json` の `credits`）の「Flix Game Engine」「rpg-starter」の行を自分の名前に替える。

## AI エージェント向け指針の配布（sync-agents）

エンジン側で `make sync-agents GAME=/path/to/このゲーム` を実行すると、エンジン共通の
エージェント指針（agents-pack/AGENTS.core.md）とこのゲームの `AGENTS.local.md` を連結した
`AGENTS.md` が生成され、共通スキルが `.claude/skills/` にコピーされます。`AGENTS.md` は
生成物なので直接編集せず、ゲーム固有の原則は `AGENTS.local.md` に書いて再 sync してください。

## 字

- PixelMplus10（`assets/PixelMplus10-Regular.ttf`）— M+ FONT LICENSE。
