# 設計 — ルーネの泉（FC 風の王道 RPG テンプレート）

読み手: このテンプレートを写してゲームを作る人と、直す人。ここに書くのは決めた事・その理由・変えてはいけない事。
**型の中身（欄・case）の正はコード**で、ここには写さない（写すと古くなる）。各節の「正はコード」の行が指す名前を `bin/fge refactor show <Mod.名前>` で引く。
作った順番・フェーズごとの直し・テストプレイの指摘は `docs/history.md`、つり合いの最終の数は `docs/balance.md`、絵の設計は `docs/ART_BRIEF.md`。
形を変える時は、この文書も一緒に直す。

## 0. 前提と決まり

- 写経元: World の形は `templates/sound-novel-starter`（画面は enum の payload・Res に Doc・Yarn・セーブ）、
  App の組み立て・`Starts`・`ZOrder`・`E2e`・`test/` の並びは `templates/tidepool-starter`。
- 規約の本文: engine の `AGENTS.md`・`docs/flix-conventions.md`（World は遊びの状態だけ・payload は 1 case の enum で包む・
  match を入れ子にしない）・`docs/error-handling.md`・`docs/doc-conventions.md`（入れ子は 2 階層まで）・`/doc-design`・`docs/clock.md`・
  `docs/audio.md`・`docs/z-bands.md`・`docs/performance.md`・`/add-template`・`/quality-assurance`。
- **engine のコードは直さない。** 足りない物は 9 節の「相談事項」に積み、テンプレの中で書いた。

## 1. ゲームの流れ（遊びの 1 周）

目安は **1 周 20 分台**（人の目安。仕掛けを考える時間を含む）。ボスの前で Lv 7（つり合いは 5 節・最終の数は `docs/balance.md`）。

| # | 場所 | 起きる事 |
|---|---|---|
| 1 | タイトル | 「はじめから / つづきから」。セーブが無ければ「つづきから」は灰色で選べない |
| 2 | ルーネ村 | 枯れた泉の前で始まる。道具屋・宿屋・鍛冶屋・村長の家がある |
| 3 | 村長の家 | 依頼「泉が枯れてしもうた…」。**はい / いいえ**（いいえは「そこを なんとか」で同じ問いへ戻る）。はいで手付けとやくそう ×3 |
| 4 | 鍛冶屋の前 | 依頼を受けた後に話すと、鉱夫の娘 **ミナ** が加わる |
| 5 | 道具屋・宿屋 | やくそう・装備を買う。宿屋は泊まると HP / MP 全快し、**セーブを書く** |
| 6 | ワールドマップ（32×24） | 村の外周の端から外へ。**ほこら** の見習い魔法使い **トト** は杖をなくしている → 南の森の岩穴（レバーと鉄格子・番をする おやぶんモグ）で杖を取り戻して返すとトトが加わる。橋を渡って坑道の入口へ |
| 7 | 坑道 B1 | 岩の部屋（岩を床のスイッチへ押す）・分岐の広間のレバーとトロッコの分かれ目・ボルじい・下り階段 |
| 8 | 坑道 B2 | 暗い迷路とたいまつ・落とし穴・行商人コロンの店・中ボス くろがねゴブリン・宝箱の **ふるびたかぎ** |
| 9 | 坑道 B3 | 水晶を順に点けると飛び石が現れる地底湖・岩の部屋 2 とひとくいばこ・ミナの父。ふるびたかぎの扉の奥でボス **ジェムイーター**（逃げられない・HP 半分で技が変わる） |
| 10 | 帰り | 勝つと水脈が開く会話 → 暗転して坑道の入口（ワールドマップ）へ。村まで歩いて帰る（敵は出る） |
| 11 | 村 | 泉に水が戻り村人が集まっている。泉の上の村長に報告するとお礼 |
| 12 | エンディング | 後日談 → ぼうけんの きろく → スタッフの字が流れ、「おわり」。決定でタイトルへ（セーブは消さない） |

**先へ進む条件（門）**: 依頼を受ける前は村から出られない（村の出口で引き返す）。ミナが加わる前も出られない。
トトが加わる前は坑道の入口に入れない（「ほこらに だれか いたような…」）。門は「その仲間が加わっているか」の 1 種類で、
ミナは依頼の後にしか加わらないので、村の出口は gate = mina の 1 つで両方を止める（台詞は gateNode の中で `$quest` で分ける）。判定と台詞は 4.1・4.2。

**全滅**: 宿屋の前で目覚める（お金は半分・HP / MP 全快・旗と宝箱と手に入れた物はそのまま。ボスは生きたまま、挑み直せる）。
**フィールドで HP 0 の仲間**は隊列から抜ける（描かない・場所を詰める）。宿屋か、B3 のミナの父（`<<heal>>`）で治ると戻る。経験値は生きている仲間しか受け取らない。

## 2. World の形

### 2.1 層と向き

```
Main / Game / E2e / Starts / render/   ……… App の境目（どこを呼んでもよい）
   │
Controls（入力 → 規則の関数・Doc の読み直しの表・音の選び）
   │                          │
View（*View.flix）  ───→  規則の側（World・World*.flix・Battle・Party・Bag・Progress…）──→ Res（Doc と描く元）
```

- App の w は `Resources.With[Res.Res, World.World]`。規則は `(res, w)` で受け、Doc は `res#...` から読む。
- Res は World を使わない。View は World を丸ごと受けない（場面ごとの payload と Res だけを受ける）。

### 2.2 World の欄

**正はコード**: `World.World`（`src/World.flix`。欄ごとの意味は型の doc）。
- 一番上の欄は場面をまたぐ物だけ（場面・仲間・ふくろ・進み具合・乱数の回数・遊びの時計・実時間・終了の確認・出来事・セーブとその合図）。
  場面だけの値は 2.3 の payload へ入れる。11 個に抑え、`bin/fge record-wrap` の world-fields・world-resource に掛からない形にする。
- **仲間の加入の正は `Party`**（加わった順）。`Progress` は依頼の段階（quest）・開けた物（opened）・名前付きの旗（flags）だけを持ち、加入の旗を別に持たない。
- セーブは `save`（中身）と `saveRev`（書く合図）の 2 つ。`App.addOutput` は saveRev が変わった時だけ書く（4.8）。

### 2.3 場面（Scene）

**正はコード**: `World.Scene`（Title / Field / Battle / Ending）と、payload の `World.FieldRec`・`World.BattleRec`・`World.EndingRec`。
どの場面からどこへ移るかの図は `src/World.flix` の冒頭のコメント。
- 場面ごとの値は非 pub の 1 case の enum + `pub type alias` で包む（外から作らせない）。読む関数（`fieldRecOf` など）と書く関数（`mapField` など）を通す。
- 比べる・字にする用に名前だけの `SceneKind with Eq, ToString`（`World.sceneKindOf`）。
- 場面に入る関数は `World.enterField`・`WorldBattle.enter`・`World.enterEnding`・`World.toTitle` だけ。doc に `[遷移: X→Y]`。
- Battle と Ending は `FieldState` を中に持つ（戦いの後に戻る先・エンディングで下に描く報告した村）。
- フィールドの値のうち、マップを出ると戻す物（押した岩の `rocks`・たいまつの `light`）はセーブに書かない（セーブは明るい村の宿でだけ書く）。

### 2.4 重ねるウィンドウ（FieldWindow）

**正はコード**: `World.FieldWindow`（Closed / Talk / Menu / Shop / Notice）と、中の `World.TalkRec`・`World.MenuPage`・`World.ShopPage`・`World.NoticeState`。
- ウィンドウはフィールドの payload に 1 つだけ持つ。店は開いた会話（`TalkState`）を中に持ち、閉じるとその続きへ戻る（ウィンドウを Talk に戻すだけなので WorldShop は WorldTalk を呼ばない）。
- 取消で戻る先は 1 か所ずつ: メニューは `WorldMenu.parentOf`、店は `WorldShop.parentOf`、戦いは `WorldBattle.cancel`。
- `MenuPage` は 4.6 の手順と 1 対 1。

### 2.5 入力の層（InputLayer）

入力を受ける一番手前の層は `InputLayer.layerOf(w)` の 1 か所で決め、キーの振り分けはその値を match するだけにする。
**正はコード**: `InputLayer.Layer`。順は 終了の確認 → タイトル / エンディング → フィールド（暗転とトロッコの間は Busy・ほかは開いているウィンドウ（Talk / Menu / Shop / Notice）か Walking）→ 戦い（コマンドを選ぶ BattleChoose / 伝言を出す BattleMessage）。
- Busy の間は入力を捨てる。歩く関数は Walking の時しか呼ばない（2.8）。

### 2.6 乱数

`Math.Random` は使わない。`World#dice`（引いた回数）と `Hash01.at(dice, 用途の番号)` で引き、引くたびに 1 足す
（`Dice.roll(channel, w)`・`Dice.weighted`・`Dice.range` の 1 ファイル。用途は `Dice.Channel` の enum）。同じ操作の列は同じ結果になり、テスト・e2e・描き出しが毎回同じになる。
はじめからは `dice = 0`。`Starts` は `seed=N` で始めの値を変えられる。セーブにも入れる。
テンプレの `bin/lint-rules/forbid.local.json` で `RandomUtil.` と `Math.Random` を止める。

### 2.7 パーティ・持ち物・進み具合

- **仲間は固定の 3 人**: `pub enum Member with Eq, Order, ToString { case Luka case Mina case Toto }`。物語に結び付くのでコードに置き、数値は Doc。
- **正はコード**: `Party.Party`（中は非 pub。仲間ごとの `Party.Stats` と加わった順）・`Bag.Bag`・`Progress.Progress`。
  最大 HP・ちから等は **Lv と装備から導く**（`Party.maxHpOf`・`Party.atkOf` など）。World に導ける値を持たない。
  先頭は「加わった順で最初の生きている人」。
- 持ち物は `Map[ItemId, Int32]`（個数 0 は消す・12 種類まで）とお金 `gold`。装備している物はふくろに入れない。
- **依頼の段階は enum** `Quest { NotAsked | Accepted | BossDown | Reported }`。前の段階へは戻らない（`Progress.advanceQuest`）。
- 仲間の加入は `Party` の加わった順が正（Progress に別の旗を持たない）。宝箱と扉は `Set[(MapId, String)]`。

### 2.8 型で止める所

| 取り違え | 止め方 |
|---|---|
| Doc に無い道具・呪文・敵・マップの名前を World が持つ | `ItemId`・`SpellId`・`FoeId`・`MapId` は非 pub の enum + `pub type alias`。作れるのは各 Doc の `idOf(doc, name): Option[...]` だけ |
| 仲間を文字列で指す | `Member` の enum |
| マス（Grid.Cell）と画面の px | 規則は `Grid.Cell` だけ。px にするのは View の `FieldView.cellPx` だけ（forbid.local.json の rpg-no-px-in-rules が src/World* の Vec2 を止める） |
| 遊びの時刻と実時間 | 状態を進める時刻（歩き・暗転・点滅・宿・戦いの演出）は全部 `Clock.Time[Play]`。実時間は見た目だけ |
| 戦いの的 | `Battle.Target`（敵 1 体・敵全部・仲間 1 人・仲間全部）。呪文と道具は Doc の `aim` から作る |
| ウィンドウを開いたまま歩く | `InputLayer` が `Walking` の時しか歩く関数を呼ばない |

## 3. Doc（assets/*.json）の切り方

切る物差しは「いつ読み直したいか」。全部 `version`・`title`・スキーマ（sections 形式）を持ち、fail-open（既定値で続けたら 1 行言う）。
**入れ子は 2 階層まで**（record の欄 1 階層、または list / catalog の 1 行 1 階層。行の中に表を持たない）。
`project.json` の `editor.resources` に全部登録する。読み直しは `Controls.docTable` の `Resources.reloadRow`。

欄の正は各 Doc のスキーマ（`assets/*.schema.json`）と、Doc の頭の `note`。ここには何をどこに切ったかと、読み直した時に収める事だけ書く。

| ファイル | 中身 | 読み直しで収める（settle） |
|---|---|---|
| `assets/maps/<名前>.map.json` ×10（village・chief_house・inn・shop・smithy・world・toto_cave・mine_b1・mine_b2・mine_b3） | 1 マップ: 絵の組と曲・出会いの歩数・`rows`（1 文字 = 1 マス）・list の節（exits・npcs・objects（宝箱・扉・レバー・岩・床のスイッチ・格子・トロッコ…）・events・props・encounter。どれも 1 行は平らな欄だけ） | いるマップが消えたら始まりの場所（rules の `startMap / startX / startY`）へ。いるマスが壁になったら一番近い歩けるマスへ |
| `assets/rpg.party.json` | 3 人の初めの値と伸び・覚える呪文・経験値の表 | HP / MP を新しい最大に収める（戦いの最中なら Battle の party も） |
| `assets/rpg.foes.json` | 敵（雑魚・番をする者・ボス）の値・絵・色違い・逃げられないか・技が替わる HP | 戦いの最中なら敵の HP を新しい最大に収める |
| `assets/rpg.foe_moves.json` | 敵の技の重み（phase ごと。語彙は `attack / sweep / guard / sleep / spell`。spell は rpg.spells.json の呪文を唱える） | — |
| `assets/rpg.recolors.json` | 色違い（色票の鍵どうしの差し替え） | 色違いのアトラスを作り直す |
| `assets/rpg.spells.json` | 呪文 | — |
| `assets/rpg.items.json` | 道具と装備（効き目・値段・装備できる人） | ふくろの中の消えた道具を捨てる |
| `assets/rpg.shops.json` | 宿代と、店ごとの品（村の道具屋・B2 の行商人コロン） | — |
| `assets/rpg.rules.json` | 数の決まり（歩き・文字送り・暗転・戦いの式・出会い・始まりと宿の前・お金・暗い迷路・エンディングの字） | — |
| `assets/rpg.text.json` | 話し手の呼び名・戦いの伝言の型・メニューの項目名・知らせ・エンディングの字 | — |
| `assets/rpg.keys.json` | キー（決定・取消とメニュー・方向）。tidepool の `KeysDoc` を写す | — |
| `assets/rpg.mixer.json` | 曲 / 効果音 / UI のバス・効果音の間だけ曲を下げる・会話の snapshot | — |
| `assets/talk/rune.yarn` → `dialogue.json`・`vocab.json` | 会話（4.2） | 会話の最中なら閉じる |
| `assets/rpg.*.sprite.json`・`rpg.palette.json` | 絵の部品と色票 | — |

決めた事:
- **依頼のお礼の正は `rules.reward` の 1 か所**。払うのは `<<quest report>>`、台詞は `{$reward}` を埋め込む。手付けの 50G も `rules.advance` を `<<quest accept>>` が払う。
- **逃げられない事の正は `foes.noFlee` の 1 か所**。戦いの組に noFlee の敵が 1 体でもいれば逃げられない（曲もボス戦の曲になる）。
- **敵の大きさと高さ**は `foes.width / height / lift`。横の置き場は数で決める（1 体 = 中央、2 体 = 1/3・2/3、3 体 = 1/4・1/2・3/4）。
- **色違い**は `foes.recolor`（空なら元の色）で `rpg.recolors.json` の 1 行を指す。Res が `rpg.monsters.sprite.json` を色票の鍵を差し替えて作り直し、色違いごとのアトラスを持つ（4.4）。

**外に出さない物**（コードのまま）: タイルの文字 → 絵（`Autotile.Cell`）と通れるか（`Passage`）の表（`Tileset.flix`）、
ダメージの式・行動順・出会いの決め方・レベルアップの決め方・門の判定・ウィンドウの大きさと置き場・演出のタイミングの並び・3 人がいる事。

## 4. 仕組みごとの設計

### 4.1 マップの移動（`WorldField.flix`）

- **マス単位**。方向を押すと先頭が向きを変え、前のマスへ進めれば `stride = Walking(from, now)`（ほかの case はトロッコに乗る所と走っている間。正は `World.Stride`）。1 マスは `rules.secondsPerTile`（既定 0.22 秒）。
  押したままなら、着いたフレームで次の 1 マスへ続け、**次の startedAt は `Clock.after(secondsPerTile, 前の startedAt)`** にする（着いたフレームの now を使うと、1 フレームのはみ出しぶん 1 マス約 6% ずつ遅れ続ける）。1 フレームで 2 マスぶん進んだ時も同じ式で続けて数える。進めなければ向きだけ変える（ぶつかる音を 1 回）。
- 進めるか: `Tileset.passageOf(tileset, 文字)`（`Walk` / `Block` / `Counter`）・NPC のマス・マスにある物（扉・宝箱・岩・格子… 塞ぐかは `WorldObject` が種類ごとに決める）・**門**（下）。仲間は塞がない。
- **隊列**: 先頭が 1 マス進むたびに、先頭の前のマスを `trail` の頭に入れて `World.trailLength()`（3）つに切る。生きている 2 人目・3 人目がその順に立つ（HP 0 の人は描かず、後ろが詰める）。描く時は全員が同じ stride の進み具合で前のマスから今のマスへ動く。
- **カメラ**: `App.withCamera`（先頭の px。stride の途中も含む）+ `App.withCameraBounds`（マップの矩形。狭い軸は真ん中に置かれる）+ `App.withPixelSnap(_ -> 1.0)`。戦い・タイトル・エンディングは画面の中央・矩形は画面。
- **出入口**: `exits` の `at`（x, y）に着いた、または `edge` の向きでマップの外へ出ようとした → `transition` を置く。階段も同じ。
- **門**: exits の `gate`（仲間の名前 `mina / toto`。空なら無し）の仲間が加わっていなければ、そのマスへは進めず、向きだけ変えて `gateNode` の会話を開く。判定は `WorldField.closedGateAt` の 1 か所（Party の加わった順を見る）。知らない名前の gate はその出口の行ごと読めない扱い（書き損じで出口が黙って開かない）。
- **暗転と点滅（Transition）**: 持ち方は 1 つ。正は `World.Transition`（始まった時刻と、覆い切った時にする事 `World.TransitionThen`: 行き先へ移る・晴らす・宿・戦い・エンディング）。
  覆う → `then` を行う → 晴らす（FadeIn）の 2 枚に分け、長さは `WorldTransition.secondsOf`（`rules.fadeSeconds / flashSeconds / innSeconds`。戦いの前は点滅）。絵は `Transition.itemsAt` に進み具合を渡すだけ。覆っている間は `InputLayer.Layer.Busy`。
- **遊びの時計の止まる理由**: `pub enum Halt { case Asking }`。`World.paceOf` は ask が開いている間だけ `Clock.Run.Paused(Halt.Asking)`。メニューや会話では止めない（止めて困る物が無く、止めない方が単純）。
- **しらべる・はなす**: 決定で前のマスを見る。NPC なら会話、マスにある物なら `WorldObject.examine`（宝箱を開ける・扉の鍵を確かめる・レバーを引く…。知らせは `Notice`）、`Counter` の 1 マス先の NPC とも話せる（店・宿）。メニューの「はなす」「しらべる」も同じ関数。
- **イベントのマス**（`events`）: 着いたら `node` の会話を開く。台詞が 1 行も出ずに終わるノードならウィンドウは開かない（何度踏んでもよい。once の旗は持たない）。
- NPC は歩き回らない（その場で足踏み。話しかけると主人公の方を向く）。
- 使う engine: `Grid`・`Dir4`・`InputMap`・`Transition`・`Clock`・`App.withCamera / withCameraBounds / withPixelSnap`。

### 4.2 会話（`Talk.flix`・`WorldTalk.flix`）

- **Yarn を使う**（`bin/fge yarn build assets/talk`）。分かれ道（`-> はい` / `-> いいえ`）と `<<if>>` で、依頼の段階ごとの台詞を Doc だけで書ける。
- **旗の正は World**。World → YarnStorage の一方向だけ写す。写す変数（`Talk.SyncedVar`）: `$quest`（"none" / "accepted" / "bossdown" / "reported"）・`$mina`・`$gold`・`$innPrice`・`$toto`・`$reward`・だいじなものの `$has_<鍵>`。
  **会話を開く時・入力を 1 つ流す前・コマンドを 1 つ当てた後に写し直す**（`WorldTalk.syncVars`。`<<gold>>` の直後の `<<if $gold >= $innPrice>>` が新しい値を見る）。
  実行器（YarnRunner）はコマンドで止まらずに次の台詞まで流すので、`Talk.fromJson` が読む時にゲームのコマンドの直後へ `<<wait 0>>` を差し込み、
  `WorldTalk` はそこで止まった実行器へ写し直してから続きを流す（.yarn に `<<wait 0>>` は書かない。engine の実行器に「コマンドで止まる」口が入れば差し込みは要らなくなる）。
- **Yarn の `<<set>>` でこれらの変数を書かない**（書いても次の写しで消える）。TestDocs が dialogue.json を見て止める。会話の中だけの数える変数は `<<set>>` してよい。
- World を変えるのはコマンドだけ。**正はコード**: `Talk.Command`（doc にコマンドごとの意味）と `Talk.vocabOf`（`make talk-vocab`）。
  依頼の段階・お金・ふくろ・仲間・店・宿・戦い・扉・全快（`<<heal>>`）・トロッコ・移る・エンディング。
  依頼の段階を進めるのは `<<quest accept / defeat / report>>` だけ（前の段階が合わなければ何もしない）。ボスの後の段階は BossWon のノードの `<<quest defeat>>` が進め、
  そのあと `<<warp to_surface>>` で坑道の入口へ移る。
  ボスの前の会話（扉の奥の番をする者）は `$quest == "accepted"` の間だけ戦いを起こすので、全滅しても挑み直せる。
- TestDocs が dialogue.json の全コマンドの引数を Doc で引けるか見る（give の道具は items、open はそのノードを流すマップの objects の id（種類は問わない。扉と番をする者）、fight の敵は foes・ノードは Yarn、warp はマップの exits）。
- 1 行の台詞 = 1 枚のウィンドウ（4 行まで。幅 224px に折る。全角で 1 行 22 字）。収まらない台詞は TestDocs.testEveryLineFitsTheTalkWindow が止め、画面では後ろの 4 行を出す（先頭で切らない）。話し手があれば `むらおさ「…」` の形（呼び名は `rpg.text.json`）。
- 文字送りは `UiTypewriter`（`rules.cps`・Play の時計の dt）。決定で「出し切る」→ もう 1 回で次の行。1 フレームに決定は 1 回だけ使う。続きがあれば ▼。
- 選択肢は会話のウィンドウの右上に小さいウィンドウ（`gallery/quest.png` の形）。カーソルは `WorldTalk.moveCursor`。

### 4.3 出会い（`WorldField.countStep`）

- 1 マス歩き終えるたびに `stepsToFight` を 1 減らす。マップに `encounter` の行が無ければ減らさない（村・家・ボスの間）。
- 0 になったら組を `Dice.weighted` で 1 つ選び、点滅の Transition → `StartBattle`。次の歩数はマップの `minSteps..maxSteps`（無ければ rules の値）から引き直す。
- 1 戦の敵は 3 体まで（`foe1..foe3`。`rules.maxFoes` は描き場所の数で 3 固定、Doc はそれ以下にしか下げられない）。

### 4.4 コマンドバトル（`Battle.flix` = 式・`WorldBattle.flix` = 進め方・`BattleView.flix` = 絵）

進み方（DQ の型）: 生きていて眠っていない仲間全員の行動を先に選び、そのあと敵味方をすばやさ順に 1 つずつ実行する。

**正はコード**: 見せる側の値は `World.BattleRec`、進みは `World.Phase`（`Choose(仲間, CommandPage)` か `Show(今の Beat, 残りの Beat, 出し始めた時刻, AfterShow)`）。
コマンドのページは `World.CommandPage`、戦いの値は `Battle.Rec`、1 手は `Battle.BeatRec`（伝言の行・演出・その手の後の戦いの値）。
現れた時・1 ターン・勝ち / 全滅 / 逃げ切りの伝言はどれも Show で出し、出し終えた後にする事（AfterShow）で Choose へ戻るか勝ち負けを見るか戦いを終える。

- **式と見せ方の境目**: 1 ターン（全員の行動を順に実行するまで）は純関数 `BattleActs.resolveRound` が決め、Beat の列を返す。
  敵の行動の選び・行動順・眠り・guard・振り替え・ダメージ・倒れた事は全部この中。勝ち負けは `Battle.outcomeOf`、経験値とレベルアップは `Party.gainExp`、にげるは `BattleActs.tryFlee`。どれも時計とフレームを見ない。
  `WorldBattle` は見せる側: Choose で集めた plans を resolveRound に渡し、返った Beat を Play の時計で 1 つずつ伝言にする。HP の表示は今見せている Beat の `after` を読む（先に結果が出ない）。
  `BalanceSim`（5.5）も同じ resolveRound を呼び、フレームも時計も通さない。
- **戦いの間の正は `Battle.Rec` の party と bag**（World の party と bag は触らない）。勝った時・逃げた時に party と bag を一緒に World へ書き戻す（全滅の時は書き戻した後に全滅の決まりを当てる）。Doc を読み直した時は Battle.Rec の party と foes の両方を新しい最大に収める。
- resolveRound は敵が途中で全滅したら、そこで Beat を止める（残りの行動は流さない）。仲間が全滅した時も同じ。
- 取消は 1 つ前のページ（最初のページなら前の仲間の選び直し。`WorldBattle.cancel`）。コマンドは たたかう・じゅもん・どうぐ・ぼうぎょ・にげる（`World.BattleCommand`）。
- **呼び分け**: 同じ名前が 2 体以上なら `コケだまA` `コケだまB`（出た順）。敵の一覧のウィンドウは名前ごとに数を出す（`gallery/battle.png` の形）。
- **行動順**: `すばやさ × (1 + 0.25 × r)` の大きい順（r は Dice）。同じ値は仲間が先。
- **ダメージ**（数は rules）: `max(1, round((ちから − まもり ÷ 2) × (1 − spread + 2 × spread × r)))`、spread 既定 0.125。
  会心（`critRate` 既定 1/32。仲間の通常攻撃だけ）はまもりを 0 として 1.5 倍。呪文は `power × (0.9 + 0.2 × r)` でまもりを見ない。ヒールは最大 HP で止める。
- **guard**（敵の技）: その手番のうちに受けるダメージを半分（切り上げ）。手番の終わりに外す。
- **sleep**（ねぼけダケ・ふかねダケ）: 仲間 1 人を眠らせる（成功率 `rules.sleepRate`。眠っている人には効かない）。眠っている人は選ぶページを飛ばし、その人の手番の頭に Dice で `rules.wakeRate` 未満なら起きて動く（眠った次の手番は必ず眠る）。叩かれても起きない。戦いが終われば起きる。仲間が全員眠ったら敵だけが動く。
- **sweep**: 生きている仲間全員に `ちから × 0.6` の通常の式。
- 倒れた的への行動は、生きている別の的へ振り替える（いなければ飛ばす）。
- **にげる**: Choose で誰かが にげる を選んだら、その後の仲間は選ぶページを飛ばす（にげる はその人の手番で試し、失敗したら飛ばした仲間は何もしない）。率 = `fleeBase + (仲間の一番速い − 敵の一番速い) × fleeSlope` を 0.1..0.95 に収める。noFlee の組では「にげられない！」で手番を使う。
- **どうぐ**: 回復の物（`heal` / `mpHeal`）と、敵 1 体に `burn` のダメージを与える物（たいまつ・ばくだんいし）。どちらでもない物は戦いでは灰色。
- **敵の行動**: `rpg.foe_moves.json` の その敵の行（phase 1）から Dice で重み付きに選ぶ。HP が `phase2At`（割合。0 なら替えない）を切ると phase 2 の行に替える（ジェムイーター）。的は生きている仲間から Dice。
- **勝ち**: 経験値は敵の合計を、生きている仲間がそれぞれ全部受け取る。お金はふくろへ。`Party.gainExp` が表をまたいだ分だけ何レベルでも上げ、伸びと覚えた呪文を伝言にする。
- **全滅**: お金に `goldKeep`（0.5）を掛けて切り捨て、HP / MP 全快で宿の前へ。
- 伝言は 1 枚ずつ文字送りで出し、`messageWait` 秒で自動で次へ（決定で早送り）。
- 演出: 攻撃 `slash`・呪文 `fire` / `ice` / `heal`・当たり `hit`（battlefx のコマ）+ 敵の点滅。仲間が当たったら戦いの背景を 2px ずらす。1 手の演出の長さは `rules.fxSeconds`（時計は Play）、音は Beat から `WorldBattle.beatEventsOf` が出来事にする。
- 戦いの背景はマップの `battleBack`（`bg_plains` / `bg_cave` / `bg_lake`）。
- **色違いの絵**: Res が `foes.recolor` のある行ごとに `rpg.monsters.sprite.json` を「色票の鍵を差し替える resolver」で `PxSpriteAtlas.bake` し直し、テクスチャ `px_foe_<id>` として持つ（今は雑魚 5 体と番をする者 2 体の 7 枚）。

### 4.5 レベルアップ（`Party.flix`）

- 経験値の表（累計）は `rpg.party.json` の `exp`。上限は Lv 10。伸びは Lv ごとに固定（ぶれは付けない）。最大 HP / MP が増えた分だけ今の HP / MP も足す。
- 呪文は `learns`: トトがファイア（Lv1）・ヒール（Lv3）・アイス（Lv5）、ルカがヒール（Lv4）。ミナは持たない。

### 4.6 メニュー（`WorldMenu.flix`）

フィールドで X を押すと `Menu(Root(0))`。配置は `gallery/item.png`（左上に 2 列 × 3 行・右に一覧・下につよさ）。手順は 2.4 の MenuPage と 1 対 1。

| 項目 | ページの順 |
|---|---|
| どうぐ | Items → ItemTarget → 効き目の Notice（BackTo Items）。装備品を選ぶと「そうびで つけかえてね」、だいじなものは「つかえない」の Notice |
| じゅもん | SpellWho → Spells → SpellTarget → Notice。MP が足りなければ「MPが たりない！」 |
| つよさ | Status（左右で仲間を替える）。Lv・HP・MP・ちから・すばやさ・みのまもり・ぶき・よろい・ゴールド |
| そうび | EquipWho → EquipSlot → EquipPick（今の物はふくろへ戻す。付けられない人の物は出さない） |
| はなす / しらべる | 4.1 の決定と同じ関数 |

`gallery/item.png` の一覧ウィンドウの題「ルカ」は「どうぐ」に替わる（ふくろは 3 人で 1 つ）。

### 4.7 店と宿（`WorldShop.flix`）

- 店は `<<shop>>`（村の道具屋）/ `<<shop 名前>>`（`rpg.shops.json` の goods の shop。B2 の行商人コロンは mine）。かう / うる → 品 → 個数 → はい / いいえ。お金が足りない・ふくろが 12 種類で一杯なら灰色。売値は値段の半分（切り捨て）。だいじなものは売れない。
- 宿は `<<inn>>`。払えない時は Yarn の `<<if $gold >= $innPrice>>` で断る台詞へ分ける（コマンドは払える前提でだけ流す。払えないのに流れたら何もせず 1 行言う）。

### 4.8 セーブ（`Saves.flix`）

- **1 枠**・`saves/rune.json`（`version` 付き）。**再開する所は宿の前**（`rules.homeMap / homeX / homeY`。全滅の戻り先と同じ）。位置は書かない。
- 中身は仲間・ふくろ・進み具合・乱数の回数（正は `Saves.Rec`）。宿に泊まった時に World の `save = Some(今の中身)` にして `saveRev` を 1 足す。
  `App.addOutput` が実機のフレームの後で `save` を書く（テスト・flow・描き出しでは書かない）。
- 起動の時に Main が 1 回読み、`World.initial(save)` に渡す。壊れていれば `None` にして 1 行言う（「つづきから」は灰色）。
  「つづきから」は `save` の中身で party・bag・progress・dice を置き換え、宿の前で Field に入る。
- 読み書きは `Util.Json` の自前の符号（sound-novel の `Saves` を写す）。`saves/.gitkeep` を置く。

### 4.9 音（`Controls.soundOf` / `Controls.musicOf`・`Bgm`・docs/audio.md）

- 規則は音を鳴らさない。出来事 `Event` を `Emit` で出し、`Controls.soundOf` が名前を選ぶ。戦いの 1 手の出来事は `WorldBattle.beatEventsOf`（伝言と演出の種類から）、暗転の始まり（出会い・ボスの登場・宿）とお金の増減は `Controls` が前後の World を見比べて出す。
- **効果音**（音の下限の 4 種を必ず。`art/sfx.snd.star` → `assets/sfx`。34 個）: カーソル・決定・取消・ぶつかる・扉（鍵で開けるのも）・階段・宝箱・お金・レバー・床のスイッチ・岩・トロッコ・水晶（点く・消える）・宿・出会い・ボスの登場・攻撃・会心・叩かれた・呪文 3 種（炎・氷・回復。道具の炎と回復も同じ音）・眠り・逃げる・敵を倒した・全滅・レベルアップ・勝ちのファンファーレ・会話（開く・送る・字の声 3 つ。2 字に 1 回・UI のバス）。
- **曲**（`App.withSustained` で World から宣言。`art/bgm.snd.star` → `assets/bgm`。頭 + 輪のループ点つき）: タイトル（頭 1 + 輪 8 小節・21.6 秒）/ 村（8 小節・21.8 秒。家の中とエンディングも）/ ワールドマップ（8 小節・16.0 秒）/ 坑道（8 小節・25.3 秒）/ 戦い（頭 1 + 輪 8 小節・14.4 秒）/ ボス戦（頭 2 + 輪 8 小節・15.0 秒）。フィールドの曲はマップ Doc の `bgm`、戦いの点滅に入ったら戦いの曲、逃げられない敵（`noFlee`。中ボス・ひとくいばこ・ボス）ならボス戦の曲、勝ちと全滅の伝言の間は止める（ファンファーレと全滅の音が一発で鳴る）。
- **mixer**（`assets/rpg.mixer.json`）: music 0.45・sfx 1.0・ui 0.8。効果音の間は曲を 0.6 倍へ（ducks）。カーソルと会話の字は連打を間引く。終了の確認の間は snapshot `ask`（曲を籠もらせる）。曲は -16 LUFS・効果音は -22 LUFS で作り、バスで合わせる。
- 素材は全部 `bin/fge snd build` で合成する（効果音は矩形波と雑音、曲は矩形波 2 本 + 三角波 + 雑音。style は free・reverb や pan は使わない）。録音素材は混ぜない。

## 5. つり合いの土台（Doc の初めの値）

数はすべて Doc の既定値。テストは Doc から期待値を導くので、ここを変えてもテストは壊れない。目安:
**雑魚はその区間の Lv のルカが 2〜3 発で倒す / ボスは bot の着く Lv 7 で 10〜14 ターン・勝率 70〜85%・たたかうだけでは負ける / ボスの前で Lv 7 / 1 周は人の目安で 20 分台**（最終の数と、そう決めた根拠は `docs/balance.md`）。

### 5.1 仲間（Lv1 の値と 1 Lv ごとの伸び。装備を除く）

| 仲間 | joinLv | HP | MP | ちから | まもり | すばやさ | 伸び（HP / MP / ちから / まもり / すばやさ） | 初めの装備 |
|---|---|---|---|---|---|---|---|---|
| ルカ | 1 | 28 | 6 | 11 | 6 | 8 | 6 / 2 / 3 / 2 / 2 | ひのきのぼう・たびびとのふく |
| ミナ | 1 | 34 | 0 | 13 | 8 | 5 | 7 / 0 / 3 / 2 / 1 | つるはし・たびびとのふく |
| トト | 2 | 18 | 12 | 6 | 4 | 10 | 4 / 4 / 1 / 1 / 2 | かしのつえ・ローブ |

表の値はどの行も **Lv1 の値**。加わる時に joinLv まで伸びを足す（トトは加わった時 Lv2: HP 22・MP 16・ちから 7・まもり 5・すばやさ 12、経験値は表の Lv2 の 12）。

経験値の表（累計）: Lv2 12 / Lv3 35 / Lv4 75 / Lv5 140 / Lv6 240 / Lv7 420 / Lv8 600 / Lv9 820 / Lv10 1100。

### 5.2 道具と装備（値段 G）

| 名前 | 種類 | 値段 | 効き目 | 装備できる人 | 置き場 |
|---|---|---|---|---|---|
| やくそう | use | 8 | HP 30 | — | 村の店・コロン・宝箱（B1） |
| せいすい | use | 20 | 今は効き目なし（出会いを避ける仕組みを外した後も品と宝箱に残っている） | — | 村の店・コロン・宝箱（B3） |
| まりょくのみ | use | 30 | MP 10 | — | コロン・宝箱（B2） |
| たいまつ | use | 10 | 暗いマップで 120 歩の明かり・戦いで敵 1 体に 12 | — | コロン・宝箱（B2） |
| ばくだんいし | use | 40 | 戦いで敵 1 体に 40 | — | 宝箱（B3） |
| ふるびたかぎ / トトのつえ | key | — | B3 の扉 / トトに返す | — | 宝箱（B2）/ 森の岩穴 |
| ひのきのぼう / かしのつえ / つるはし | weapon | 10 / 10 / 20 | ちから +2 / +1 / +4 | ルカ / トト / ミナ | 初め |
| どうのつるぎ | weapon | 60 | ちから +6 | ルカ | 村の店 |
| てつのつるはし | weapon | 180 | ちから +9 | ミナ | 宝箱（B1） |
| はがねのつるぎ | weapon | 250 | ちから +11 | ルカ | 宝箱（B2） |
| たびびとのふく / ローブ | armor | 10 / 10 | まもり +2 | 3 人 / トト | 初め |
| かわのよろい | armor | 70 | まもり +5 | ルカ・ミナ | 宝箱（B1）・村の店 |
| まほうのローブ | armor | 80 | まもり +5 | トト | 宝箱（B2） |
| みずのはごろも | armor | 300 | まもり +8 | 3 人 | 宝箱（B3） |

値は `rpg.items.json`・品は `rpg.shops.json`・宝箱はマップの objects が正（この表は今の値を写した物。変えたら一緒に直す）。
宿代 6G。初めのお金 50G + 手付け 50G = 100G で買えるのは、どうのつるぎとやくそう 4 つ（92G）まで。強い装備は坑道の宝箱で手に入る（店で買う物は どうのつるぎ と 2 つ目の かわのよろい だけ）。

### 5.3 敵（雑魚 12 体・番をする者 3 体・ボス）

色違いは FC の定番の作り（同じ絵の色票を差し替え、強い方を奥へ）。名前は絵の側（ART_BRIEF・sprite の note）にそろえ、色違いには新しく付けた。

| id | 名前 | 絵（色違い） | Lv | HP | ちから | まもり | すばやさ | 経験値 | お金 | 技 | 出る所 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| kusausa | くさウサ | bunny | 1 | 16 | 9 | 4 | 7 | 3 | 3 | attack | ワールド |
| neboke | ねぼけダケ | shroom | 2 | 16 | 10 | 6 | 3 | 4 | 4 | attack 3・sleep 1 | ワールド |
| koke | コケだま | koke | 2 | 20 | 11 | 10 | 4 | 5 | 5 | attack | ワールド・B1 |
| hanausa | はなウサ | bunny（桃） | 3 | 20 | 11 | 6 | 10 | 6 | 6 | attack | ワールド（北） |
| koumori | 坑道コウモリ | bat | 3 | 26 | 14 | 8 | 12 | 8 | 6 | attack | B1・B2 |
| horimogu | ほりモグ | mole | 4 | 30 | 16 | 12 | 6 | 10 | 8 | attack 3・guard 1 | B1・B2 |
| fukane | ふかねダケ | shroom（紫） | 5 | 32 | 17 | 12 | 4 | 12 | 10 | attack 2・sleep 1 | B2 |
| goblin | つるはしゴブリン | goblin | 5 | 40 | 20 | 14 | 9 | 15 | 12 | attack | B2・B3 |
| hinoko | ひのこコウモリ | bat（赤） | 5 | 34 | 16 | 12 | 14 | 14 | 10 | attack 3・spell fire 1 | B2 |
| shouyado | ショウヤドカリ | hermit | 6 | 50 | 22 | 24 | 5 | 20 | 15 | attack 2・guard 1 | B3 |
| akabou | あかぼうしゴブリン | goblin（赤） | 7 | 50 | 20 | 18 | 10 | 24 | 18 | attack 3・sweep 1 | B3 |
| koriyado | こおりヤドカリ | hermit（青） | 7 | 54 | 23 | 22 | 6 | 24 | 16 | attack 1・spell ice 1・guard 1 | B3 |
| gemeater | ジェムイーター | boss | 10 | 560 | 40 | 22 | 9 | 200 | 0 | 1: attack 1・sweep 1 / 2（HP 50% 未満）: attack 3・sweep 1 | B3 の奥・noFlee |

番をする者（会話の `<<fight>>` で戦う固定の戦い。逃げられない）: 森の岩穴の おやぶんモグ（mole の色違い。Lv6・HP 90）・B2 の くろがねゴブリン（goblin の色違い。Lv8・HP 190）・B3 の ひとくいばこ（Lv7・HP 190）。
数は `rpg.foes.json` と `rpg.foe_moves.json` が正（この表は今の値を写した物。`make balance` で直した数の移り変わりは `docs/history.md`）。

呪文（rules ではなく spells）: ファイア MP3 力 14（敵 1）/ ヒール MP3 回復 30（味方 1）/ アイス MP5 力 10（敵全部）。敵が使う fire / ice も同じ値。

### 5.4 戦う回数の見積もり（逆算）

出会いの間隔 12..20 歩（平均 16 歩）。1 戦の敵は平均 2.2 体。
（今の値はワールドマップ（rules）7..11 歩・B1 26..38 歩・B2 と B3 30..44 歩。下の表は逆算の見積もりのまま残し、
bot の実測と並べた表は `docs/balance.md` にある。実測で B3 が 2 戦多いのは、仕掛け（岩の部屋・水晶・小島）で歩く数が増えたため。）

| 区間 | 歩く数 | 戦う数 | 1 戦の経験値 | 区間の経験値 | 累計 | Lv（ルカ・ミナ） | 1 戦のお金 | 区間の稼ぎ | 使う | 手持ち |
|---|---|---|---|---|---|---|---|---|---|---|
| 村（出発前） | — | 0 | — | 0 | 0 | 1 | — | 100（初め 50 + 手付け 50） | 92（どうのつるぎ・やくそう ×4） | 8 |
| ワールド（行き） | 40 | 2.5 | 4.5 × 2.2 ≒ 10 | 25 | 25 | 2 | 4.5 × 2.2 ≒ 10 | 25 | 0 | 33 |
| B1 | 64 | 4 | 7.7 × 2.2 ≒ 17 | 68 | 93 | 4 | 6.3 × 2.2 ≒ 14 | 56 | 0 | 89 |
| B2 | 80 | 5 | 12.8 × 2.2 ≒ 28 | 140 | 233 | 5（6 の手前） | 9.2 × 2.2 ≒ 20 | 100 | 0 | 189 |
| B3（扉まで） | 60 | 4 | 22.7 × 2 ≒ 45 | 180 | 413 | 6 | 15.3 × 2 ≒ 30 | 122 | 0 | 311 |
| 帰り・報告 | 50 | 3 | — | — | — | 6 | — | +300（お礼）+ 戦い | 宿 6 | 600 前後 |

お金は村を出た後に使い道が少ない（宿とやくそうだけ）。坑道から村へ戻って泊まる・やくそうを買い足す道は残すが、つり合いはそれをしない前提で組む（bot もしない）。余ったお金は FC の王道どおり、エンディングで見せる数にとどめる。

トトは Lv2（経験値 12）で加わり、その後は同じ経験値を受けるので、ボスの前で同じく Lv 6。

確かめは「初めの装備 + 村で買える物（どうのつるぎ）+ 宝箱の装備（かわのよろいはルカ・まほうのローブはトト）」で計算する。ミナは最後まで つるはし（+4）。
- 雑魚: ルカ Lv6 のちから 26 + 6 = 32。あかぼうしゴブリン（まもり 18）へ 23 → 3 発。ショウヤドカリ（まもり 24）へ 20 → 3 発。つるはしゴブリンへ Lv5 のルカ（29）で 22 → 2 発。
- ボス: ルカ 21・ミナ（28 + 4 = 32）21・トトのファイア 14 で 1 ターン 56 前後。360 ÷ 56 ≒ 6.4 ターン。ヒールに 1〜2 ターン使って 7〜8 ターン。
- ミナの受けるダメージ: まもり 8 + 10 + 2 = 20 → ボスから 24。HP 34 + 35 = 69 で 3 発。
- ボスから: ルカのまもり 16 + 5 = 21 → 34 − 10.5 ≒ 24（HP 58 で 2〜3 発）。sweep は 1 人 10 前後。ヒールとやくそうで持ち直せる強さ。
- この表は見積もり。実際の数は 5.5 の bot と `make balance` で測って比べ、外れたら Doc（出会いの歩数・経験値・敵の値）だけで直す。

### 5.5 テストプレイ（シミュレーション）— 3 つの道具

見積もり（5.4）を数で確かめるため、**3 つの道具を作って流す**。どれも画面なしで、実機と同じ規則と Doc を通す。

**1. 自動の通しプレイ（bot）— `make bot` → `debug/bot.md`**

- 置き場: `src/sim/Bot.flix`（道筋の表と、キーの決め方）・`src/sim/BotRoute.flix`（道の計算: マップの間の最短・マップの中の幅優先・トロッコとレバーの寄り道）・
  `src/sim/BotBattle.flix`（戦いの方針。BalanceSim も使う）と `src/sim/BotRun.flix`（入口・レポート）。依存は Bot → BotRoute・BotBattle の一方通行。入口は `BotRun.play`（`make bot`）。
- **手は実機と同じ経路で流す**: bot は毎フレーム World を見てキー（方向・決定・取消・メニュー）を 1 つ決め、`App.traceFrame` で `Game.app` に 1 フレームずつ流す（Flow と同じ経路）。規則の関数を直に呼ばないので、入力の層・門・ウィンドウの詰まりもそのまま見つかる。dt は 1/60 秒で固定。
- **方針（決め打ち）**:
  - 何をするかは `Bot.goalOf` の 1 か所で決める: 割り込み（下）が無ければ、道筋の表 `Bot.stepsOf`（上の行ほど先。依頼を受ける → ミナ → どうのつるぎ → 森の岩穴 → トト → 坑道の宝箱と仕掛け → ボス）の最初の済んでいない行。全部済めば村長に報告する。
  - 歩き: マップの間は exits をつないだ図の最短、マップの中は `GridSearch.distances`（通れるかは規則と同じ `WorldField.canEnter`）の最短。宝箱は道の途中にある物だけ開ける。
  - 戦い（`BotBattle.battlePlans`）: HP 35% 未満の仲間を回復の呪文 → やくそう・逃げられない組では攻めの呪文 → ばくだんいし・ほかは たたかう（的は HP の一番少ない敵）。にげない。
  - 割り込み（`Bot.interruptOf`。道筋より先）: ふくろに付けられる良い装備 → 村の外で倒れた仲間がいれば起こしに行く（`Bot.reviveOf`: 出入口の数でミナの父が宿より近ければ父、ほかは宿）→ 村の外で HP 60% 未満なら回復の呪文 → やくそう → 村で HP 60% 未満なら宿。
    倒れた人を起こさないと、経験値を受け取れずにその人だけ Lv が止まる。全滅したら宿の前から goalOf をやり直す。
  - 歩いて着けない時の寄り道（`BotRoute.detourOf`）: 乗れるトロッコ → 分かれ目を替えるレバー → 格子を上げるレバー（B1 の帰りの近道）。
  - 会話: 文字送りは決定で進め、はい / いいえは「はい」。
- **詰みの判定**: 戦いの中の時間は数えない。フィールドにいる間の Play の時計で 60 秒、「目的地までの残りのマス数（マップの間はつないだ図の残りの出入口の数 × 100 + マップの中のマス数）」が一番小さかった値より縮まなければ「詰んだ」として、その時の World の指紋と goal を書いて終わる。
  `GridSearch.distances` はマップか goal が変わった時だけ引き直し、bot の値に持つ（毎フレーム引かない）。
- **確かめる事**（レポートに出す）: 詰まない・タイトルからエンディングまでのゲーム内時間（Play の時計）・区間（ワールド行き / B1 / B2 / B3 / ボス / 帰り）ごとの戦った回数と、区間に入った時の 3 人の Lv（倒れている人に †）・人の目安の時間・全滅の回数と場所・終わりの装備とお金と使う物と MP。
- **終了コード**: エンディングに着けば 0、詰めば 1。`BOT_SEED=n`（dice の始めの値。既定 0）・`BOT_RUNS=n`（種を変えて n 本流し、表を並べる。make の既定 5）。
- **1 本目の流した手は `debug/bot/playthrough.flow` に書く**（`make flow FLOW=debug/bot/playthrough.flow` で流し直せる。動画は別の手順 `e2e/video.flow`）。区間の頭ごとに `mark <区間>` と、その時に立っているはずの値の `expect quest=…` と `expect map=…` を書く（問いの名前は E2e の probes。動画で流し直した時に区間がずれたらそこで止まる）。
  Flow の `drive` を使わないのは、drive が「詰んだ理由」を返せないため。
- 1 本の重さの目安: 15 分 = 54000 フレーム。画面なしで 1 分以内を目標にする。超えたら BOT_RUNS の本数を並列に流す（1 本ずつ別のスレッド。World は純粋なので本どうしは混ざらない）。1 本の中のフレームはまとめない。

**2. つり合いのシミュレーション — `make balance` → `debug/balance.md`**

- 置き場: `src/sim/BalanceSim.flix`。戦いだけを流す。**`BattleActs.resolveRound`（4.4）を直に回し、フレームも時計も `WorldBattle` も通さない**。plans は bot と同じ戦いの方針（`BotBattle.battlePlans(res, rec)` を Field の bot と分けて pub にする）。
- 区間ごとのパーティは `src/sim/BalanceSim.flix` の表で決める（5.4 の各区間の Lv と、その時に持っているはずの装備・やくそうの数。bot のレポートの値で書き直してよい）。
- 流す物: 各マップの encounter の組ぜんぶ × 500 種（`dice` の始めの値を変える）、ボス戦 × 500 種を Lv 6 / 7 / 8 で（ボスの組は「たたかうだけ」= `BotBattle.attackOnlyPlans` の行も並べる）。合わせて約 14000 戦・7 万ターン。**全部の表で 1 分以内**を目標にする（超えたら種の数を `BALANCE_SEEDS` で下げられるようにする。既定 500）。
- レポートの中身（区間ごと・組ごとの表）: 勝率・ターン数（中央値と 9 割の値）・受けたダメージ（最大 HP に対する割合の中央値と 9 割の値）・全滅の率・使った MP とやくそう。
  敵ごとに「その区間の Lv のルカの たたかう で倒れるまでの回数」（中央値）。
- **5 節の目安と照らす**: 雑魚はルカの 2〜3 発 / ボスは bot の着く Lv 7 で 10〜14 ターン・勝率 70〜85%・たたかうだけの勝率 40% 以下/ 雑魚 1 戦の受けるダメージは中央値で最大 HP の 30% 以下。外れた行に `⚠` を付けて並べる。
- **テストではなく知らせる口**（重いので `make test` に入れない。終了コードはいつも 0）。外れたら Doc の数だけで直して流し直す。コードの式は直さない（直す時はこの文書を先に直す）。

**3. 紹介の動画 — `make video` → `debug/video/rune.mp4`**

- 置き場: `src/render/VideoRender.flix`（Makefile の `video` は `templates/tidepool-starter` の形を写した）。手は `e2e/video.flow`（git に入る）を e2e と同じ flow の実行器で 60 fps で流し、音は同じフレームの出来事とミキサー（曲は宣言・効果音は出来事）から混ぜる。
- 1 周を全部は撮らない。**区間は flow の `mark in_<名前>` と `mark out_<名前>` で切る**（タイトル・依頼・ミナ・ワールド・トロッコ・たいまつ・戦い・ボス・ボスの後・報告・エンディングの頭と終わりの 12 区間）。区間ごとに Starts から始め直し、手は全部流して撮る区間だけを並んだ順につなぐ。約 80 秒。
- 768×720（256×240 の 3 倍・ドット絵なので整数倍）・30 fps。GPU のある所は 30 秒ほど、無い所（SoftRaster）は 1 コマ 0.2〜0.5 秒。途中で止まったら `FGE_VIDEO_PAINT=frames:A-B` で残りだけ塗る。
- 撮る区間を増やす・替える時は `e2e/video.flow` だけを直す（`make flow FLOW=e2e/video.flow` で手が通るかを先に見る）。

## 6. 絵の組み立て（タイル層と重なり順）

**地面はタイル層**: `App.withTileLayers` に、マップごとに 1 つの `TileLayerSpec`（`key` = MapId の名前・tiles は鍵が変わった時だけ組むサンク）を渡す。
描き出しとテストは `TileScene.toItems` で同じ絵を出す。**水と岸（コマ送りのある `Edged`）と泉・たいまつ・人・小物は動く側**で、見えているマス（`Grid.cellsIn`）だけ描く。

View のファイル: `View.flix`（場面で振り分ける入口・画風の層の並びを頭に書く）・`TitleView`・`FieldScreen`・`BattleView`・`MenuView`・`ShopView`・`EndingView`。

**重なり順（`ZOrder.flix`・docs/z-bands.md）**:
- world の層の正は `ZOrder.Layer`（奥から 地面・家の影・地面に重ねる物・人と小物・暗いマップの墨・戦い）。人と小物の層は人・小物・屋根を `ZStack.zIndex(Depth.orderAt(足元の y), ZStack.leaf(部品))` で並べる（屋根は家の足元の y を持つので人より手前に出る）。Battle は背景 → 敵 → 演出を積んだ順。
- HUD の `ZOrder.HudLayer`（Window・Transition・Prompt）: 会話・メニュー・店・戦いのコマンドは Window、暗転と点滅は Transition、Esc の確認は Prompt。`App.withHudView` に繋ぐ（カメラで動かない）。
- z の数は `ZOrder` の `zRange` だけに書き、ほかは積んだ順で決める。

## 7. ファイルの割り方

| 分け | `src/` のファイル |
|---|---|
| 規則（World と場面ごと） | World・WorldTitle・WorldField・WorldObject・WorldTransition・WorldTalk・WorldMenu・WorldShop・WorldBattle |
| 規則の部品 | Battle・BattleActs・Party・Member・Bag・Progress・Quest・Flag・Dice・Rail・Talk・Saves・InputLayer・DirName |
| Doc と描く元 | Res・MapDoc・PartyDoc・FoesDoc・FoeMovesDoc・RecolorsDoc・SpellsDoc・ItemsDoc・ShopsDoc・RulesDoc・TextDoc・KeysDoc・Tileset・Autotile・MapArt・Sheet・Palette |
| 絵 | View・ViewField・ViewMenu・ViewBattle・TitleView・FieldScreen・FieldView・WindowView・MenuView・ShopView・BattleView・EndingView・PromptView・ZOrder |
| App の境目 | Main・Game・Controls・Bgm・Starts・E2e・Drive |
| `src/render/` | SceneRender（場面の PNG）・VideoRender（紹介の動画）・VideoAuditEntries（生成物） |
| `src/sim/` | Bot・BotRoute・BotBattle・BotRun（自動の通しプレイ）・BalanceSim（つり合い） |

合わせて src 1 万行・test 2500 行ほど。1 ファイル 400 行が目安で、超えたら割れる所を探す。
例外は、場面の型を 1 か所に集めた `World`（型と図のコメントが本体）と、Doc の読み手（`MapDoc`・`TextDoc`。欄ごとの読み方が並ぶだけ）。
`WorldBattle` も 400 行を少し超えている（コマンドのページの動きと伝言の見せ方。割るなら見せ方の側）。

## 8. 決まった事（依頼主の決定）

| 事柄 | 決定 |
|---|---|
| トトが加わる所 | ワールドマップのほこら |
| 装備 | 入れる（武器と鎧） |
| ボスの後 | 暗転で坑道の入口へ戻し、ワールドマップを歩いて帰る |
| ワールドマップの広さ | 32×24（2×2 画面） |
| セーブ | 宿に泊まると 1 枠に書く。再開は宿の前 |
| 全滅 | お金半分・宿の前で全快 |
| 曲 | 6 本 + ファンファーレ。全部合成 |
| 敵の種類 | 雑魚 12 体（絵 7 + 色違い 5）+ ボス。名前は絵の側にそろえ、色違いには新しい名前 |
| 宿屋の主人 | `woman` の絵を兼ねる |
| フィールドで HP 0 の仲間 | 隊列から抜ける（描かない） |

色違いの名前（はなウサ・ふかねダケ・ひのこコウモリ・あかぼうしゴブリン・こおりヤドカリ）は依頼主に見せて決めた。

## 9. engine への相談事項（独断で前提にしない）

1. **決まった種の乱数**: `RandomUtil` は `Math.Random` なので、テンプレでは `Hash01` + World の回数（`Dice`）で引く。2 本目のゲームでも要れば engine に足すかを相談する。
2. **マス単位の移動と隊列の追従**: engine に無い（`make module Q=GridMove` は当たり無し）。テンプレの `WorldField` に書き、別のゲームが要った時に engine へ移すかを相談する。
3. **旧 rpg-starter を指す engine の設定と文書**（済み。依頼主の承認を取ってから直した）: `bin/lint-rules/record-wrap.json` の除外 2 行（消す）・`docs/modules/map.md`（TownMap.flix）・`ui.md`・`time.md`・`light.md`（World.flix / View.flix）・`docs/shader-doc.md`（town.shader.json）・`docs/backlog.md`（新しいファイルへ指し直すか、別のテンプレの実例へ替える）。
4. **タイル層の Tileset**（済み。テンプレの中で組めた）: `TileLayerSpec` の `Tileset` を `PxSpriteAtlas` のアトラスから作る道が無ければ、作る関数を engine に足すかを相談する（それまでは地面も動く側で、見えているマスだけ描く。17×16 マス + 縁と人と小物で 800 未満に収まるので、どちらの道でも足りる）。
5. **色違い（パレット差し替え）**: 済み（相談は要らない）。`PxSpriteAtlas.bake(doc, resolver)` の resolver で色票の鍵を差し替えれば足りる（4.4）。
6. **会話の実行器をコマンドの後で止める口**（依頼主へ相談。今は足さない）: `YarnRunner` はコマンドで止まらずに次の台詞まで流すので、
   テンプレは `Talk.fromJson` で木の JSON にゲームのコマンドの直後の `<<wait 0>>` を差し込んで止めている（木の JSON の形に寄りかかる）。
   engine の実行器に「wait 以外のコマンドの後で止まる」選べる口があれば差し込みが要らなくなる。別のゲームで同じ物が要った時に足すかを決める。
   それまでは `TestQuest.testGoldLineAfterAcceptShowsTheNewGold`（本物の dialogue.json）と `testGoldIsCopiedBeforeTheNextIf` が差し込みを守る。
7. agent-eval: `agents-pack/agent-eval/engine.json` に RPG のお題（「敵を 1 体足す」「NPC の台詞を依頼の段階で変える」）を 1〜2 本足してよいか。
   → 依頼主の決定（2026-10-29）: 足さない。

## 10. 危険（重くなる所・壊れやすい所）

- **型の推論の破綻**: 戦いの 1 手を 1 つの関数に詰めると `Expected X, Got X` が出る。段階（Choose / Show と、Show の後の AfterShow）ごとに関数を分け、`match` を入れ子にしない。
- **World の型の大きさ**: FieldRec・BattleRec・Battle.Rec・Beat・Party・Bag・Progress・SaveData は 1 case の enum で包む。`bin/fge record-wrap`（`make lint`）が止める。
- **毎フレームの描き物の数**: ワールドマップを全部動く側で描くと 1500 を超える。地面はタイル層、動く側は見えているマスだけ。
- **毎フレームの Doc の引き直し**: マップの格子を毎フレーム `List[String]` から引かない。Res を作る時に `Vector[Vector[Char]]` と通れるかの表へ作り直して持つ。
- **Yarn と World の二重の正**: World → Yarn の一方向・コマンドごとに写し直す・`<<set>>` を TestDocs で止める（4.2）。
- **乱数の決まり**: Dice 以外の乱数を `forbid.local.json` で止める。
- **bot が遅い・すぐ詰む**: 54000 フレームを 1 フレームずつ App に流すので、1 本 1 分を超えるかもしれない。超えたら BOT_RUNS を並列にする（1 本の中のフレームはまとめない）。詰みの判定が厳しすぎて誤って止まる時は、レポートの World の指紋で原因を見てから緩める。
- **bot の方針がゲームに寄りかかる**: goalOf の表が依頼の段階の並びを写すので、流れを変えたら表も直す。bot が通ることは「人が通れる」の証明ではない（会話の分かれ道で「いいえ」を選ぶ道は e2e の側で見る）。
- **色違いのアトラスの数**: 色違い 1 体ごとにテクスチャが 1 枚増える。今の 7 枚より増やす時は Res の作り直しの重さを測ってから。
