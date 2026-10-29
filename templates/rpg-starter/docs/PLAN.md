# 実装計画 — ルーネの泉（FC 風の王道 RPG テンプレート）

読み手: 実装担当とレビュー役。絵の段階（`docs/ART_BRIEF.md`・`gallery/*.png` の 12 場面）が終わった所から、
遊べるゲームにするまでの道筋を決める。ここに書いた事は「決めた事」。変える時はこの文書を先に直す。

## 0. 前提と決まり

- 写経元: World の形は `templates/sound-novel-starter`（画面は enum の payload・Res に Doc・Yarn・セーブ）、
  App の組み立て・`Starts`・`ZOrder`・`E2e`・`test/` の並びは `templates/tidepool-starter`。
  場面の表と判断の関数を 1 か所に集める書き方は `../../../internet_dungeon/docs/world-map.md`。
- 規約の本文: engine の `AGENTS.md`・`docs/flix-conventions.md`（World は遊びの状態だけ・payload は 1 case の enum で包む・
  match を入れ子にしない）・`docs/error-handling.md`・`docs/doc-conventions.md`（入れ子は 2 階層まで）・`/doc-design`・`docs/clock.md`・
  `docs/audio.md`・`docs/z-bands.md`・`docs/performance.md`・`/add-template`・`/quality-assurance`。
- **engine のコードは直さない。** 足りない物は 11 節の「相談事項」に積み、テンプレの中で書いて進める。
- 1 フェーズ = 1 回のレビュー（90 点）。フェーズの終わりに `make check`・`make test`・`make render-all` が緑。

## 1. ゲームの流れ（遊びの 1 周）

目安は **1 周 15 分**（10〜20 分の真ん中）。ボスの前でレベル 6 前後（つり合いの逆算は 5 節）。

| # | 場所 | 起きる事 | 目安 |
|---|---|---|---|
| 1 | タイトル | 「はじめから / つづきから」。セーブが無ければ「つづきから」は灰色で選べない | — |
| 2 | ルーネ村 | 枯れた泉の前で始まる。村人が「むらおさが よんでいたよ」と言う。道具屋・宿屋・鍛冶屋・村長の家がある | 1 分 |
| 3 | 村長の家 | 依頼「泉が枯れてしもうた…」。**はい / いいえ**（いいえは「そこを なんとか」で同じ問いへ戻る）。はいで 50G とやくそう ×3 | 1 分 |
| 4 | 鍛冶屋の前 | 依頼を受けた後に話すと、鉱夫の娘 **ミナ** が加わる。受ける前は「父ちゃんの坑道は いま あぶないよ」 | 0.5 分 |
| 5 | 道具屋・宿屋 | やくそう・せいすい・装備を買う。宿屋（主人は `woman` の絵）は泊まると HP / MP 全快し、**セーブを書く** | 1.5 分 |
| 6 | ワールドマップ（32×24・2×2 画面） | 村を出て北へ。途中の **ほこら** で見習い魔法使い **トト** が加わる。橋を渡って坑道の入口へ。草原の敵と 2〜3 回戦う | 2.5 分 |
| 7 | 坑道 B1 | トロッコのレール・たいまつ・宝箱（たいまつ・やくそう・**かわのよろい**）・下り階段 | 2.5 分 |
| 8 | 坑道 B2 | 広めの迷路。宝箱に **ふるびたかぎ**・まりょくのみ・**まほうのローブ** | 2.5 分 |
| 9 | 坑道 B3 | 水晶の地底湖。封じられた扉はふるびたかぎで開く。扉の奥でボス **ジェムイーター** | 2.5 分 |
| 10 | 帰り | 勝つと水脈が開く会話 → 暗転して坑道の入口（ワールドマップ）へ。村まで歩いて帰る（敵は出る） | 1 分 |
| 11 | 村長の家 | 泉に水が戻っている。報告すると「300G を うけとった」 | 0.5 分 |
| 12 | エンディング | 泉の前に村人が集まる絵 + 「おわり」。決定でタイトルへ（セーブは消さない） | — |

**先へ進む条件（門）**: 依頼を受ける前は村から出られない（村の出口で引き返す）。ミナが加わる前も出られない。
トトが加わる前は坑道の入口に入れない（「ほこらに だれか いたような…」）。門は「その仲間が加わっているか」の 1 種類で、
ミナは依頼の後にしか加わらないので、村の出口は gate = mina の 1 つで両方を止める（台詞は gateNode の中で `$quest` で分ける）。判定と台詞は 4.1・4.2。

**全滅**: 宿屋の前で目覚める（お金は半分・HP / MP 全快・旗と宝箱と手に入れた物はそのまま。ボスは生きたまま、挑み直せる）。
**フィールドで HP 0 の仲間**は隊列から抜ける（描かない・場所を詰める）。宿屋で治ると戻る。

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

```flix
pub type alias Rec = {
    scene    = Scene,                  // 今の場面と、その場面だけの値
    party    = Party.Party,            // 3 人の数値・装備・加わったか（1 case の enum で包む）
    bag      = Bag.Bag,                // 持ち物（ItemId → 個数）とお金
    progress = Progress.Progress,      // 依頼の段階・仲間の加入・開けた宝箱と扉・せいすいの残り歩数
    dice     = Int32,                  // 乱数を引いた回数（2.5）
    play     = Clock.Clock[Play],      // 遊びの時計（歩き・文字送り・暗転・戦いの演出）
    realNow  = Clock.Time[Clock.Real], // 止まらない物（水のゆれ・カーソルの点滅・その場足踏み）
    ask      = Option[Ask],            // 一番手前の確認（Esc の終了）
    events   = Emit.Events[Event],     // 規則が出した出来事（音を選ぶ元）
    save     = Option[Saves.SaveData], // 書く（読んだ）セーブの中身。タイトルの「つづきから」もここを読む
    saveRev  = Int32                   // セーブを書く合図（App.addOutput が変わった時だけ save を書く）
}
```

一番上の欄は 11 個。`bin/fge record-wrap` の world-fields・world-resource に掛からない形にする。

### 2.3 場面（Scene）

```flix
pub enum Scene {
    case Title(TitleMenu)                  // カーソルの項目
    case Field(FieldState)                 // マップを歩いている（上に開くウィンドウも payload に持つ）
    case Battle(BattleState)               // 戦い（戻り先の FieldState を中に持つ）
    case Ending(Clock.Time[Clock.Real])    // 入った時刻
}
```

- `FieldState` / `BattleState` は非 pub の 1 case の enum + `pub type alias`（外から作らせない）。読む関数 `fieldRecOf`・書く関数 `mapField` を 1 つずつ。
- 比べる・字にする用に名前だけの `SceneKind with Eq, ToString`（`World.sceneKindOf`）。
- 場面に入る関数は `World.enterField`・`WorldBattle.enter`・`World.enterEnding`（予定）・`World.toTitle`（予定） だけ。doc に `[遷移: X→Y]`。

`FieldRec` の中身:

| 欄 | 型 | 意味 |
|---|---|---|
| `map` | `MapId` | いるマップ |
| `hero` | `Grid.Cell` | 先頭のマス |
| `facing` | `Dir4.Dir4` | 先頭の向き |
| `stride` | `Stride` | `Still` / `Walking(from: Grid.Cell, startedAt: Clock.Time[Play])` |
| `trail` | `List[(Grid.Cell, Dir4.Dir4)]` | 先頭が前にいたマス（新しい順に 2 つ）。生きている 2 人目・3 人目がこの順に立つ |
| `stepsToFight` | `Int32` | 次の戦いまでの歩数 |
| `window` | `FieldWindow` | 上に開いているウィンドウ（2.4） |
| `transition` | `Option[Transition]` | 暗転・点滅の途中（4.1） |

### 2.4 重ねるウィンドウ（FieldWindow）

```flix
pub enum FieldWindow {
    case Closed
    case Talk(TalkState)
    case Menu(MenuPage)
    case Shop(ShopState, TalkState)          // 店を閉じたら、開いた会話の続きへ戻る
    case Notice(NoticeState)
}

TalkState   = { runner: YarnRunner.Runner[Play], line: Option[Yarn.Line], reveal: UiTypewriter.Reveal,
                choices: List[YarnRunner.DialogueOption], cursor: Int32 }
ShopState   = ShopPage の enum: Top(Int32)                    // かう / うる / やめる
                              | Goods(ShopMode, Int32)          // 品の一覧
                              | Count(ShopMode, ItemId, Int32)  // 個数 1〜9
                              | Confirm(ShopMode, ItemId, Int32, Int32)  // 「〜G です よろしいですか」はい / いいえ
NoticeState = { lines: List[String], reveal: UiTypewriter.Reveal, then: NoticeThen }
NoticeThen  = Close | BackTo(MenuPage) | ResumeTalk(TalkState)
```

フィールドのメニュー（4.6 の手順とそろえる。キャンセルは `WorldMenu.parentOf` の 1 か所で 1 つ前のページへ）:

```flix
pub enum MenuPage {
    case Root(Int32)                              // はなす / じゅもん / つよさ / どうぐ / そうび / しらべる
    case Items(Int32)                             // ふくろの一覧
    case ItemTarget(ItemId, Int32)                // 誰に使うか
    case SpellWho(Int32)                          // 誰が唱えるか
    case Spells(Member, Int32)                    // 呪文の一覧（フィールドで使えない物は灰色）
    case SpellTarget(Member, SpellId, Int32)      // 誰にかけるか
    case Status(Member)                           // つよさ（左右で仲間を替える）
    case EquipWho(Int32)                          // 誰の装備か
    case EquipSlot(Member, Int32)                 // ぶき / よろい
    case EquipPick(Member, Slot, Int32)           // ふくろの中の付けられる物（「はずす」を先頭に）
}
```

### 2.5 入力の層（InputLayer）

入力を受ける一番手前の層は `InputLayer.layerOf(w)` の 1 か所で決め、キーの振り分けはその値を match するだけにする。

```flix
pub enum Layer {
    case Asking(Ask)                 // Esc の終了の確認（どの場面より手前）
    case Busy                        // 暗転・点滅の途中、戦いの 1 手の演出（Timeline）が終わるまで（入力を捨てる）
    case Title(TitleMenu)
    case Window(FieldWindow)         // Closed 以外のウィンドウ
    case Walking                     // ウィンドウが閉じていて歩ける
    case BattleChoose(BattleRec)     // 戦いのコマンドを選んでいる（BattleChoose と BattleMessage は P5 で足す）
    case BattleMessage               // 演出が終わって伝言を出している間（決定で早送り・次へ）
    case Ending
}
```

境目: 戦いの 1 手は「演出（Timeline の進み具合が 1 未満）= Busy」→「伝言を出している = BattleMessage」の順で、演出が終わったフレームで切り替わる。

### 2.6 乱数

`Math.Random` は使わない。`World#dice`（引いた回数）と `Hash01.at(dice, 用途の番号)` で引き、引くたびに 1 足す
（`Dice.roll(w): (Float64, World)`・`Dice.weighted`・`Dice.range` の 1 ファイル）。同じ操作の列は同じ結果になり、テスト・e2e・描き出しが毎回同じになる。
はじめからは `dice = 0`。`Starts` は `seed=N` で始めの値を変えられる。セーブにも入れる。
テンプレの `bin/lint-rules/forbid.local.json` で `RandomUtil.` と `Math.Random` を止める。

### 2.7 パーティ・持ち物・進み具合

- **仲間は固定の 3 人**: `pub enum Member with Eq, Order, ToString { case Luka case Mina case Toto }`。物語に結び付くのでコードに置き、数値は Doc。
- `Party` は `Map[Member, Stats]` と加わった順 `List[Member]`。`Stats = { lv, exp, hp, mp, weapon: Option[ItemId], armor: Option[ItemId] }`。
  最大 HP・ちから等は **Lv と装備から導く**（`Party.maxHpOf(res, member, w)`）。World に導ける値を持たない。
  先頭は「加わった順で最初の生きている人」。
- 持ち物は `Map[ItemId, Int32]`（個数 0 は消す・12 種類まで）とお金 `gold`。装備している物はふくろに入れない。
- **依頼の段階は enum** `Quest { NotAsked | Accepted | BossDown | Reported }`（case は使うフェーズで足す。P2 は NotAsked・Accepted）。前の段階へは戻らない（`Progress.advanceQuest`）。
- 仲間の加入は `Party` の加わった順が正（Progress に別の旗を持たない）。宝箱と扉は `Set[(MapId, String)]`。

### 2.8 型で止める所

| 取り違え | 止め方 |
|---|---|
| Doc に無い道具・呪文・敵・マップの名前を World が持つ | `ItemId`・`SpellId`・`FoeId`・`MapId` は非 pub の enum + `pub type alias`。作れるのは各 Doc の `idOf(doc, name): Option[...]` だけ |
| 仲間を文字列で指す | `Member` の enum |
| マス（Grid.Cell）と画面の px | 規則は `Grid.Cell` だけ。px にするのは View の `FieldView.cellPx` だけ（forbid.local.json の rpg-no-px-in-rules が src/World* の Vec2 を止める） |
| 遊びの時刻と実時間 | 状態を進める時刻（歩き・暗転・点滅・宿・戦いの演出）は全部 `Clock.Time[Play]`。実時間は見た目だけ |
| 戦いの的 | `Target { Foe(Int32) | AllFoes | Ally(Member) | AllAllies }`。呪文と敵の技の Doc の `target` から作る |
| ウィンドウを開いたまま歩く | `InputLayer` が `Walking` の時しか歩く関数を呼ばない |

## 3. Doc（assets/*.json）の切り方

切る物差しは「いつ読み直したいか」。全部 `version`・`title`・スキーマ（sections 形式）を持ち、fail-open（既定値で続けたら 1 行言う）。
**入れ子は 2 階層まで**（record の欄 1 階層、または list / catalog の 1 行 1 階層。行の中に表を持たない）。
`project.json` の `editor.resources` に全部登録する。読み直しは `Controls.docTable` の `Resources.reloadRow`。

| ファイル | 中身（節 = sections の 1 つ） | 読み直しで収める（settle） |
|---|---|---|
| `assets/maps/<名前>.map.json` ×9（village・chief_house・inn・shop・smithy・world・mine_b1・mine_b2・mine_b3） | タブは 8 枚: 値の group「マップ」（`tileset`・`battleBack`・`bgm`）・`rows`（list of text。1 文字 = 1 マス）・list の節 6 つ（どれも 1 行は平らな欄だけ）: `exits {id, x, y, edge, to, spawnX, spawnY, facing, gate, gateNode}`・`npcs {id, sprite, x, y, facing, node}`・`objects {id, kind (chest / door), x, y, item, count, gold, key}`・`events {x, y, node}`・`props {sprite, frame, x, y}`・`encounter {foe1, foe2, foe3, weight}` | いるマップが消えたら宿の前へ。いるマスが壁になったら一番近い歩けるマスへ |
| `assets/rpg.party.json` | catalog `members`（鍵 = luka / mina / toto）: `name, sprite, joinLv, hp, mp, atk, def, agi, hpUp, mpUp, atkUp, defUp, agiUp, weapon, armor`。list `learns {member, spell, lv}`。list `exp {lv, total}` | HP / MP を新しい最大に収める（戦いの最中なら Battle.Rec の party も） |
| `assets/rpg.foes.json` | catalog（鍵 = 敵の名前の id）: `name, sprite, recolor, width, height, lift, lv, hp, atk, def, agi, exp, gold, noFlee, phase2At` | 戦いの最中なら敵の HP を新しい最大に収める |
| `assets/rpg.foe_moves.json` | list `moves {foe, phase, act, weight}`。act の語彙は `attack / sweep / fire / ice / sleep / guard`（4.4） | — |
| `assets/rpg.recolors.json` | catalog（鍵 = 色違いの名前）: `from1, to1, from2, to2, from3, to3, from4, to4`（色票の鍵どうし） | 色違いのアトラスを作り直す |
| `assets/rpg.spells.json` | catalog: `name, mp, power, target, field, fx` | — |
| `assets/rpg.items.json` | catalog: `name, kind (use / weapon / armor / key), price, heal, mpHeal, holySteps, burn, atk, def, luka, mina, toto`（最後の 3 つは装備できるか） | ふくろの中の消えた道具を捨てる |
| `assets/rpg.shops.json` | 値: `innPrice`。list `goods {item}` | — |
| `assets/rpg.rules.json` | 値 23 個を group 6 つ（タブ 6 枚）に束ねる: フィールド `secondsPerTile / cps`・戦い `messageWait / spread / critRate / fleeBase / fleeSlope / maxFoes`・出会い `minSteps / maxSteps / holyMargin`・始まりと宿の前 `startGold / startMap / startX / startY / startFacing / homeMap / homeX / homeY`・お金 `goldKeep / reward / advance`・暗転 `fadeSeconds / flashSeconds / innSeconds` | — |
| `assets/rpg.text.json` | catalog 4 つ: `speakers`（話し手の呼び名。鍵がそのまま会話の語彙の話し手になる）・`battle`（伝言の型 `{name}の こうげき！`）・`menu`（項目名）・`notice`（知らせ） | — |
| `assets/rpg.keys.json` | キー（決定 Z / Enter / Space・取消とメニュー X / Backspace・方向は矢印と WASD）。tidepool の `KeysDoc` を写す | — |
| `assets/rpg.mixer.json`（予定） | 曲 / 効果音 / UI のバス・効果音の間だけ曲を下げる・会話の snapshot | — |
| `assets/talk/rune.yarn` → `dialogue.json`・`vocab.json` | 会話（4.2） | 会話の最中なら閉じる |
| `assets/rpg.scenes.json`（予定） | 13 場面の題と一言（Studio のギャラリー） | — |
| 既存 `assets/rpg.*.sprite.json`・`rpg.palette.json` | 絵の部品と色票（変えない） | — |

決めた事:
- **依頼のお礼の正は `rules.reward` の 1 か所**。払うのは `<<quest report>>`、台詞は `{$reward}` を埋め込む。手付けの 50G も `rules.advance` を `<<quest accept>>` が払う。
- **逃げられない事の正は `foes.noFlee` の 1 か所**。戦いの組に noFlee の敵が 1 体でもいれば逃げられない。
- **敵の大きさと高さ**は `foes.width / height / lift`（`BattleScenes` の `size`・`lift` を移す）。横の置き場は数で決める（1 体 = 中央、2 体 = 1/3・2/3、3 体 = 1/4・1/2・3/4）。
- **色違い**は `foes.recolor`（空なら元の色）で `rpg.recolors.json` の 1 行を指す。Res が `rpg.monsters.sprite.json` を色票の鍵を差し替えて作り直し、色違いごとのアトラスを持つ（4.4）。

**外に出さない物**（コードのまま）: タイルの文字 → 絵（`Autotile.Cell`）と通れるか（`Passage`）の表（`Tileset.flix`）、
ダメージの式・行動順・出会いの決め方・レベルアップの決め方・門の判定・ウィンドウの大きさと置き場・演出のタイミングの並び・3 人がいる事。

マップの `rows` は今の `FieldScenes.villageRows` などを JSON に移すのが最初の中身（村・村長の家・ワールドマップ・B1・B3 は絵の段階の格子を写す。
ワールドマップは 32×24 へ広げる。B2・宿屋・道具屋・鍛冶屋の前は新しく打つ）。坑道は各 24×20 前後。

## 4. 仕組みごとの設計

### 4.1 マップの移動（`WorldField.flix`）

- **マス単位**。方向を押すと先頭が向きを変え、前のマスへ進めれば `stride = Walking(from, now)`。1 マスは `rules.secondsPerTile`（既定 0.22 秒）。
  押したままなら、着いたフレームで次の 1 マスへ続け、**次の startedAt は `Clock.after(secondsPerTile, 前の startedAt)`** にする（着いたフレームの now を使うと、1 フレームのはみ出しぶん 1 マス約 6% ずつ遅れ続ける）。1 フレームで 2 マスぶん進んだ時も同じ式で続けて数える。進めなければ向きだけ変える（ぶつかる音を 1 回）。
- 進めるか: `Tileset.passageOf(tileset, 文字)`（`Walk` / `Block` / `Counter`）・NPC のマス・閉じた扉・宝箱・**門**（下）。仲間は塞がない。
- **隊列**: 先頭が 1 マス進むたびに、先頭の前のマスを `trail` の頭に入れて 2 つに切る。生きている 2 人目・3 人目がその順に立つ（HP 0 の人は描かず、後ろが詰める）。描く時は全員が同じ stride の進み具合で前のマスから今のマスへ動く。
- **カメラ**: `App.withCamera`（先頭の px。stride の途中も含む）+ `App.withCameraBounds`（マップの矩形。狭い軸は真ん中に置かれる）+ `App.withPixelSnap(_ -> 1.0)`。戦い・タイトル・エンディングは画面の中央・矩形は画面。
- **出入口**: `exits` の `at`（x, y）に着いた、または `edge` の向きでマップの外へ出ようとした → `transition` を置く。階段も同じ。
- **門**: exits の `gate`（仲間の名前 `mina / toto`。空なら無し）の仲間が加わっていなければ、そのマスへは進めず、向きだけ変えて `gateNode` の会話を開く。判定は `WorldField.closedGateAt` の 1 か所（Party の加わった順を見る）。知らない名前の gate はその出口の行ごと読めない扱い（書き損じで出口が黙って開かない）。
- **暗転と点滅（Transition）**: 持ち方は 1 つ。`Transition = { kind: Fade | Flash, startedAt: Clock.Time[Play], then: TransitionThen }`、`TransitionThen = Warp(MapId, Grid.Cell, Dir4) | StartBattle(List[FoeId]) | InnRest(TalkState) | FadeIn`。
  覆う → `then` を行う → 晴らす（FadeIn）の 2 枚に分け、長さは `rules.fadeSeconds / flashSeconds / innSeconds`。絵は `Transition.itemsAt` に進み具合を渡すだけ。覆っている間は `InputLayer.Layer.Busy`。
- **遊びの時計の止まる理由**: `pub enum Halt { case Asking }`。`World.paceOf` は ask が開いている間だけ `Clock.Run.Paused(Halt.Asking)`。メニューや会話では止めない（止めて困る物が無く、止めない方が単純）。
- **しらべる・はなす**: 決定で前のマスを見る。NPC なら会話、宝箱なら開ける（`Notice`）、扉なら鍵を確かめる、`Counter` の 1 マス先の NPC とも話せる（店・宿）。メニューの「はなす」「しらべる」も同じ関数。
- **イベントのマス**（`events`）: 着いたら `node` の会話を開く。台詞が 1 行も出ずに終わるノードならウィンドウは開かない（何度踏んでもよい。once の旗は持たない）。
- NPC は歩き回らない（その場で足踏み。話しかけると主人公の方を向く）。
- 使う engine: `Grid`・`Dir4`・`InputMap`・`Transition`・`Clock`・`App.withCamera / withCameraBounds / withPixelSnap`。

### 4.2 会話（`Talk.flix`・`WorldTalk.flix`）

- **Yarn を使う**（`bin/fge yarn build assets/talk`）。分かれ道（`-> はい` / `-> いいえ`）と `<<if>>` で、依頼の段階ごとの台詞を Doc だけで書ける。
- **旗の正は World**。World → YarnStorage の一方向だけ写す。写す変数（`Talk.SyncedVar`。使うフェーズで足す）: `$quest`（"none" / "accepted" / "bossdown" / "reported"）・`$mina`・`$gold`（P2）・`$innPrice`（P3）・`$toto`（P4）・`$reward`（P7）。
  **会話を開く時・入力を 1 つ流す前・コマンドを 1 つ当てた後に写し直す**（`WorldTalk.syncVars`。`<<gold>>` の直後の `<<if $gold >= $innPrice>>` が新しい値を見る）。
  実行器（YarnRunner）はコマンドで止まらずに次の台詞まで流すので、`Talk.fromJson` が読む時にゲームのコマンドの直後へ `<<wait 0>>` を差し込み、
  `WorldTalk` はそこで止まった実行器へ写し直してから続きを流す（.yarn に `<<wait 0>>` は書かない。engine の実行器に「コマンドで止まる」口が入れば差し込みは要らなくなる）。
- **Yarn の `<<set>>` でこの 6 つを書かない**（書いても次の写しで消える）。TestDocs が dialogue.json を見て止める。会話の中だけの数える変数は `<<set>>` してよい。
- World を変えるのはコマンドだけ。`Talk.Command` の enum と `Talk.vocabOf` が語彙の正（`make talk-vocab`）:

| コマンド | 意味 |
|---|---|
| `<<quest accept>>` / `<<quest report>>` | 段階を進め、`rules.advance` / `rules.reward` を払う（前の段階が合わなければ何もしない） |
| `<<join mina>>` / `<<join toto>>` | 加える（加わっていれば何もしない）。トトは `joinLv` の経験値で加わる |
| `<<give 道具 個数>>` / `<<gold 数>>` | ふくろとお金 |
| `<<shop>>` / `<<inn>>` | 店を開く（閉じたら続きへ）/ 宿代を払って泊まる → 暗転 → 全快 → セーブ → 続きへ |
| `<<open 扉>>` | 今のマップの扉を開く |
| `<<fight 敵 勝った後のノード>>` | 戦う。勝ったら Field へ戻って指したノードを開く（ボスは `<<fight gemeater BossWon>>`。BossWon のノードが水脈の台詞のあとに `<<warp to_world>>` を流す） |
| `<<warp 出口の id>>` | 今のマップの exits の 1 行（`id` で引く）を通って暗転で移る。門は見ない |
| `<<ending>>` | エンディングへ |
| `<<se 名前>>` | 効果音 |

  ボスを倒した段階の更新は `<<fight>>` の勝ちが行う（`foes.noFlee` のボス戦に勝つと `Quest.BossDown`（予定）。台詞側に段階を書かせない）。
  ボスの前の会話（扉の奥のイベントのマス）は `$quest == "accepted"` の間だけ戦いを起こすので、全滅しても挑み直せる。
- TestDocs が dialogue.json の全コマンドの引数を Doc で引けるか見る（give の道具は items、open の扉はそのノードを開くマップの objects（kind = door）、fight の敵は foes・ノードは Yarn、warp はマップの exits）。
- 1 行の台詞 = 1 枚のウィンドウ（4 行まで。幅 224px に折る。全角で 1 行 22 字）。収まらない台詞は TestDocs.testEveryLineFitsTheTalkWindow が止め、画面では後ろの 4 行を出す（先頭で切らない）。話し手があれば `むらおさ「…」` の形（呼び名は `rpg.text.json`）。
- 文字送りは `UiTypewriter`（`rules.cps`・Play の時計の dt）。決定で「出し切る」→ もう 1 回で次の行。1 フレームに決定は 1 回だけ使う。続きがあれば ▼。
- 選択肢は会話のウィンドウの右上に小さいウィンドウ（`gallery/quest.png` の形）。カーソルは `UiMenu.moveCursor`。

### 4.3 出会い（`WorldField.countStep`）

- 1 マス歩き終えるたびに `stepsToFight` を 1 減らす。マップに `encounter` の行が無ければ減らさない（村・家・ボスの間）。
- 0 になったら組を `Dice.weighted` で 1 つ選び、`Flash` の Transition → `StartBattle`。次の歩数は `rules.minSteps..maxSteps`（既定 12..20）から引き直す。
- 1 戦の敵は 3 体まで（`foe1..foe3`。`rules.maxFoes` は描き場所の数で 3 固定、Doc はそれ以下にしか下げられない）。
- せいすいの残り歩数がある間は、組の敵の Lv が全員「パーティの一番高い Lv − `holyMargin`」以下なら飛ばす。飛ばした時は戦わずに、次の歩数を出会った時と同じく `minSteps..maxSteps` から引き直す（その組を選び直さない）。

### 4.4 コマンドバトル（`Battle.flix` = 式・`WorldBattle.flix` = 進め方・`BattleView.flix` = 絵）

進み方（DQ の型）: 生きていて眠っていない仲間全員の行動を先に選び、そのあと敵味方をすばやさ順に 1 つずつ実行する。

```
Opening（「〜が あらわれた！」）→ Choose(member, CommandPage) → … → Run(resolveRound が返した Beat の列, startedAt: Time[Play])
   → 勝ち → Victory（経験値・お金・レベルアップの伝言を 1 枚ずつ）→ Field（afterWin のノードがあれば開く）
   → 全滅 → Defeat（「ぜんめつした…」）→ 宿の前（Transition の Warp）
   → どちらでもない → Choose へ
にげる成功 → Fled（「うまく にげきれた！」）→ Field（歩数は引き直す）
```

- **式と見せ方の境目**: 1 ターン（全員の行動を順に実行するまで）は純関数 `BattleActs.resolveRound(res, rec, plans, dice): (rec, List[Beat], dice)` が決める。
  敵の行動の選び・行動順・眠り・guard・振り替え・ダメージ・倒れた事は全部この中。`Beat = { message: BattleMsg, fx: Option[Fx], after: Battle.Rec }`（1 手ぶんの伝言と、その手の後の戦いの値）。
  勝ち負けは `Battle.outcomeOf(rec)`、経験値とレベルアップは `Party.gainExp`、にげるは `BattleActs.tryFlee`。どれも時計とフレームを見ない。
  `WorldBattle` は見せる側: Choose で集めた plans を resolveRound に渡し、返った Beat を Play の時計で 1 つずつ演出 → 伝言にする。HP の表示は今見せている Beat の `after` を読む（先に結果が出ない）。
  `BalanceSim`（5.5）も同じ resolveRound を呼び、フレームも時計も通さない。
- `Battle.Rec = { party: Party.Party, bag: Bag.Bag, foes: Vector[FoeState], asleep: Set[Member], guarding: Set[Int32] }`（戦いの値）。**戦いの間の正は Battle.Rec の party と bag**（World の party と bag は触らない）。勝った時・逃げた時に party と bag を一緒に World へ書き戻す（全滅の時は書き戻した後に 4.4 の全滅の決まりを当てる）。Doc を読み直した時は Battle.Rec の party と foes の両方を新しい最大に収める。
- resolveRound は敵が途中で全滅したら、そこで Beat を止める（残りの行動は流さない）。仲間が全滅した時も同じ。
  `BattleRec = { battle: Battle.Rec, phase: Phase, back: FieldState, plans: Map[Member, Plan], afterWin: Option[String] }`（見せる側の値）。`Phase = Opening | Choose(Member, CommandPage) | Run(List[Beat], Clock.Time[Play]) | Victory(List[String]) | Defeat | Fled`。
  `FoeState = { id: FoeId, label: String, hp: Int32, phase2: Bool }`。
  `CommandPage = Commands(Int32) | FoeTarget(Plan の種類, Int32) | SpellList(Int32) | AllyTarget(SpellId, Int32) | ItemList(Int32) | ItemTarget(ItemId, Int32)`。取消は 1 つ前のページ（最初のページなら前の仲間の選び直し）。
- **呼び分け**: 同じ名前が 2 体以上なら `コケだまA` `コケだまB`（出た順）。敵の一覧のウィンドウは名前ごとに数を出す（`gallery/battle.png` の形）。
- **行動順**: `すばやさ × (1 + 0.25 × r)` の大きい順（r は Dice）。同じ値は仲間が先。
- **ダメージ**（数は rules）: `max(1, round((ちから − まもり ÷ 2) × (1 − spread + 2 × spread × r)))`、spread 既定 0.125。
  会心（`critRate` 既定 1/32。仲間の通常攻撃だけ）はまもりを 0 として 1.5 倍。呪文は `power × (0.9 + 0.2 × r)` でまもりを見ない。ヒールは最大 HP で止める。
- **guard**（敵の技）: その手番のうちに受けるダメージを半分（切り上げ）。手番の終わりに外す。
- **sleep**（ねぼけダケ・ふかねダケ）: 仲間 1 人を眠らせる（成功率 0.6。眠っている人には効かない）。眠っている人は選ぶページを飛ばし、その人の手番の頭に Dice で 0.5 未満なら起きて動く（眠った次の手番は必ず眠る）。叩かれても起きない。戦いが終われば起きる。仲間が全員眠ったら敵だけが動く。
- **sweep**: 生きている仲間全員に `ちから × 0.6` の通常の式。
- 倒れた的への行動は、生きている別の的へ振り替える（いなければ飛ばす）。
- **にげる**: Choose で誰かが にげる を選んだら、その後の仲間は選ぶページを飛ばす（にげる はその人の手番で試し、失敗したら飛ばした仲間は何もしない）。率 = `fleeBase + (仲間の一番速い − 敵の一番速い) × fleeSlope` を 0.1..0.95 に収める。noFlee の組では「にげられない！」で手番を使う。
- **どうぐ**: やくそう・まりょくのみ・たいまつ（敵 1 体に `burn` のダメージ）。せいすいは戦いでは灰色。
- **敵の行動**: `rpg.foe_moves.json` の その敵の行（phase 1）から Dice で重み付きに選ぶ。HP が `phase2At`（割合。0 なら替えない）を切ると phase 2 の行に替える（ジェムイーター）。的は生きている仲間から Dice。
- **勝ち**: 経験値は敵の合計を、生きている仲間がそれぞれ全部受け取る。お金はふくろへ。`Party.gainExp` が表をまたいだ分だけ何レベルでも上げ、伸びと覚えた呪文を伝言にする。
- **全滅**: お金に `goldKeep`（0.5）を掛けて切り捨て、HP / MP 全快で宿の前へ。
- 伝言は 1 枚ずつ文字送りで出し、`messageWait` 秒で自動で次へ（決定で早送り）。
- 演出: 攻撃 `slash`・呪文 `fire` / `ice` / `heal`・当たり `hit`（battlefx のコマ）+ 敵の点滅。仲間が当たったら戦いの背景を 2px ずらす。タイミングは `Timeline` に書き、音も同じ表に付ける（時計は Play）。
- 戦いの背景はマップの `battleBack`（`bg_plains` / `bg_cave` / `bg_lake`）。
- **色違いの絵**: Res が `foes.recolor` のある行ごとに `rpg.monsters.sprite.json` を「色票の鍵を差し替える resolver」で `PxSpriteAtlas.bake` し直し、テクスチャ `px_foe_<id>` として持つ（色違いは 5 体 = テクスチャ 5 枚）。

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

- 店は `<<shop>>`。かう / うる → 品 → 個数（1〜9）→ はい / いいえ。お金が足りない・ふくろが 12 種類で一杯なら灰色。売値は値段の半分（切り捨て）。だいじなものは売れない。
- 宿は `<<inn>>`。払えない時は Yarn の `<<if $gold >= $innPrice>>` で断る台詞へ分ける（コマンドは払える前提でだけ流す。払えないのに流れたら何もせず 1 行言う）。

### 4.8 セーブ（`Saves.flix`）

- **1 枠**・`saves/rune.json`（`version` 付き）。**再開する所は宿の前**（`rules.homeMap / homeX / homeY`。全滅の戻り先と同じ）。位置は書かない。
- 中身 `SaveData = { party, bag, progress, dice }`。宿に泊まった時に World の `save = Some(今の中身)` にして `saveRev` を 1 足す。
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
**雑魚はその区間の Lv のルカが 2〜3 発で倒す / ボスは 6〜8 ターン / ボスの前で Lv 6 前後**。

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
| やくそう | use | 8 | HP 30 | — | 店・宝箱 |
| せいすい | use | 20 | 64 歩 | — | 店 |
| まりょくのみ | use | 30 | MP 10 | — | 宝箱（B2） |
| たいまつ | use | 10 | 敵 1 体に 12 | — | 宝箱（B1） |
| ふるびたかぎ | key | — | B3 の扉 | — | 宝箱（B2） |
| ひのきのぼう / かしのつえ / つるはし | weapon | 10 / 10 / 20 | ちから +2 / +1 / +4 | ルカ / トト / ミナ | 初め |
| どうのつるぎ | weapon | 60 | ちから +6 | ルカ | 店 |
| たびびとのふく / ローブ | armor | 10 / 10 | まもり +2 | 3 人 / トト | 初め |
| かわのよろい | armor | 70 | まもり +5 | ルカ・ミナ | 宝箱（B1）・店 |
| まほうのローブ | armor | 80 | まもり +5 | トト | 宝箱（B2） |

宿代 6G。**店の装備はどうのつるぎ（60G）と かわのよろい（70G）**。初めのお金 50G + 手付け 50G = 100G で買えるのは、どうのつるぎとやくそう 4 つ（92G）まで。かわのよろいは B1 の宝箱で 1 つ手に入り、2 つ目（ミナの分）は坑道で稼いでから村へ戻って買う（お金の使い道）。まほうのローブは宝箱だけ。

### 5.3 敵（雑魚 12 体 + ボス）

色違いは FC の定番の作り（同じ絵の色票を差し替え、強い方を奥へ）。名前は絵の側（ART_BRIEF・sprite の note）にそろえ、色違いには新しく付けた。

| id | 名前 | 絵（色違い） | Lv | HP | ちから | まもり | すばやさ | 経験値 | お金 | 技 | 出る所 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| kusausa | くさウサ | bunny | 1 | 16 | 9 | 4 | 7 | 3 | 3 | attack | ワールド |
| neboke | ねぼけダケ | shroom | 2 | 16 | 10 | 6 | 3 | 4 | 4 | attack 3・sleep 1 | ワールド |
| koke | コケだま | koke | 2 | 20 | 11 | 10 | 4 | 5 | 5 | attack | ワールド・B1 |
| hanausa | はなウサ | bunny（桃） | 3 | 20 | 11 | 6 | 10 | 6 | 6 | attack | ワールド（北） |
| koumori | 坑道コウモリ | bat | 3 | 22 | 12 | 8 | 12 | 8 | 6 | attack | B1・B2 |
| horimogu | ほりモグ | mole | 4 | 30 | 16 | 12 | 6 | 10 | 8 | attack 3・guard 1 | B1・B2 |
| fukane | ふかねダケ | shroom（紫） | 5 | 32 | 17 | 12 | 4 | 12 | 10 | attack 2・sleep 1 | B2 |
| goblin | つるはしゴブリン | goblin | 5 | 40 | 20 | 14 | 9 | 15 | 12 | attack | B2・B3 |
| hinoko | ひのこコウモリ | bat（赤） | 5 | 34 | 17 | 12 | 14 | 14 | 10 | attack 2・fire 1 | B2 |
| shouyado | ショウヤドカリ | hermit | 6 | 50 | 22 | 24 | 5 | 20 | 15 | attack 2・guard 1 | B3 |
| akabou | あかぼうしゴブリン | goblin（赤） | 7 | 50 | 20 | 18 | 10 | 24 | 18 | attack 3・sweep 1 | B3 |
| koriyado | こおりヤドカリ | hermit（青） | 7 | 54 | 23 | 22 | 6 | 24 | 16 | attack 1・ice 1・guard 1 | B3 |
| gemeater | ジェムイーター | boss | 10 | 360（P5.5 で 460・P7 で 360）| 41（P7 で 34 → 41） | 22 | 9 | 200 | 0 | 1: attack 3・sweep 1 / 2（HP 50% 未満）: attack 2・sweep 2 | B3 の奥・noFlee |

P5 の `make balance` で直した数（上の表は直した後の値）: くさウサ HP 12→16（ルカ Lv1 の 1 発で倒れた）・はなウサ ちから 13→11・
坑道コウモリ ちから 14→12・ひのこコウモリ ちから 18→17・こおりヤドカリ まもり 26→22（4 発かかった）・あかぼうしゴブリン HP 56→50・ちから 25→20。
出会いの組も 3 つ軽くした（3 体の組の受けるダメージが 40〜50%）: ワールドの はなウサ・くさウサ・くさウサ → はなウサ・くさウサ、
B1 の 坑道コウモリ×2・コケだま → 坑道コウモリ・コケだま×2、B3 の あかぼうし・つるはし×2 → あかぼうし・つるはし。

呪文（rules ではなく spells）: ファイア MP3 力 14（敵 1）/ ヒール MP3 回復 30（味方 1）/ アイス MP5 力 10（敵全部）。敵が使う fire / ice も同じ値。

### 5.4 戦う回数の見積もり（逆算）

出会いの間隔 12..20 歩（平均 16 歩）。1 戦の敵は平均 2.2 体。

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

- 置き場: `src/sim/Bot.flix`（方針）と `src/sim/BotRun.flix`（入口・レポート）。入口は `App.Headless.job("BotRun", "run", …)`。
- **手は実機と同じ経路で流す**: bot は毎フレーム World を見てキー（方向・決定・取消・メニュー）を 1 つ決め、`App.traceFrame` で `Game.app` に 1 フレームずつ流す（Flow と同じ経路）。規則の関数を直に呼ばないので、入力の層・門・ウィンドウの詰まりもそのまま見つかる。dt は 1/60 秒で固定。
- **方針（決め打ち）**:
  - 何をするかは `Bot.goalOf(w)` の 1 か所の表で決める（依頼の段階と仲間とふくろから「次の目的地と、着いたらする事」）。例: NotAsked → 村長に話す / Accepted でミナがいない → 鍛冶屋 / 装備を買っていない → 道具屋で `rules` の順に買える物を買う / トトがいない → ほこら / かぎが無い → B2 の宝箱 / BossDown → 村長。
  - 歩き: マップの間は exits をつないだ図の最短、マップの中は `GridSearch.distances`（通れるかは規則と同じ `WorldField.canEnter`）の最短。宝箱は道の途中にある物だけ開ける。
  - 戦い: 基本は たたかう（的は HP の一番少ない敵）。仲間の HP が最大の 35% 未満ならトト / ルカのヒール、MP が無ければやくそう、どちらも無ければ たたかう。MP が尽きたトトも たたかう。にげない。
  - 店（任意の goal）: B1 を出た後に手持ちが 70G を超えていれば、村へ戻ってミナの かわのよろい を買う（`BOT_SHOP=1` の時だけ。既定は 0 で、5.4 のつり合いはこれをしない前提）。
  - 宿: 区間の頭（村を出る前・坑道へ入る前に村へ戻れる時）に、誰かの HP が 60% 未満なら泊まる。全滅したら宿の前から goalOf をやり直す。
  - 会話: 文字送りは決定で進め、はい / いいえは「はい」。
- **詰みの判定**: 戦いの中の時間は数えない。フィールドにいる間の Play の時計で 60 秒、「目的地までの残りのマス数（マップの間はつないだ図の残りの出入口の数 × 100 + マップの中のマス数）」が一番小さかった値より縮まなければ「詰んだ」として、その時の World の指紋と goal を書いて終わる。
  `GridSearch.distances` はマップか goal が変わった時だけ引き直し、bot の値に持つ（毎フレーム引かない）。
- **確かめる事**（レポートに出す）: 詰まない・タイトルからエンディングまでのゲーム内時間（Play の時計）・区間（ワールド行き / B1 / B2 / B3 / ボス / 帰り）ごとの戦った回数と区間の終わりの Lv・全滅の回数と場所・使ったやくそうと MP・お金の出入り。
- **終了コード**: エンディングに着けば 0、詰めば 1。`BOT_SEED=n`（dice の始めの値。既定 0）・`BOT_RUNS=n`（種を変えて n 本流し、表を並べる。既定 1）。
- **流した手は `debug/bot/playthrough.flow` に書く**（3. の動画がそのまま使う）。区間の頭ごとに `mark <区間>` と、その時に立っているはずの値の `expect quest=…` と `expect map=…` を書く（問いの名前は E2e の probes。動画で流し直した時に区間がずれたらそこで止まる）。
  Flow の `drive` を使わないのは、drive が「詰んだ理由」を返せないため。
- 1 本の重さの目安: 15 分 = 54000 フレーム。画面なしで 1 分以内を目標にする。超えたら BOT_RUNS の本数を並列に流す（1 本ずつ別のスレッド。World は純粋なので本どうしは混ざらない）。1 本の中のフレームはまとめない。

**2. つり合いのシミュレーション — `make balance` → `debug/balance.md`**

- 置き場: `src/sim/BalanceSim.flix`。戦いだけを流す。**`BattleActs.resolveRound`（4.4）を直に回し、フレームも時計も `WorldBattle` も通さない**。plans は bot と同じ戦いの方針（`Bot.battlePlans(res, rec)` を Field の bot と分けて pub にする）。
- 区間ごとのパーティは `src/sim/BalanceSim.flix` の表で決める（5.4 の各区間の Lv と、その時に持っているはずの装備・やくそうの数。bot のレポートの値で書き直してよい）。
- 流す物: 各マップの encounter の組ぜんぶ × 500 種（`dice` の始めの値を変える）、ボス戦 × 500 種を Lv 5 / 6 / 7 で。合わせて約 14000 戦・7 万ターン。**全部の表で 1 分以内**を目標にする（超えたら種の数を `BALANCE_SEEDS` で下げられるようにする。既定 500）。
- レポートの中身（区間ごと・組ごとの表）: 勝率・ターン数（中央値と 9 割の値）・受けたダメージ（最大 HP に対する割合の中央値と 9 割の値）・全滅の率・使った MP とやくそう。
  敵ごとに「その区間の Lv のルカの たたかう で倒れるまでの回数」（中央値）。
- **5 節の目安と照らす**: 雑魚はルカの 2〜3 発 / ボスは 6〜8 ターン / ボスの勝率は Lv 6 で 70〜95% / 雑魚 1 戦の受けるダメージは中央値で最大 HP の 30% 以下。外れた行に `⚠` を付けて並べる。
- **テストではなく知らせる口**（重いので `make test` に入れない。終了コードはいつも 0）。外れたら Doc の数だけで直して流し直す。コードの式は直さない（直す時は計画を先に直す）。

**3. 通しの動画 — `make video` → `debug/video/rune.mp4`**

- 置き場: `src/render/VideoRender.flix`（予定）（`templates/tidepool-starter` の `VideoRender` と Makefile の `video` を写す）。手は bot が書いた `debug/bot/playthrough.flow` を `Flow.play`（予定） で流し、音は同じコマの出来事とミキサーから混ぜる。
- 15 分を全部は撮らない。**区間は flow の `mark` で切る**（撮る区間の名前の表を VideoRender に持つ: title・quest・join・world_first_fight・toto・b1_fight・magic・boss・return・ending）。手は全部流し、撮る区間だけ塗る。つなぐと 3 分前後。
- 重さの見積もり: 30fps × 3 分 = 5400 コマ。SoftRaster で 1 コマ 0.2〜0.5 秒（シェーダーの面が無いので tidepool より軽い）として 20〜45 分。GPU のある所（`FGE_GPU`）なら数分。途中で止まったら `FGE_VIDEO_PAINT=frames:A-B` で残りだけ塗る。
- 依頼主が見る物なので、撮ったら `/critique-render` で何コマか見てから渡す。

## 6. 今の描き出しコードの育て方

| 今のファイル | どうするか |
|---|---|
| `src/Sheet.flix` | **そのまま生かす**（部品を置く関数・仮の四角・コマの選び方） |
| `src/Palette.flix`・`src/Res.flix` | 生かす。Res に Doc の束（`Res.Docs` と `Res.build`。tidepool の形）と色違いのアトラスを足す |
| `src/WindowView.flix` | **生かす**。足すのは「灰色の項目」「途中まで出した文」「数字の右寄せ」「名前ごとの数（コケだま 2）」 |
| `src/FieldView.flix` | 生かす。地面をタイル層の宣言（下）へ写す関数と、水と岸だけを動く側で描く関数に分ける。人に「歩きの途中の px のずれ」と歩いている間だけ回すコマを足す |
| ~~`src/render/FieldScenes.flix`~~（P7 で消した） | **ばらす**。凡例は `src/Tileset.flix` へ（`Passage` を足す）。格子はマップ Doc へ。小物と人の置き場はマップ Doc の `props`・`npcs` へ。場面を組む関数は捨てる |
| ~~`src/render/BattleScenes.flix`~~（P7 で消した） | 背景・敵の置き方・3 人のウィンドウ・コマンドのウィンドウの矩形は `BattleView.flix` へ。敵の大きさと高さは `foes.json` へ |
| `src/render/SceneRender.flix` | 残す。`sceneOf` を「名前 → `Starts` で World を作り、決まった手を進めた World」に替え、描くのは実機と同じ `View.frame` / `View.hud` |
| `src/Main.flix` | `Game.app` を呼ぶだけに替える |

**地面はタイル層**: `App.withTileLayers` に、マップごとに 1 つの `TileLayerSpec`（`key` = MapId の名前・tiles は鍵が変わった時だけ組むサンク）を渡す。
描き出しとテストは `TileScene.toItems` で同じ絵を出す。**水と岸（コマ送りのある `Edged`）と泉・たいまつ・人・小物は動く側**で、見えているマス（`Grid.cellsIn`）だけ描く。
タイル層の `Tileset` を Sheet のアトラスから作る方法は P1 の最初に確かめる（作れなければ相談事項 4）。

**13 場面は Starts から作る**（スナップショット）:

| 場面 | Starts と、その後の決まった手 |
|---|---|
| `title` | `title` |
| `village` | `field map=village x=7 y=10`（依頼の前） |
| `quest` | `talk node=ChiefQuest` を、はい / いいえの所まで送る |
| `join` | `talk node=SmithJoin` を「ミナが なかまに くわわった！」まで送る |
| `world` | `field map=world …` に 3 人（`party=luka,mina,toto`） |
| `dungeon1` | `field map=mine_b1 …` |
| `dungeon3` | `field map=mine_b3 …`（ボスの扉の手前） |
| `battle` | `battle foes=koke,koumori,goblin` |
| `magic` | 同じ組 → トトの番で じゅもん → ファイアを選んで炎の演出の途中 |
| `item` | `field map=village …` でメニュー → どうぐ |
| `boss` | `battle foes=gemeater` の Opening |
| `clear` | `field map=village quest=bossdown` で報告の会話の途中 |
| `ending` | `ending`（新しく足す。Makefile の `SHOTS`・`shotNames`・`rpg.scenes.json` を一緒に） |

場面の絵は時刻を決めて撮る。今の gallery の絵と見比べ、差が出たら `/critique-render` で直す。

View のファイル: `View.flix`（場面で振り分ける入口・画風の層の並びを頭に書く）・`TitleView`・`FieldScreen`・`BattleView`・`MenuView`・`ShopView`・`EndingView`。

**重なり順（`ZOrder.flix`・docs/z-bands.md）**:
- world の `Layer { Map, Battle }`: Map の中は奥から「地面（タイル層）→ 水と岸 → 足元の順の木」。足元の順の木は人・小物・屋根を `ZStack.zIndex(Depth.orderAt(足元の y), ZStack.leaf(部品))` で並べる（屋根は家の足元の y を持つので人より手前に出る）。Battle は背景 → 敵 → 演出を積んだ順。
- HUD の `HudLayer { Window, Transition, Prompt }`: 会話・メニュー・店・戦いのコマンドは Window、暗転と点滅は Transition、Esc の確認は Prompt。`App.withHudView` に繋ぐ（カメラで動かない）。
- z の数は `ZOrder` の `zRange` だけに書き、ほかは積んだ順で決める。

## 7. フェーズ

**いま遊べる物（P7 まで）**: タイトル → 村を歩く・家に出入りする・村人と話す・依頼を受ける・ミナが仲間に加わる・村の外周の端の出口と gate・
メニュー（どうぐ・つよさ・そうび・じゅもん）・道具屋・宿とセーブ・「つづきから」・ワールドマップ・ほこらのトトの杖の話 → 森の岩穴のレバーと鉄格子とほりモグ →
杖を返すとトトが加わる・坑道 B1（トロッコと分かれ目のレバー・岩の部屋 1・ボルじい）・B2（暗い迷路とたいまつ・落とし穴・行商人コロンの店・
中ボスくろがねゴブリン）・B3（水晶の順番と飛び石・岩の部屋 2 とひとくいばこ・ミナの父）・ふるびたかぎの扉・出会いとコマンドバトル
（たたかう / ぼうぎょ / にげる / じゅもん / どうぐ）・経験値とレベルアップ・全滅・会話の音・眠り・敵の呪文・フィールドの じゅもん（ヒール）・
B3 の扉の奥のジェムイーター（逃げられない・HP 半分で phase 2）・勝つと坑道の入口へ戻されワールドマップを歩いて帰る・
泉に水が戻った村（村人が泉に集まる）・村長への報告とお礼・エンディング（スタッフの字。決定で早送り → もう一度でタイトル）。

どのフェーズも終わりに: `make check`・`make test`・`make render-all`（Starts から描ける場面）が緑、`/critique-code` と `/critique-render`、レビュー役 90 点。
テストは `/quality-assurance` の形（期待値は Doc から導く・1 テスト 1 アサート・Starts から作る）。

5.5 の 3 つの道具を流す時期（完了の条件に入る）:

| フェーズ | bot（`make bot`） | つり合い（`make balance`） | 動画（`make video`） |
|---|---|---|---|
| P1〜P4 | — | — | — |
| P5 | 作る。タイトルから B3 の扉の前まで詰まずに着く（ボスと帰りは P7）。BOT_RUNS=5 | 作る。たたかう だけの方針で雑魚の表を出す | — |
| P6 | 同じ範囲を、ヒール・やくそうの方針で BOT_RUNS=5 | 呪文と道具を入れて全区間の雑魚の表。⚠ を Doc で直す | — |
| P7 | タイトルからエンディングまで 1 本で通る。BOT_RUNS=10 で全部通る | ボス戦を入れた全部の表。ボスの ⚠ を Doc で直す | `playthrough.flow` を書き出す所まで |
| P8 | 最終の数（区間ごとの戦う数・Lv・時間）を 5.4 の表と並べて README へ | 最終の表を `docs/balance.md`（予定） に写す（debug/ は git 管理外） | 作って撮る。依頼主へ渡す |

### P1 — 村を歩いて話せる（+ engine 側の古い参照の片付け）

- **始める前に依頼主の承認を取り、engine の設定と文書の古い参照を片付ける**（11 節 3。`bin/lint-rules/record-wrap.json` の旧 rpg-starter の除外 2 行・`docs/modules/*.md`・`docs/shader-doc.md`・`docs/backlog.md`）。新しい World を書く前に除外を外しておかないと、検査が新しい World を見逃す。
- P1 の World は scene・dice・play・realNow・ask・events の 6 欄。残りの欄（party・bag・progress・save・saveRev）は使うフェーズで足す。
- 作る: `World`・`Res`（Docs）・`Game`・`Main`・`Starts`（title / field / talk）・`Controls`・`InputLayer`・`ZOrder`・`E2e`・`Dice`、
  `MapDoc`（村と村長の家）・`Tileset`・タイル層・`WorldField`（歩く・当たり・出入口・Transition）・`Talk` / `WorldTalk`（台詞だけ）・`TitleView`・`FieldScreen`・`View`、
  `rpg.rules.json`・`rpg.text.json`・`rpg.keys.json`・`rune.yarn`（村人と村長のあいさつ）・`forbid.local.json`。効果音は決定・取消・ぶつかる・扉。
- 完了の条件: タイトル →「はじめから」→ 村を歩き、家に出入りし、村人と話せる。`title`・`village` を Starts から描く（残りは P7 まで旧 `FieldScenes` で描く）。
- テスト: 壁へは進めず向きだけ変わる / 押したままで 10 マス歩いた時刻が secondsPerTile × 10 に一致する（遅れが積もらない）/ 扉のマスに着き暗転が終わると行き先の spawn にいる / 暗転の間は方向キーで動かない / 決定で前の NPC の会話が開き、閉じると歩ける / マップ Doc の 3 本（壊れた JSON・1 欄の上書き・rows の長さに追随）/ 読み直しでいるマスが壁になったら近くの歩けるマスへ。
  e2e: `e2e/village_walk.flow`（はじめから → 村長の家に入って出る）。

### P2 — 依頼と仲間・門

- 作る: コマンド（quest / join / give / gold / se）と `syncVars`・はい / いいえ・`Progress`・`Party`（加わる・trail）・`Bag`・門・`rpg.party.json`・`rpg.items.json`（道具の分）・鍛冶屋の前のマップ。
- 完了の条件: 依頼を受け、鍛冶屋でミナが加わり、2 人で歩ける。依頼の前は村を出られない。`quest`・`join` を Starts から描く。
- テスト: いいえでは段階が変わらない / 依頼の前に鍛冶屋と話してもミナは加わらない / 同じ `<<join>>` を 2 回流しても 1 人 / `<<gold>>` の直後の `<<if $gold …>>` が新しい値で分かれる / 依頼の前は村の出口のマスへ進めず gateNode が開く / 隊列は先頭の前のマスを順に詰める（曲がり角 2 回）/ 語彙と vocab.json の一致 / dialogue.json に 6 つの変数への `<<set>>` が無い / 全コマンドの引数が Doc で引ける / party Doc の 3 本。
- P2 で決めた事（実装して決めた。上の節より新しい）:
  - World に足したのは party・bag・progress の 3 欄（bag は `<<quest accept>>` の手付けと `<<give>>`・`<<gold>>` の置き場）。`Party` はまだ加わった順だけで、`Stats`（Lv・HP…）は P3 で足す。`rpg.party.json` の行も `sprite` だけ（使うフェーズで欄を足す）。`rpg.items.json` は `name` だけ。
  - `rules` に `startGold`（50）と `advance`（50）を足した。「はじめから」でふくろに startGold が入る。
  - 鍛冶屋の前（`smithy`）は村の西の道の端（0, 9）から入る。ミナはそこに立つマップの人（id = `mina`）で、依頼の後に話すと `<<join mina>>` で加わり、マップから消えて立っていたマスから隊列に入る（id が仲間の名前の人は、加わるとマップから消える決まり）。
  - 村の出口は南の道の端（20, 14）。行き先の `world` は P4 までの仮のマップ（村の組の 16×15）で、P4 でワールドマップに書き直す。
  - `<<se>>` は P8（音を作るフェーズ）へ送った。
  - 出入口を通った直後は trail が空で、後ろの人は先頭と同じマスに重なる（先頭が手前に描かれる）。歩き出すと順に出てくる。
  - e2e は `e2e/quest_join.flow`（村長の家で依頼を受ける → 村の出口で引き返す → 鍛冶屋の前でミナが加わる → 村の出口から外へ）。

### P3 — メニュー・店・宿・セーブ

- 作る: `WorldMenu`（どうぐ・つよさ・そうび・はなす・しらべる。じゅもんは項目だけで P6 まで灰色）・`MenuView`・`WorldShop`・`ShopView`・宿・`Saves`・「つづきから」・道具屋と宿屋のマップ・`rpg.shops.json`・装備。
- 完了の条件: 村で買い物・装備・宿で泊まる・終了して「つづきから」で宿の前から。`item` を Starts から描く。
- テスト: お金が足りないと買えずお金もふくろも変わらない / 売ると値段の半分 / 宿で全快し saveRev が 1 進み save に今の中身が入る / SaveData の符号の往復で同じ / 壊れたセーブは「つづきから」を選べない / 「つづきから」は宿の前の Field / 装備を替えると前の装備がふくろへ戻り、ちからが Doc の値だけ変わる / メニューの取消は 1 つずつ前のページへ。
- P3 で決めた事（実装して決めた。上の節より新しい）:
  - 仲間の顔ぶれの enum は `Member.Member`（`src/Member.flix`）へ移した。`Party` が `PartyDoc`・`ItemsDoc` を読み、`ItemsDoc` が装備できる仲間を `Member` で持つので、~~`Party.Member`~~ のままだとファイルの輪になる。
  - `Party.Stats` は `lv / hp / mp / weapon / armor` だけ（`exp` と Lv ごとの伸び `hpUp…` は P5）。最大 HP・ちから・みのまもり・すばやさは `Party.maxHpOf`・`atkOf`・`defenseOf`・`agiOf` が Doc と装備から導く。`rpg.party.json` に `name, hp, mp, atk, def, agi, weapon, armor` を足した（`joinLv` は P4）。
  - `rpg.items.json` は `name, kind, price, heal, mpHeal, atk, def, luka, mina`（`holySteps`・`burn`・`toto` は使うフェーズで足す）。フィールドで使えるのは heal か mpHeal のある use だけで、せいすい・たいまつは「いまは つかえない」の知らせ。
  - ふくろの並び（どうぐ・うる・装備の候補）は `Bag.listOf`: 使う物 → ぶき → よろい → だいじなもの、同じ種類は値段の安い順。
  - `MenuPage` は P3 で使うページだけ（`SpellWho`・`Spells`・`SpellTarget` は P6）。知らせは `FieldWindow.Notice` で、送った後は `NoticeThen.Close | BackTo(MenuPage)`（`ResumeTalk` は要らなかった）。確かめのカーソルは `World.Answer`。
  - 店の確かめは `ShopPage.Confirm(mode, 道具, 個数, Answer)`。「〜G だよ かうかい？」と はい / いいえ は画面の下の文のウィンドウに出す。
  - 宿は `TransitionThen.InnRest`（payload なし）。会話は暗転の間もウィンドウに置いたまま続きを流さず（`WorldTalk.resumeOrShow`）、晴れたら `WorldTalk.tick` が続ける。覆う長さは `rules.innSeconds`・晴らす方は `fadeSeconds`。宿の前は `rules.homeMap / homeX / homeY`（下を向く）。
  - `<<shop>>` は会話を `FieldWindow.Shop(page, 会話)` へ渡し、やめるでウィンドウを `Talk(会話)` に戻すだけ（`WorldShop` は `WorldTalk` を呼ばない。ファイルの輪を作らない）。
  - ウィンドウを閉じた後の歩きの待ちは `Controls.step` の 1 か所: そのフレームにウィンドウが閉じたら、押している方向の集まりを `awaitRelease: List[Dir4]` に入れ、離した方向から外す（`Dir4` は Order を持たないので Set でなく List）。`World.closeWindow` は閉じるだけ。
  - セーブの中身の比べ方は書く字（`Saves.toText`）どうし（record に Eq が無いので、Party・Bag・SaveData に Eq を足すより安い）。
  - 「起動し直した所」は flow では作れない（`start` のたびに World を作り直す）ので、e2e `e2e/shop_inn.flow` は前半で買う・泊まる・セーブを書くまでを見て、後半は `start title saved=yes …`（中身を引数で組んだセーブ）から「つづきから」を見る。泊まった中身がそのまま戻ることは `TestShop.testContinueRestoresWhatTheInnSaved`（`Fixtures.relaunch` = Main と同じ `World.initial(save)`）が見る。
  - Starts の field に `items=yakusou:3,seisui:1` と `hp=N`、title に `saved=yes` を足した。
  - 村の左の家（扉 3, 3）が宿屋・真ん中の家（扉 11, 3）が道具屋。道具屋の前の商人は呼び込みの台詞に替えた。

### P4 — ワールドマップと坑道

- 作る: ワールドマップ（32×24）・ほこらでトト加入・坑道 B1〜B3・階段・宝箱・ふるびたかぎの扉・イベントのマス・坑道の入口の門・`stepsToFight`（0 になっても P4 ではまだ戦わず引き直すだけ）。
- 完了の条件: 村 → ワールドマップ → ほこら → B3 の扉の前まで歩ける。`world`・`dungeon1`・`dungeon3` を Starts から描く。
- テスト: 村の端から出るとワールドマップの村の印の隣 / 宝箱は 1 回だけ開き中身がふくろへ / 鍵が無いと扉は開かない・有ると開いて旗が立つ / トトがいる時のほこらのノードは台詞を出さない / トトの前は坑道の入口へ進めない / カメラの矩形はマップの矩形 / 出会いの歩数は Doc の範囲から引き、同じ dice なら同じ値。
  性能: ワールドマップで **動く側の描き物が 1 フレーム 800 未満**、タイル層の作り直しはマップを移った時だけ（`make render` の目録と `check-render-budget` で数える）。

- P4 で決めた事（実装して決めた。上の節より新しい）:
  - ほこらは別のマップにしない（マップは 9 枚のまま）。ワールドマップの Q（入れない）の前のマス（25, 12）の `events` と、横に立つトト（id = `toto`）の両方が `Shrine` を開く。`Shrine` は `<<if not $toto>>` の中だけに台詞を持つので、加わった後は着いても何も開かない。
  - `<<join>>` で隊列に入る場所は「話しかけた人」ではなく「いるマップの、id が仲間の名前の人」のマス（イベントのマスで開いた会話でも同じ所から入る）。
  - トトは `joinLv`（2）の Lv で加わる。Lv ごとの伸び（`hpUp…`）は P5 で足すので、P4 のトトの数は Lv1 の値のまま。
  - マップ Doc に `objects {id, kind, x, y, item, count, gold, key}`・`events {x, y, node}`・`encounter {foe1, foe2, foe3, weight}` を足した。宝箱は開けた後もマスを塞ぎ、扉は開けると通れる（鍵は減らさない）。扉の絵は `boss_door`（48×48）を扉のマスの下端の中央に合わせ、開けたら描かない。
  - 開けた旗は `Progress.Rec.opened`（`Set[(MapId, String)]`）。セーブの版を 2 に上げて `opened` を書く（`Saves.load` はマップの表も受け、消えたマップの旗は捨てる）。
  - タイルの組 `world`・`mine`（B1・B2。暖色）・`mine_deep`（B3）を足した。森は歩ける。`x` は水晶の柱と大きな水晶（小物）の下の入れない床。出入口に `edge` の欄は足さない（村の南の出口は端のマスの出入口で足りた）。
  - `stepsToFight` は 0 = まだ引いていない。出会いの組のあるマップで最初の 1 歩の時に引き、マップを移っても持ち越す。0 になったら引き直すだけ（戦いは P5）。`encounter` の敵の名前は P5（`rpg.foes.json`）まで検査しない。
  - 乱数の用途は `Dice.Channel` の enum（P4 は `EncounterSteps` だけ）。知らせを出す口は `World.showNotice`（WorldMenu と WorldField が使う）。
  - 一覧の名前（`WindowView.title`）は字の後ろに墨の札を敷いて、縁の上へはみ出す上半分も読めるようにした（1 行目の場所は変えない）。
  - 性能（実測）: 動く側の描き物はワールドマップで 42〜89・B1 8・B2 11・B3 76・村 47（1 フレーム。`TestWorldMap.testWorldMovingItemsStayUnderTheBudget` が 800 未満を見る）。タイル層はワールドマップで 1 枚（タイル 556 枚）。鍵はマップの名前とアトラスの鍵なので、作り直しはマップを移った時だけ（`testTileLayersStayWhileWalkingOnOneMap`・`testTileLayersChangeWithTheMap`）。
  - e2e は `e2e/world_mine.flow`（村の出口 → ほこらでトト → 坑道の入口 → B1 の宝箱）。

### P5 — コマンドバトル（たたかう・にげる）

- 作る: `Battle`・`WorldBattle`・`BattleView`・`rpg.foes.json`・`rpg.foe_moves.json`（attack / guard / sweep）・`rpg.recolors.json` と色違いのアトラス・出会いから戦いへ・レベルアップ・全滅・`<<fight>>` と afterWin。
- 完了の条件: 草原と坑道で戦い、勝って経験値とお金を得て Lv が上がる。負けると宿の前。`battle` を Starts から描く。
- テスト: `resolveRound` は同じ rec・plans・dice なら同じ Beat の列 / 演出の途中の HP の表示は見せている Beat の after（最後の結果を先に出さない）/ ダメージの下限は 1 / guard した敵へのダメージは半分 / 行動順はすばやさの大きい順（同じ dice で）/ 倒れた的への行動は別の的へ / 経験値は生きている仲間だけ / 表を 2 つまたぐと 2 レベル上がる / 全滅でお金が goldKeep で切り捨て・HP 全快・宿の前 / 逃げる率は 0.1..0.95 / noFlee の組で にげる は手番を使う / 同じ名前の 2 体は A と B / 1 戦の敵は 3 体まで / foes Doc の 3 本 / 全部の敵の sprite と recolor が絵と色票で引ける。
  e2e: `e2e/first_battle.flow`（`battle foes=kusausa` から勝つまで）。
  シミュレーション: `src/sim/` の Bot・BotRun・BalanceSim を作る。`make bot` がタイトルから B3 の扉の前まで BOT_RUNS=5 で詰まずに着く。`make balance` の雑魚の表を見て、⚠ の行を Doc で直すか、直さない理由をレビューに書く。

- P5 で決めた事（実装して決めた。上の節より新しい）:
  - 戦いの進みは `World.Phase = Choose(仲間, CommandPage) | Show(Beat の列, 出し始めた時刻, AfterShow)` の 2 つに畳んだ。`AfterShow = Choose | Judge | Leave(Outcome)`。
    現れた・1 ターン・勝ち（やっつけた・経験値・お金・レベルアップ）・全滅の伝言はどれも Beat の列で、出し終えた後にする事だけが違う（4.4 の Opening / Run / Victory / Defeat / Fled は Show の AfterShow で表す）。
  - コマンドは たたかう / じゅもん / どうぐ / ぼうぎょ / にげる の 1 列 5 つ（じゅもん・どうぐ は P6 まで灰色で `Denied`）。`CommandPage = Commands(カーソル) | FoeTarget(生きている敵の何番目か)`（呪文と道具のページは P6）。
    ぼうぎょ は `Battle.Plan.Defend`（そのターンに受けるダメージを半分・切り上げ。敵の guard と同じ式）。
  - `Battle.Rec = { party, foes, guarding, defending, fled }`（bag と asleep は P6 で足す）。Beat = `{ lines: List[Msg], fx: Option[Fx], after }`・`Msg = { text: TextDoc.BattleText, values }`（字にするのは見せる側）。
    敵の技は 1 ターンの頭に全部の敵の分を引く（guard はそのターンの初めから効く）。`Target = Foe | Ally | AllAllies`（AllFoes は P6 のアイス）。
  - 1 枚の Beat は「演出 0.4 秒（`WorldBattle.fxSecondsOf`。1 行目の伝言は演出の間から出す）→ 残りを文字送り → 出し切って `rules.messageWait` 秒」で次へ。決定で出し切る → もう 1 回で次へ。Timeline は P6（呪文の演出）で入れる。
  - 出会いは「何も無いマスに着いた時」だけ数える（出入口とイベントのマスでは数えない。点滅と暗転・会話が重ならない）。出会ったら歩きを止めて点滅（`TransitionThen.StartBattle(敵, afterWin)`・`rules.flashSeconds`）→ 覆い切ったら `WorldBattle.enter`。
    `<<fight 敵 [ノード]>>` も会話を閉じて同じ点滅へ渡す。逃げた後の歩数は、出会った時に引き直してある値のまま。
  - 経験値は `rpg.party.json` の `exp {lv, total}`、Lv ごとの伸びは仲間の行の `hpUp…agiUp`（Lv1 の値 + 伸び × (Lv − 1)）。`Party.Stats` に `exp` を足し、セーブの版を 3 に上げた。トトは加わった時に Lv2・経験値 12。
  - 全滅の後の宿の前は `WorldShop.homeOf`（「つづきから」と同じ。`WorldField` から移した。WorldBattle が WorldField を呼ぶと輪になる）。
  - 色違いは 1 体ぶんの絵だけを焼いたアトラス（`Sheet.recolored`・`px_foe_<敵の鍵>`）。差し替えは あかぼうし = 帽子の黄 → 赤・ひのこ = 体の橙 → 赤と額の水晶 → 黄・はなウサ = 葉と体 → 桃・ふかね = かさ → 紫・こおり = 殻 → 青。
  - Starts に `battle foes=… lv=…`・field に `lv=`・`steps=`（次の戦いまでの歩数。歩く手順の flow は 999 で出会わない）を足した。flow の問いに `lv`・`foes`、操作に `drive battle`（伝言とコマンドを決定で送る）。
  - P4 で入っていた `MapDoc.encounterOf` の読み違い（`"foe1" :: … :: Nil |> List.filterMap` の結合の順で、敵の名前でなく欄の名前を持っていた）を直した。P5 で敵の名前を検査して見つかった。
  - bot（`src/sim/Bot.flix`・`BotRun.flix`）は どうのつるぎ を買って付け、B1 の かわのよろい・B2 の まほうのローブ を開けて付ける（`goalOf` の表に 1 行ずつ）。せいすい・やくそう は買わない（戦いで使うのは P6）。
    入口の名前は `BotRun.play`（`run` は Flix の予約語）。BalanceSim の区間の Lv は bot の「区間に入った時の Lv」（world 1・B1 2・B2 3・B3 5）。

### P5.5 — トトと坑道（依頼主のテストプレイ 1 回目の直し・`docs/proposals/toto-and-mine.md` 改訂 2）

前半（済み）: テストプレイの指摘 1・4・5・6・7 の直し・トトの加入を T1「なくした杖」へ・仕掛けの基本の 3 種（lever・gate・guard）。
後半（済み）: 坑道 B1〜B3 の作り直し・plate・rock・cart・junction・dark・pit・crystal・bridge・sign・中ボスとひとくいばこ・B3 の人（ミナの父）・鍛冶屋をミナの祖父へ。

- P5.5 で決めた事（実装して決めた。上の節より新しい）:
  - **村の出口は外周の端の全部**。`exits` の行に `edge`（`all` か `up / down / left / right`）を書くと、その辺の端のマスから外へ押した時に移る（`MapDoc.ExitPlace = Cell(x, y) | Edge(向き)`・`MapDoc.edgeExitOf`）。
    端のマスに着いただけでは移らない（端を歩いて回れる）。押したまま着いたら、次のフレームの押しで移る。gate は端の出口にも効く（`WorldField.closedGateOf`）。
    村の西の道の端（0, 9）は鍛冶屋の前へのマスの出口のまま（着くと移るので端の出口より先に効く）。P4 の「edge の欄は足さない」は取り消し。
  - **隊列の trail は 3 つ**（2 人目・3 人目が立つマスと、3 人目が動き出す 1 つ前のマス）。3 人目も先頭と同じ進み具合で前のマスから動く（`World.trailLength`）。
  - **会話の音**: 開く（`talk_open`）・送る（`talk_next`。選択肢を選ぶ時は決定の音）・文字送り（1・3・5… 字目に `talk_low / mid / high`）。声の高さは `rpg.text.json` の `speakers` の `voice`（書かない話し手と地の文・知らせは mid）。
    鳴らすのは `Controls.talkSoundsOf` の 1 か所で、前後の World の見比べから出す（会話と知らせの 2 つの文字送りに同じ数え方を書かない）。知らせ（宝箱など）も同じ音。
  - **装備の画面**: そうびの「ぶき / よろい」の一覧の右に付けている物の名前を出さない（幅 15 マスで「よろい」と 7 字の名前が重なった）。付けている物は下のつよさのウィンドウに出ている。描き出しの場面 `equip` で見る。
  - **まりょくのみ**: 使えていたが、P5 まで MP が減らないので「しかし なにも おこらなかった」しか出なかった。HP も MP も最大の人に使うと減らさず「〜には いまは ひつようない」と出す（倒れている人は今のまま）。Starts の field に `mp=` を足した。
  - **物の種類 3 つ**: `lever`（壁のマス。調べると `flag` の旗を立てる / 下ろす。絵は up / down のコマ）・`gate`（`flag` が `openWhen` の時だけ通れる。閉じていれば調べると「てつごうしが おりている」）・
    `guard`（調べると `node` の会話。消すのは勝ちのノードの `<<open id>>`）。旗は `Progress.Rec.flags`（セーブの版 4 のまま往復する）。番をする者の絵は、人の絵（rpg.chars）にあれば下向きの足踏み・敵の絵（rpg.monsters）にあればそのコマを回す・どちらにも無ければその組の絵（化けた宝箱）。
    立てる物の無い gate の旗は `Res.flagProblemsOf` が起動時に言う。レバーを動かすと `lever` の音。飛び石（湖の上の gate）は水のマスを通れるようにする口が要るので後半（B3）で決める。
  - **会話**: `$has_<鍵>`（items の kind = key の物を持っているか。`Talk.SyncedVar.Has`）・`<<take 道具 個数>>`・`<<open 物の id>>`（今のマップの objects のどの種類にも効く。どのマップにも無い id は `Talk.problemsOf` が言う）を足した。
    番をする者の `node` も「コードが開くノード」（会話の語彙）に入る。`<<fight>>` の勝ちのノード（`StaffBack`）は語彙に入らないので、`bin/fge yarn build` が「開かれない」と注意を 1 行出す（止めない）。
  - **トトの加入**: ほこらのイベントのマスを消した。トトに話しかけた時だけ `Shrine` が開く（依頼の前は修行の話・依頼の後は杖の話とミナの一言・`$has_totostaff` なら返して加わる）。噂は依頼の後の `Woman`。
    森の岩穴 `toto_cave`（16×15・mine の組・出会い無し）はワールドマップの (21, 18) の `C`（`cave_mouth`。森の縁の絵を選ぶ時は森として数える）。入口の部屋の北に鉄格子、右の壁にレバー、奥にほりモグ（`horimogu` の 1 体・`<<fight horimogu StaffBack>>`）。
    だいじなもの `totostaff`（トトのつえ）。坑道の入口の gate（toto）と `MineGate` は今のまま。
  - bot（`Bot.goalOf`）はトトの前に「岩穴のレバー → ほりモグ → トトに話す」の 3 行。~~`Aim.Open`~~ は `Aim.Examine`（物を調べる。宝箱・レバー・番をする者）に、端の出口へは端のマスで外へ押す（`Bot.Arrive.Push`）。
    `make balance` に森の岩穴の区間（ルカ・ミナ Lv1・固定の戦いは重みの欄が「固定」）を足した: ほりモグ 1 体は勝率 100%・2 ターン・受けるダメージ 18%。
  - 描き出しの場面に `cave`（森の岩穴）と `equip`（そうびのページ）を足した。e2e は `world_mine.flow`（杖を取り戻してトトが加わり B1 の宝箱まで）と `quest_join.flow`（端の出口）を直した。

  - **後半: 物の種類を 7 つ足した**（`MapDoc.ObjectKind`。JSON は平らなまま）: `plate`（`flag`・`hold`）・`rock`・`cart`（`dir`・`node`）・`junction`（`flag`・`dir`・`dirOn`）・`crystal`（`flag`・`order`）・
    `bridge`（飛び石。`flag`）・`sign`（石碑。`node`）。案の表に無い `bridge` と `sign` は、飛び石を gate で書けなかった（gate は旗で「無くなって通れる」、飛び石は旗で「現れて水の上を通れる」で向きが逆）のと、
    石碑を guard で書くと「番をする者」の名と合わないため。塞ぐかは状態だけでなく種類も見る（`WorldObject.blocks`: 床のスイッチ・分かれ目・飛び石は塞がない）。水の上に立てるのは `WorldObject.floors`。
    1 マスに物が 2 つ並ぶ（床のスイッチに岩）ので、`WorldField.Occupancy` の物はマス → 並び（塞ぐ物が先）。床に敷く物は `FieldScreen.thingBoxOf` の `flat` で Over の層に描く。
  - **岩**: 今のマスは `FieldRec#rocks`（場面の値。`World.arriveAt` で空 = マップを出ると Doc の位置へ戻る。セーブに書かない）。押すと岩が 1 マス動いて先頭も進む（`WorldObject.pushRock` → `WorldField.pushOrBump`）。
    岩の行き先は歩ける床で、人・出入口・会話のマス・床のスイッチ以外の物が無い所だけ（`rockCanEnter`）。押さえる床（hold）は同じ旗の床が全部沈むと旗を立て、そのまま（岩をどけても開いたまま）。
  - **トロッコ**: `<<ride>>` は `Stride.Boarding` を置くだけで、次のフレームに `WorldField.board` が `Rail.startRide` で道を 1 回引いて `Stride.Riding({ cart, path, startedAt })` にする
    （会話から物の今を読むと WorldObject → WorldTalk → WorldObject の輪になるため）。走れなければ「トロッコは うごかない」。1 マスは `rules.secondsPerRail`（0.08）。走っている間は Busy・出会いもたいまつの歩数も数えない・2 人目と 3 人目は描かず、降りると trail を空にする。
    **レールのマスは歩けない**（`Tileset.minePassages` から = | を外した。歩いて辿ると分かれ目のレバーを使わずに先へ行けるため）。降りる所はレールの終わりのマスで、そこから隣の床へ歩いて出る。
    分かれ目の絵は `rail_switch`（西から来て north / south へ曲がる 2 コマ）なので、B1 の分かれ目は旗が下りていれば北・立っていれば南（→ 東の坑道）。曲がり角の絵は `Autotile.Cell.Joined`（隣のレールの向きで縦・横・4 つの角）。
  - **暗さ**: マップの `dark`。墨は見えているマスごとの矩形（明かりの縁の 1 マスの輪は 4 分の 1 の墨を市松に 2 枚のディザ）で `ZOrder.Layer.Dark`（290..299）。見える広さは `rules.darkRadius`（1）/ `torchRadius`（3）。
    たいまつの残りは `FieldRec#light`（`lightSteps` 120。暗いマップで 1 マスごとに減る）。案の「Progress に持ち、セーブの版を上げる」はやめた: セーブは明るい村の宿でだけ書くので、残りを書いても読む時に意味が無い。
    描き物の数は B2 の迷路の真ん中で 291・B3 の湖の前で 130・B1 の広間で 26（`TestMine.testMineMovingItemsStayUnderTheBudget` が 800 未満を見る）。
  - **出会いの歩数**: マップに `minSteps / maxSteps`（坑道は 3 枚とも 30..44）。片方だけ・逆さまは rules の範囲に落として 1 行言う。
  - **店を 2 つ**: `rpg.shops.json` の goods の行に `shop`（空 = 村の道具屋・mine = コロン）。`FieldWindow.Shop(店の名前, ページ, 会話)`。
  - **会話**: `<<heal>>`（全快）・`<<ride>>`・`<<shop 名前>>` を足した。鍛冶屋はミナの祖父（「せがれが こうどうから もどらんのじゃ」）。B3 の取り残された人はミナの父（話すと全快・水晶の順番。ミナが仲間なら親子の会話）。
  - **マップ**: B1 32×30（入口・ボルじい → 分岐の広間（かわのよろい・レバー・トロッコ）→ 北の行き止まり（てつのつるはし・帰りのトロッコ）/ 東の坑道（下り階段）。岩の部屋 1 → 小部屋（やくそう×3・120G）。東の坑道の南の細道の奥のレバーで入口の格子が上がる帰りの近道）。
    B2 48×30 の暗い迷路（入口の小部屋にコロンとたいまつ×3・行き止まりに かぎ・まほうのローブ・まりょくのみ×2・一番奥にくろがねゴブリンとはがねのつるぎ・割れた床 3 つ → B3 の西の小部屋（せいすい×2・上り階段で B2 の入口へ））。
    B3 32×30（上り階段の部屋にミナの父と石碑 → 湖の岸の水晶 3 つ（東・西・北）→ 飛び石で小島（みずのはごろも）と北の岸（封じられた扉）。東の岩の部屋 2（岩 2・床 2）→ ばくだんいし×3 と ひとくいばこ）。
    座標の設計は 1 枚の台本（scratchpad の gen_mine.py）で書いて JSON に書き出した（台本はリポジトリに置かない。直すのは JSON）。
  - **敵**: くろがねゴブリン（`goblin` の色違い `iron` = 帽子の黄 fc28 → fc00・明るい黄 fc38 → fc10・逃げられない）とひとくいばこ（`mimic`・逃げられない）。ひとくいばこの技は案の sleep が P6 なので今は attack だけ。
    色違いのテクスチャは 6 枚になった（12 節の「5 枚を超える時は重さを測る」: 起動の重さは測っていない。Res の作り直しはマップを移る時ではなく Doc を読み直す時だけなので、遊んでいる間の重さは変わらない）。ジェムイーターの HP 360 → 460（Doc）。
  - **道具**: てつのつるはし（ミナ +9）・はがねのつるぎ（ルカ +11）・みずのはごろも（3 人 +8）・ばくだんいし（`burn` 40）。items に `lightSteps`・`burn` の欄（`burn` を使うのは P6 の戦いのどうぐ）。
  - **bot**: `Bot.goalOf` に坑道の宝・岩の部屋（押す手は `rockPlanOf`）・中ボス・ひとくいばこ・水晶（order の順）・ミナの父（B3 で HP 60% 未満）の行と、村の外で HP 60% 未満なら やくそう を使う `Goal.Heal`。
    トロッコとレバーは表に書かず、目的へ歩いて着けない時に `detourOf` が「乗れば着くトロッコ」→「動かせばそうなるレバー」の順に選ぶ。扉の前は (16, 6)。
    レポートに「人の目安」（歩き・暗転・トロッコの秒 + 戦い × 33 秒 + ウィンドウ × 3 秒）を足した: bot のゲーム内時間は 4:00 前後、人の目安は 14 分前後（扉の前まで。ボスと帰りと、人が仕掛けを考える時間は入っていない）。
  - **テスト**: `test/TestMine.flix`（トロッコと分かれ目・レールを歩けない・岩と床・岩はマップを出ると戻る・マップの出会いの歩数・暗さとたいまつ・落とし穴・中ボス・店 2 つ・水晶と飛び石・床 2 つ・ひとくいばこ・全快・セーブで旗と点けた水晶が残る・描き物の数）。
    e2e は `mine_b1.flow`（岩の部屋 1 → レバー → トロッコ → B2）・`mine_b2.flow`（たいまつ → くろがねゴブリン → はがねのつるぎ）・`mine_b3.flow`（水晶 3 つ → 飛び石 → 扉）。描き出しの場面に `dungeon2`（暗い迷路）を足し、`dungeon1`・`dungeon3` を新しいマップで撮り直した。

### P6 — じゅもん・どうぐ・眠り・敵の呪文

- 作る: 戦いの じゅもん / どうぐ のページと的・`rpg.spells.json`・敵の fire / ice / sleep・眠り・battlefx のタイミング（`Timeline`）・フィールドのヒール（P3 の灰色を外す）。
- 完了の条件: トトのファイア・アイス、ルカのヒール、やくそう・たいまつが戦いで使え、ヒールがフィールドでも使える。`magic` を Starts から描く。
- シミュレーション: bot の方針にヒール・やくそうを足し、同じ範囲を BOT_RUNS=5。`make balance` の全区間の雑魚の ⚠ を Doc で直す。
- テスト: MP が足りない呪文は選べない / アイスは生きている敵全部 / ヒールは最大 HP で止まる / 戦いで使った道具は 1 つ減る / せいすいは戦いで灰色 / 眠った人は選ぶページを飛ばされ、次の手番は必ず眠る / 仲間が全員眠っても戦いが止まらない / spells Doc の 3 本。

- P6 で決めた事（実装して決めた。上の節より新しい）:
  - **呪文の Doc** `assets/rpg.spells.json`（catalog: `name, mp, power, aim, field, fx`）。4.4 の `target` は `aim`（`foe` / `allFoes` / `ally`。ally は回復）にした。覚える表は `rpg.party.json` の list `learns {member, spell, lv}`（加わった時の Lv までの行は加わった時から覚えている）。
    呪文を指す名前は `SpellsDoc.SpellId`（非 pub の enum + `pub type alias`）。覚えた呪文は `Party.spellsOf`（導く。World に持たない）。レベルアップで覚えた呪文は「〜は 〜を おぼえた！」の Beat（`Battle.resolveVictory`）。
  - **敵の呪文**: 2.3 の act の語彙 `fire / ice` はやめ、`act = spell` と `spell` の欄（呪文の鍵）にした（`FoeMovesDoc.Act.Spell(鍵)`）。敵に呪文を 1 つ持たせるたびにコードを足さずに済む。鍵は `Res.problemsOf` が確かめる。数は仲間と同じ spells の行（敵は MP を使わない）。敵の回復の呪文は唱えた敵自身を戻す。
  - **眠り**: `act = sleep`。率は `rules.sleepRate`（0.6）・起きる率は `rules.wakeRate`（0.5）。`Battle.Rec#asleep: Map[仲間, 眠ってから過ぎた手番]`。眠った次の自分の手番は必ず「ねむっている」、その次から wakeRate で起き、起きた手番は動かない。
    選ぶ人は `Battle.choosersOf`（生きていて眠っていない人）で、全員眠れば Choose を飛ばして敵だけのターンを流す。倒れたら眠りも消す。
  - **戦いのふくろ**: `Battle.Rec#bag`。`Battle.start` が World のふくろを受け、勝ち・逃げ・全滅のどれでも World へ書き戻す（全滅でも使った道具は減ったまま）。同じターンに 2 人が同じ道具を選んだ分は一覧の残りから引き（`WorldBattle.itemsOf`）、手番で無くなっていれば「もう なかった」。
    戦いのどうぐの一覧は使う物（kind = use）だけ並べ、戦いで効く物（heal / mpHeal / burn）だけ選べる（せいすいは灰色）。burn の物（たいまつ・ばくだんいし）は敵 1 体に burn をそのまま（ぶれ・まもり無し。guard は半分）。
  - **コマンドのページ**: `CommandPage` に `SpellList`・`SpellTarget(呪文, カーソル)`・`ItemList`・`ItemTarget(道具, カーソル)`。敵全部の呪文は的を選ばない。取消は 1 つ前のページ（`WorldBattle.parentOf`）。
    右の一覧のウィンドウ（5 行）に呪文（右に MP）・道具（右に残り）・的を出し、入りきらなければカーソルが見える所まで送る（`ViewBattle.scrolled`）。じゅもん は呪文を覚えていない人・どうぐ は戦いで使える物が無い時に灰色。
  - **演出**: `Battle.Fx = { kind, target, seconds, shake }`・`FxKind = Slash | Hit | Spell(絵の名前) | Burn | Mend`。敵全部の呪文は生きている敵ごとに絵を置き、仲間への演出は帯の下のその人の列に置く。仲間が叩かれた（呪文も）時だけ背景をゆらす。
    `Timeline` は入れなかった: 演出は 1 枚の絵のコマを fxSeconds の進み具合で選ぶだけで足り、音は P8 で出来事の表に付ける。
  - **フィールドの じゅもん**: `MenuPage.SpellWho → Spells → SpellTarget`。唱えられるのは `field = true` の回復の呪文だけ（戻すのは power。ぶれ無し）。HP が最大の人・倒れた人には MP を使わずに知らせ。じゅもん は誰も呪文を覚えていなければ灰色。
  - **描き出し**: `magic` は Starts から（同じ組でトトが じゅもん → ファイア → 先頭の敵 と選び、演出の 3 割まで進めた所）。旧 ~~`BattleScenes.magic`~~ は消した。
  - **e2e**: `e2e/battle_magic.flow`（やくそう・せいすいの灰色・ファイア）。flow の問いに `mp`（仲間の MP の合計）と `page`（コマンドのページ）を足した。
  - **bot** の戦いの方針（`Bot.battlePlans`）: HP 35% 未満の仲間（このターンにまだ誰も回復しない人）を回復の呪文 → HP の戻る道具で回復。逃げられない組では回復の呪文の MP を残して攻めの呪文（敵 2 体以上なら敵全部の呪文）→ たたかう の 2 倍より強い burn の道具。ほかは HP の一番少ない敵を たたかう。
    フィールドでは HP 60% 未満の人に回復の呪文（`Goal.Cast`）→ やくそう。コマンドのページは `Bot.wantedRowOf` が方針の行動へ向けて送る。ばくだんいしは攻めの弱い人（トト）だけが投げるので、ボス（P7）まで残る。
  - **balance**: 区間のふくろ（`Section#bag`）を持たせ、使った MP と道具の列を足した。固定の戦いのうち逃げられない物（中ボス・ひとくいばこ）は「ルカの 2〜3 発」でなく 3〜5 ターン（中央値）で見る。B2 の奥の区間は固定の戦いだけを流す（Lv5 で B2 の雑魚を流すと 1 発で倒れて ⚠ になるが、その Lv で B2 の雑魚とは戦わない）。
    Doc で直した数: ひとくいばこ HP 90 → 160（ばくだんいしとファイアで 1 ターンで倒れた）・ひのこコウモリ ちから 17 → 16 と技の重み attack 2 → 3（ファイアがまもりを見ないので 2 体の組の受けるダメージが 31%）。くろがねゴブリンはファイアで 4 ターン・受けるダメージ 22% で直さなかった。
  - 敵の技の行: ねぼけダケ attack 3・sleep 1 / ふかねダケ attack 2・sleep 1 / ひとくいばこ attack 2・sleep 1 / ひのこコウモリ attack 3・spell fire 1 / こおりヤドカリ attack 1・spell ice 1・guard 1。

### P7 — ボス・帰村・エンディング

- 作る: ボスの間のイベント・`<<fight gemeater BossWon>>`・phase 2・BossWon の会話と `<<warp>>`・泉が湧いた村・報告とお礼・`EndingView`・エンディング → タイトル。旧 `FieldScenes` / `BattleScenes` を消し、13 場面を全部 Starts から描く。
- 完了の条件: はじめからエンディングまで通して遊べる。`make bot BOT_RUNS=10` が 10 本ともエンディングに着き、ゲーム内時間が 10〜20 分に入る。`make balance` のボスの表が 6〜8 ターン・Lv 6 で勝率 70〜95% に入る（入らなければ Doc で直す）。bot が `playthrough.flow` を書く。
- テスト: ボスに勝つと段階が BossDown で坑道の入口にいる / BossDown の前は報告できない / 報告でお金が rules.reward だけ増え段階が Reported / ボスに負けて宿の前から戻ると、扉の奥のイベントでまた戦える / HP が phase2At を切った手番の後から phase 2 の技を選ぶ。
  e2e: `e2e/playthrough_*.flow` の 4 本（村 → 出発 / ワールド → B1 / B2 → B3 / ボス → 報告。Starts で各区間の頭から）。

- P7 で決めた事（実装して決めた。上の節より新しい）:
  - **依頼の段階** `Quest { NotAsked | Accepted | BossDown | Reported }` は `src/Quest.flix` の `Quest.Quest` へ移した（~~`Progress.Quest`~~ から）。マップ Doc の人と小物が段階を持つので、
    MapDoc が段階を使う。Progress はマップの名前（`MapDoc.MapId`）を使うので、~~`Progress.Quest`~~ のままだとファイルの輪になる。
  - **ボスを倒した段階は会話の `<<quest defeat>>`**（勝ちのノード `BossWon` が流す）。4.2 の「`foes.noFlee` のボス戦に勝つと BossDown」はやめた: 中ボスとひとくいばこ（P5.5）も noFlee なので、
    勝っただけで段階が進んでしまう。お礼は `<<quest report>>`（`rules.reward` = 300。台詞は `{$reward}`）。会話の変数 `$reward` を足した（`Talk.SyncedVar.Reward`）。
  - **ボスの間**: B3 の扉の奥（12..20, 1..4）に `guard` の `b3_boss`（絵は敵の `boss` 96×80。扉のマス (16, 5) から調べる。部屋いっぱいに描かれる）と水晶の小物 4 つ。
    `Boss` のノードは `$quest == "accepted"` の間だけ `<<fight gemeater BossWon>>`。負ければ宿の前で、`b3_boss` は開いていないので挑み直せる（イベントのマスは使わず、番をする者の形）。
  - **坑道の入口へ戻す**: 出口に `edge` = `none`（`MapDoc.ExitPlace.Nowhere`。歩いては通らない）を足し、B3 に `to_surface`（行き先はワールドマップの (20, 4)）。会話の `<<warp 出口の id>>` が暗転で移す（`WorldTalk.warp`）。
    x / y の書き忘れを「通らない出口」と読まないよう、`none` は書かせる。bot のマップの間の道はこの出口を通らない（`Bot.isWalkable`）。
  - **泉が湧いた村**: マップ Doc の `npcs` / `props` の行に `questFrom` / `questUntil`（段階の名前。両端を含む。`MapDoc.Span`）。知らない名前は行ごと読めない扱い。同じマスに段階の違う人を並べてよい（`npcAt` はマス → 並び。立つのは `MapDoc.standingAt`）。
    村: `spring_dry` は accepted まで・`spring_full`（3 コマ）は bossdown から。bossdown から村長（`chief_spring`。泉の上 (7, 5)・`ChiefReport`）・子ども・商人・鍛冶屋（ミナの祖父）・ミナの父が泉のまわりに立ち、長老・元の子ども・商人は accepted まで。
    村長の家の村長と B3 のミナの父は accepted まで（ミナの父はボスを倒すと村へ帰る。案の筋）。旧 ~~`FieldScenes.clear`~~ の人の並びを写した。
  - **エンディング**: `World.Scene.Ending(EndingState = { startedAt, back })`。`<<ending>>` → `TransitionThen.Ending`（覆う方は `rules.innSeconds`）→ `World.enterEnding`。
    2.3 の `Ending(Clock.Time[Clock.Real])` はやめ、遊びの時計にした（流れ切ったかで決定が効くかを決めるので、絵だけの時刻ではない）。絵は報告した村を下敷きに描き（`World.shownFieldOf`）、
    下のウィンドウの中をスタッフの字（`rpg.text.json` の `credits`。`{lv}`・`{gold}`）が `rules.creditSeconds`（24 秒）かけて下から上へ流れ、流れ切ると「おわり」（`menu` の `theEnd`）。
    流れている間の決定は効かない（報告の台詞を送る連打で飛ばさない）。流れ切った後の決定で `World.toTitle`（セーブは書かない・消さない。「つづきから」は最後に泊まった宿から）。
  - **描き出し**: 旧 ~~`FieldScenes`~~ / ~~`BattleScenes`~~ を消し、15 場面 + `ending` の 16 場面を全部 Starts から描く（`boss` = `battle foes=gemeater` の現れた・`clear` = `ChiefReport` のお礼の行・`ending` = Starts の `ending` で 3 割流れた所）。
  - **e2e**: 4 本の `playthrough_*.flow` は作らず、`e2e/boss.flow`（扉の奥 → ボス → BossWon → 坑道の入口）と `e2e/report_ending.flow`（ワールドマップ → 村 → 報告 → エンディング → タイトル）の 2 本にした。
    前の 3 区間は `quest_join`・`world_mine`・`mine_b1`〜`b3` が同じ道を見ている。通しは bot の `debug/bot/playthrough.flow`（下）。
  - **bot**: `Bot.goalOf` に「扉を開ける → HP か MP が減っていればミナの父 → ボス → 村の泉の村長」の 4 行。エンディングに着いた所で表を数え（`Bot.isAtEnding`）、字が流れ切ってタイトルへ戻るまで流す。区間に `boss`・`return`（`BotRun.sectionOf`）。
    1 本目の手を `debug/bot/playthrough.flow` に engine の記録の書き手で書く（区間の頭ごとに `mark` と `expect quest=…&scene=…&map=…`）。bot の 1 フレームはナノ秒に丸めた 1/60 秒（丸めないと流し直した時に文字送りの境目が 1 フレームずれる）。
    `make flow FLOW=debug/bot/playthrough.flow` でタイトルからエンディングまで同じ指紋で流れる。Starts の `title` に `seed=` を足した。
  - **数**（BOT_RUNS=10・種 0〜9）: 10 本ともエンディング・全滅 0。ゲーム内時間 4:38〜5:09・人の目安 16:05〜18:28（歩き 3 分前後・戦い 19〜21 回・ウィンドウ 42〜49 枚。人が仕掛けを考える時間は入っていない。
    案の見積もりでは仕掛けに 3.1 分 → 足すと 19〜21.5 分）。ボスに入った時の Lv は 7（10 本とも）、帰り道で 0〜2 戦。
  - **balance のボス**: `BalanceSim.bossAt(5 / 6 / 7)`（装備とふくろは bot が扉の奥に入った時の物）。HP 460・ちから 34 では Lv6 で勝率 99%・9 ターン（長くて負けない）だったので、
    Doc で HP 460 → 360・ちから 34 → 41 に直した: Lv6 で勝率 83%・8 ターン（中央値）・全滅 17%。Lv5 は 35%・Lv7 は 100%（bot は Lv7 で入るので楽に勝つ）。目安は「Lv6 で 6〜8 ターン・勝率 70〜95%」（受けるダメージは見ない）。

### P8 — 音と仕上げ・テンプレとしての出荷

- 作った（P8 前半）: 曲 6 本とファンファーレ・残りの効果音・mixer（4.9 節）・テスト `TestSounds`。
- 作る（P8 後半）: `make video`（`VideoRender`）で通しの動画を撮って依頼主へ渡す・つり合いの確かめ（bot と balance の最終の数を 5.4 の表と並べ、README と `docs/balance.md`（予定） に残す）・`reference/title.png` と `SHA256SUMS.txt`・`/add-template` の 7 手順・`AGENTS.local.md` の早見表の見直し（9 節）・README。
- 完了の条件: `/add-template` のチェックリストが全部埋まる。`make reference-check` が緑。音の下限を満たす。`debug/video/rune.mp4` を依頼主が見られる。`make bot BOT_RUNS=10` が緑のまま。
- テスト（`TestSounds`・済み）: 出来事 → 音の名前の表 / project.json の sounds に全部ある（出来事・呪文の fx・曲）/ 階段は扉と別の音 / 曲の宣言はマップの bgm に従い（どのマップにも曲がある）、戦いの間は戦いの曲・逃げられない敵はボスの曲・勝ちの伝言の間は止めてからマップの曲へ戻る。

## 8. ファイルの割り方（目安）

`src/`: World・WorldField・WorldTalk・WorldMenu・WorldShop・WorldBattle・Battle・Party・Bag・Progress・Dice・InputLayer・Saves・Talk・Tileset・MapDoc・PartyDoc・FoesDoc・FoeMovesDoc・RecolorsDoc・SpellsDoc・ItemsDoc・ShopsDoc・RulesDoc・TextDoc・KeysDoc・Res・Game・Main・Controls・Starts・E2e・ZOrder・View・TitleView・FieldScreen・FieldView・WindowView・MenuView・ShopView・BattleView・EndingView・Sheet・Palette、`src/render/`: SceneRender・VideoRender、`src/sim/`: Bot・BotRun・BalanceSim。
合わせて src 6500 行・test 1800 行ほど。1 ファイル 400 行を超えたら割る。

## 9. 早見表に書く事（AGENTS.local.md。P1 の後に作った。フェーズごとに足した仕組みの行を 1 行ずつ足す）

場面の表（場面・payload・入る関数・View・Starts の名前）と、「この変更 → このファイル」の表（敵を足す → foes.json・foe_moves.json・マップの encounter / 色違いを足す → recolors.json と foes の recolor / 呪文を足す → spells.json と Battle の act / マップを足す → maps/*.map.json と exits / 会話を足す → rune.yarn と npcs の node / コマンドを足す → Talk.Command と WorldTalk の枝）。internet_dungeon の `internet_dungeon/docs/world-map.md` 4 節の形。

## 10. 決まった事（依頼主と親の決定）

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

依頼主に新しく確かめる事は無い。色違いの名前（はなウサ・ふかねダケ・ひのこコウモリ・あかぼうしゴブリン・こおりヤドカリ）は P5 のレビューで見せる。

## 11. engine への相談事項（独断で前提にしない）

1. **決まった種の乱数**: `RandomUtil` は `Math.Random` なので、テンプレでは `Hash01` + World の回数（`Dice`）で引く。2 本目のゲームでも要れば engine に足すかを相談する。
2. **マス単位の移動と隊列の追従**: engine に無い（`make module Q=GridMove` は当たり無し）。テンプレの `WorldField` に書き、別のゲームが要った時に engine へ移すかを相談する。
3. **旧 rpg-starter を指す engine の設定と文書**（P1 の頭で、依頼主の承認を取ってから直す）: `bin/lint-rules/record-wrap.json` の除外 2 行（消す）・`docs/modules/map.md`（TownMap.flix）・`ui.md`・`time.md`・`light.md`（World.flix / View.flix）・`docs/shader-doc.md`（town.shader.json）・`docs/backlog.md`（新しいファイルへ指し直すか、別のテンプレの実例へ替える）。
4. **タイル層の Tileset**: `TileLayerSpec` の `Tileset` を `PxSpriteAtlas` のアトラスから作る道が無ければ、作る関数を engine に足すかを相談する（それまでは地面も動く側で、見えているマスだけ描く。17×16 マス + 縁と人と小物で 800 未満に収まるので、P4 の条件はどちらの道でも満たせる）。
5. **色違い（パレット差し替え）**: 済み（相談は要らない）。`PxSpriteAtlas.bake(doc, resolver)` の resolver で色票の鍵を差し替えれば足りる（4.4）。
6. **会話の実行器をコマンドの後で止める口**（依頼主へ相談。今は足さない）: `YarnRunner` はコマンドで止まらずに次の台詞まで流すので、
   テンプレは `Talk.fromJson` で木の JSON にゲームのコマンドの直後の `<<wait 0>>` を差し込んで止めている（木の JSON の形に寄りかかる）。
   engine の実行器に「wait 以外のコマンドの後で止まる」選べる口があれば差し込みが要らなくなる。別のゲームで同じ物が要った時に足すかを決める。
   それまでは `TestQuest.testGoldLineAfterAcceptShowsTheNewGold`（本物の dialogue.json）と `testGoldIsCopiedBeforeTheNextIf` が差し込みを守る。
7. agent-eval: P8 で `agents-pack/agent-eval/engine.json` に RPG のお題（「敵を 1 体足す」「NPC の台詞を依頼の段階で変える」）を 1〜2 本足してよいか。
   → 依頼主の決定（2026-10-29）: 足さない。

## 12. 危険（重くなる所・壊れやすい所）

- **型の推論の破綻**: 戦いの 1 手を 1 つの関数に詰めると `Expected X, Got X` が出る。段階（Opening / Choose / Run…）ごとに関数を分け、`match` を入れ子にしない。
- **World の型の大きさ**: FieldRec・BattleRec・Battle.Rec・Beat・Party・Bag・Progress・SaveData は 1 case の enum で包む。`bin/fge record-wrap` を毎フェーズ回す。
- **毎フレームの描き物の数**: ワールドマップを全部動く側で描くと 1500 を超える。地面はタイル層、動く側は見えているマスだけ（P4 の条件）。
- **毎フレームの Doc の引き直し**: マップの格子を毎フレーム `List[String]` から引かない。Res を作る時に `Vector[Vector[Char]]` と通れるかの表へ作り直して持つ。
- **Yarn と World の二重の正**: World → Yarn の一方向・コマンドごとに写し直す・`<<set>>` を TestDocs で止める（4.2）。
- **乱数の決まり**: Dice 以外の乱数を `forbid.local.json` で止める。
- **描き出しの絵が今の gallery とずれる**: 格子を Doc に移す時の写し間違い。P1・P4 で旧 `FieldScenes` の絵と Starts の絵を並べて見比べる。
- **曲づくりの手間**: 6 本の作曲を台本で書くのは重い。P8 を 2 回に割ってよい（効果音と mixer → 曲）。
- **bot が遅い・すぐ詰む**: 54000 フレームを 1 フレームずつ App に流すので、1 本 1 分を超えるかもしれない。超えたら BOT_RUNS を並列にする（1 本の中のフレームはまとめない）。詰みの判定が厳しすぎて誤って止まる時は、レポートの World の指紋で原因を見てから緩める。
- **bot の方針がゲームに寄りかかる**: goalOf の表が依頼の段階の並びを写すので、流れを変えたら表も直す。bot が通ることは「人が通れる」の証明ではない（会話の分かれ道で「いいえ」を選ぶ道は e2e の側で見る）。
- **色違いのアトラスの数**: 色違い 1 体ごとにテクスチャが 1 枚増える。5 枚で止め、5 枚を超える時は Res の作り直しの重さを測ってから。
