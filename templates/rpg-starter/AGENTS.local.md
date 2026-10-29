# このゲーム固有の設計原則

王道 RPG のテンプレート「ルーネの泉」。山あいの湖の村から依頼を受け、仲間と水晶の坑道（3 階層）へ向かい、
ボスを倒して帰ると泉がまた湧く。実装の道筋は `docs/PLAN.md`（フェーズ P1〜P8）、絵の設計は `docs/ART_BRIEF.md`。
いまはフェーズ P5.5 の後半まで（タイトル → 村を歩く・家に出入りする・村人と話す・依頼を受ける・ミナが仲間に加わる・村の外周の端の出口と gate・メニュー（どうぐ・つよさ・そうび）・道具屋・宿とセーブ・「つづきから」・ワールドマップ・ほこらのトトの杖の話 → 森の岩穴のレバーと鉄格子とほりモグ → 杖を返すとトトが加わる・坑道 B1（トロッコと分かれ目のレバー・岩の部屋 1・ボルじい）・B2（暗い迷路とたいまつ・落とし穴・行商人コロンの店・中ボスくろがねゴブリン）・B3（水晶の順番と飛び石・岩の部屋 2 とひとくいばこ・ミナの父）・ふるびたかぎの扉・出会いとコマンドバトル（たたかう / ぼうぎょ / にげる）・経験値とレベルアップ・全滅・会話の音・戦いの じゅもん / どうぐ・眠り・敵の呪文・フィールドの じゅもん（ヒール）・B3 の扉の奥のジェムイーター（逃げられない・HP 半分で phase 2）・勝つと坑道の入口へ戻されワールドマップを歩いて帰る・
泉に水が戻った村（村人が泉に集まる）・村長への報告とお礼・エンディング（スタッフの字）→ タイトル）まで、はじめからエンディングまで通して遊べる（P7 済み）。
音と仕上げは P8。規則の読み始めは `src/World.flix` の冒頭の図。

## このゲームの早見表（やりたいこと → どこを触るか）

1 行 1 文。手順の細部と理由は、右に書いた所の冒頭のコメントにある。enum の case を足す物は `case _` を書かずに全部の case を並べてあるので、
case を足して `make check` を流すと、触る所をコンパイラが並べる。仕組みを足したら、その分野にここへ 1 行足す。

### 場面とウィンドウ

| やりたいこと | 触る所 |
|---|---|
| 場面（`World.Scene` の case）を足す | `World.Scene` の case を足し、`make check` が並べる所（`InputLayer`・`Controls.interpret`・`View.frame` / `hud`）を埋め、始まりを `Starts.all` に足す |
| 場面だけが持つ値を足す | 非 pub の 1 case の enum + `pub type alias` と読む・書く関数を 1 つずつ（手本 `World.FieldState`） |
| フィールドに重ねるウィンドウを足す | `World.FieldWindow` の case と規則のファイル `src/World<名前>.flix`（手本 `WorldTalk`）を足し、閉じるのは `World.closeWindow` だけを通す |
| メニューの項目・ページを足す | `World.MenuPage` の case を足し、`make check` が並べる所（`WorldMenu`・`ViewMenu.menuOf`）を埋める |
| メニューの じゅもん | `MenuPage.SpellWho → Spells → SpellTarget`（`WorldMenu.confirmCaster` / `confirmSpell` / `castOn`。並びは `Party.spellsOf`） |
| メニューや店の知らせを足す | `TextDoc.NoticeText` の case と `rpg.text.json` の `notice` に足し、`WorldMenu.notice` で出す |
| 店を足す（2 つ目の店） | `rpg.shops.json` の goods の行に `shop` の名前を書き、会話で `<<shop 名前>>`（`WorldShop.goodsOf` が名前で品を引く。空は村の道具屋） |
| 会話から別のウィンドウを開く（`<<shop>>` の形） | `WorldTalk.applyCommand` の枝で `Flow.Handed` を返し、会話をそのウィンドウの payload に持たせる |
| 暗転の間に World を変える（宿の形） | `World.TransitionThen` の case を足し、`make check` が並べる所（`WorldTransition.secondsOf` / `transitionDone`・`ViewField.transitionProgress`）を埋める |
| 重なり順（層）を足す | `src/ZOrder.flix` の `Layer` / `HudLayer` に case と `zRange` を足す |
| エンディング（`World.Scene.Ending`） | 会話の `<<ending>>` → 暗転（`TransitionThen.Ending`・覆う方は `rules.innSeconds`）→ `World.enterEnding`（今のフィールドを下敷きに持つ）。絵は下敷きを `FieldScreen` で・字は `EndingView`（`View.endingIn` が組む）。スタッフの字は `rpg.text.json` の `credits`（`{lv}`・`{gold}`）・流れる秒は `rules.creditSeconds`・流れ切った後の決定でタイトルへ（`WorldTitle.confirmEnding` → `World.toTitle`。セーブは書かない） |
| 場面が終わった後にフィールドを絵の下敷きにする | 場面の payload に `FieldState` を持ち、`World.shownFieldOf` の枝に足す（`ViewField.fieldIn`・カメラ・タイル層はここを読む。歩きの規則は `fieldRecOf` のままなので動かない） |

### マップと物

| やりたいこと | 触る所 |
|---|---|
| マップを足す | `assets/maps/<名前>.map.json` を作り、`MapDoc.names` と入る側の `exits` に 1 行ずつ足す |
| 地図の文字・タイルの組を足す | `src/Tileset.flix`（`TilesetId` の case と通れるか・絵）と `map.schema.json` の `tileset` に足す |
| 村人と会話を足す | マップ Doc の `npcs` に 1 行足し、`assets/talk/rune.yarn` にノードを書いて `make talk-vocab` |
| 着くと会話を開くマス | マップ Doc の `events` に 1 行足す（判定は `WorldField.arrive`） |
| 階段・マップの間をつなぐ | 段の文字のマスに `exits` を 1 行足し、行き先のマップにも戻りの 1 行を足す |
| マップの端から外へ出る出口 | `exits` の行に `edge`（`all` か辺の向き）を書き、x / y は書かない（判定は `MapDoc.edgeExitOf`・`WorldField.stepFrom`。端のマスへ着いただけでは移らず、外へ押した時に移る） |
| 歩いては通らない出口（会話で移す） | `exits` の行に `edge` = `none`（x / y は書かない）と `id`。会話の `<<warp 出口の id>>` が今のマップのその行の行き先へ暗転で移す（門は見ない。`WorldTalk.warp`。どのマップにも無い id は `Talk.problemsOf` が言う。手本は B3 の `to_surface`） |
| 出口を仲間が加わるまで閉じる | マップ Doc の `exits` の行に `gate` と `gateNode` を書く（判定は `WorldField.closedGateOf`。端の出口も同じ） |
| マスにある物（宝箱・扉）を置く | マップ Doc の `objects` に 1 行足す（JSON は平ら。読む時に `MapDoc.objectKindOf` が種類の値を組む） |
| 物の種類（`kind`）を足す | `MapDoc.ObjectKind` に case（その種類だけの値は payload）と `objectKindOf` に 1 行を足し、`make check` が並べる所（`WorldObject` の `stateOf`・`examine`・`onArrive`・`onPush`・`MapDoc.defaultSpriteOf` / `raisedFlagOf` / `readFlagOf` / `guardNodeOf`・`FieldScreen.thingBoxOf`（大きさ・仮の色・絵の選び方 `Look`）・`Res.kindProblemsOf`）を埋め、`map.schema.json` の `kind` の enum と欄に足し、テストは「調べると旗が変わる」「旗で通れるかが変わる」の 2 本（手本 `TestWorldMap` の森の岩穴の節・`TestMine`） |
| 仕掛け（レバーと開く物） | `objects` に `lever`（壁のマス・`flag`）と `gate`（床のマス・同じ `flag`・`openWhen` = on / off・絵は `sprite`）を 1 行ずつ（つながるのは同じ旗の名前。立てる物の無い gate は `Res.flagProblemsOf` が言う） |
| 固定の戦い（番をする者） | `objects` に `guard`（`node`・`sprite` は人の絵か敵の絵か化けた宝箱の絵）を 1 行、`rune.yarn` の `node` に `<<fight 敵 勝ちのノード>>`、勝ちのノードに `<<open id>>`（消える）と `<<give>>` / `<<gold>>`（手本 `CaveMole` / `StaffBack`。この敵だけの枝をコードに書かない） |
| 物の状態（塞ぐか・どの絵か） | `WorldObject.stateOf`（種類・開けたか・旗から `ObjectState` を導く）の 1 か所で決め、`blocks` と `FieldScreen.thingPart` はその状態だけを読む |
| 物が立てて別の物が読む旗 | 旗の名前は `Flag.FlagId`（作るのは読む所の `Flag.fromJson` と Starts の `flags=` だけ）、立てる・読むのは `Progress.withFlag` / `isFlagSet`（開けた物は `Progress.Rec.opened` で別。セーブに入る） |
| 旗を読む物（gate の類）を足す | `Res.problemsOf` に「読むだけで、立てる物がどこにも無い旗」の検査を足す（書き損じた旗で扉が黙って開かなくなるのを起動時に言う） |
| 物の今のマス（動く物） | `WorldObject.objectsNow` の 1 か所で Doc の位置を今の位置へ替える（当たり・調べる・絵はここだけを読む） |
| 床に敷く物（踏める物）を足す | `WorldObject.blocks` の枝で塞がない種類にし、`FieldScreen.thingBoxOf` の `flat = true`（Over の層に描く。岩が上に載る）。1 マスに物が 2 つ並ぶので、当たりは `WorldField.Occupancy` のマスごとの並び（塞ぐ物が先）を読む |
| 押せる岩（rock） | `objects` に `rock`。押すのは `WorldObject.pushRock`（行き先は `rockCanEnter`: 歩ける床・人も出入口も会話のマスも無く、物は床のスイッチだけ）。今のマスは `FieldRec#rocks`（`World.arriveAt` で空に戻る = マップを出ると元の位置。セーブに書かない） |
| 床のスイッチ（plate） | `objects` に `plate`（`flag`・`hold`）。`hold = false` は着いた時（`onArrive`）・`true` は岩が動いた時（`raiseHeldPlates`）に、同じ旗の床が全部沈んでいれば旗を立てる（立てたまま） |
| トロッコと分かれ目（cart・junction） | `objects` に `cart`（`dir`・`node` の会話に `<<ride>>`）と、レールの分かれ目のマスに `junction`（`flag`・`dir`・`dirOn`）。道は `Rail.pathOf`（乗った時に 1 回）、走るのは `Stride.Boarding → Riding`（`WorldField.board` / `rideTick`。入力は Busy・出会いも明かりも数えない）。レールの文字（= \|）は歩けない。曲がり角の絵は隣のレールから（`Autotile.Cell.Joined`） |
| 水晶の順番（crystal） | `objects` に `crystal`（`flag`・`order`）。点けた水晶は `Progress.Rec.opened`、全部点くと `flag`（`WorldObject.touchCrystal`。違う順は同じ旗の水晶を全部消す） |
| 旗で現れる床（bridge・飛び石） | `objects` に `bridge`（`flag`）。旗が立つと描かれ、水のマスでも立てる（`WorldObject.floors` を `WorldField.canEnter` が読む） |
| 読む物（sign・石碑） | `objects` に `sign`（`node`）。調べると会話（番をする者と違い、消えない） |
| 暗いマップ・たいまつ | マップ Doc の `dark`、見える広さは `rules.darkRadius / torchRadius`、たいまつは items の `lightSteps`（`WorldMenu.lightTorch`・残りは `FieldRec#light`。墨は `FieldScreen.darkness` が `ZOrder.Layer.Dark` に） |
| 落とし穴 | 床の文字のマスに `exits` を 1 行（行き先は別の部屋）と、絵は `props` の `floor_crack`（flat）。bot は目的でない出入口を踏まない |
| マップごとの出会いの歩数 | マップ Doc の `minSteps / maxSteps`（両方書く。無ければ rules。`WorldField.drawSteps`） |
| 出会いの組・歩数 | マップ Doc の `encounter` と `rules.minSteps / maxSteps`（マップの `minSteps / maxSteps` が先。数えるのは `WorldField.countStep`） |
| 地図の 1 マス幅の縁を避ける | 森（`&`）・水（`~`）はどこも 2 マス幅以上にする |

### 会話と進み具合

| やりたいこと | 触る所 |
|---|---|
| 話し手の呼び名を足す | `assets/rpg.text.json` の `speakers` に 1 行足して `make talk-vocab` |
| 台詞の長さ | 1 行の台詞はウィンドウ 1 枚・4 行まで（超えると `TestDocs.testEveryLineFitsTheTalkWindow` が止める） |
| 会話のコマンド（`<<名前 引数>>`）を足す | `Talk.Command` の case と `Talk.commandNames` / `commandOf` に足し、`WorldTalk.applyCommand` を埋めて `make talk-vocab` |
| 会話が読む World の値（`$quest` の類）を足す | `Talk.SyncedVar` の case と `Talk.syncedVars` / `varNameOf` に足し、`WorldTalk.valueOf` と `rune.yarn` の `<<declare>>` を埋める |
| 会話で別のマップへ移す・エンディングへ | `<<warp 出口の id>>`（歩いては通らない出口は `edge` = `none`）・`<<ending>>`（どちらも会話を閉じて暗転） |
| 会話で全快・トロッコ | `<<heal>>`（仲間全員の HP と MP を最大へ。手本 `MinaFather`）・`<<ride>>`（前のトロッコに乗る。手本 `Cart`） |
| 会話で持ち物を見る・返す | だいじなもの（items の `kind` = key）は `$has_<鍵>` で読める（`rune.yarn` に `<<declare $has_<鍵> = false>>`）。返すのは `<<take 鍵 個数>>`（手本 `Shrine`） |
| 会話の音（文字送り・開く・送る） | 話し手の声の高さは `rpg.text.json` の `speakers` の `voice`（low / mid / high）。鳴らす所は `Controls.talkSoundsOf`（前後の World の見比べ）、素材は `art/sfx.snd.star` の `talk_*` |
| 依頼の段階を足す | `Quest.Quest` の case と `Quest.all` / `Quest.nameOf` に足し、`WorldTalk.payOf`・`Talk.questVerbTable`・`map.schema.json` の `questFrom` / `questUntil` の enum を埋める |
| 依頼の段階で村の人・小物を替える | マップ Doc の `npcs` / `props` の行に `questFrom` / `questUntil`（段階の名前。両端を含む。同じマスに段階の違う人を並べてよい。判定は `MapDoc.isShownIn`・立つ人は `MapDoc.standingAt`。手本は村の泉 `spring_dry` / `spring_full` と `chief_spring`） |
| 段階を進めてお金を払う | 会話の `<<quest accept / defeat / report>>`（払う額は `WorldTalk.payOf`。お礼は `rules.reward`・台詞では `{$reward}`） |
| 仲間を足す | `Member.Member` の case と `Member.all` / `idOf` に足し、`PartyDoc.memberDefaultOf`・`rpg.party.json`・装備できる道具の真偽・`map.schema.json` の `gate` と `party.schema.json` の `learns` の `member` を埋める |
| セーブに欄を足す | `Saves.Rec` と `toJson` / `fromJson`（`version` を上げる）・`World.saveDataOf`・`WorldTitle.confirm` に足す（往復は `TestShop` のテスト） |

### 道具と店

| やりたいこと | 触る所 |
|---|---|
| 道具を足す | `assets/rpg.items.json` の `items` に 1 行足す（フィールドで使えるのは heal か mpHeal のある use だけ） |
| 店の品・宿代を替える | `assets/rpg.shops.json`（値段は `rpg.items.json` の `price` の 1 か所） |
| 仲間の数（HP・ちから…）を足す | `PartyDoc.Member` と `memberDefaultOf`・`party.schema.json`・`rpg.party.json` に足す（最大の値は `Party.maxHpOf` などが導く） |

### 戦い

| やりたいこと | 触る所 |
|---|---|
| 敵を足す | `assets/rpg.foes.json` に 1 行、技は `rpg.foe_moves.json`、組はマップの `encounter` に足す（数は `make balance` の ⚠ を見て Doc で直す） |
| 色違いの敵を足す | `assets/rpg.recolors.json` に 1 行足し、敵の行の `recolor` に書く |
| 敵の技（act）を足す | `FoeMovesDoc.Act` の case と `actOf` / `actNames` に足し、`Battle.foeTurn` と `foe_moves.schema.json` を埋める |
| 戦いのコマンドを足す | `World.BattleCommand` の case を足し、`make check` が並べる所（`WorldBattle.isCommandOpen` / `confirmCommand`・`ViewBattle.battleCommandTextOf`）と `Battle.Plan` を埋める |
| 戦いの伝言を足す・替える | `TextDoc.BattleText` の case と `rpg.text.json` の `battle` に足し、埋める値は `TextDoc.Placeholder` で渡す |
| 戦いの演出を足す | `Battle.FxKind` の case を足して `ViewBattle.fxSpriteOf`（絵の名前）を埋める（置き場は的で決まる `ViewBattle.fxIn`）（長さは `rules.fxSeconds`） |
| 呪文を足す | `assets/rpg.spells.json` に 1 行（`aim` = foe / allFoes / ally・`fx` は battlefx の絵）と、覚える人と Lv を `rpg.party.json` の `learns` に 1 行（コードは触らない。式は `Battle.castBy`） |
| フィールドで唱えられる呪文 | spells の行の `field = true`（唱えられるのは `aim = ally` の回復だけ。`WorldMenu.confirmSpell`） |
| 敵に呪文・眠りを持たせる | `rpg.foe_moves.json` の行に `act = spell` と `spell`（呪文の鍵）、か `act = sleep`（率は `rules.sleepRate`・起きる率は `wakeRate`） |
| 戦いで使える道具 | `rpg.items.json` の use の行に `heal` / `mpHeal`（仲間 1 人）か `burn`（敵 1 体）。どれも無い use の物は戦いの一覧で灰色（`Battle.isBattleItem`） |
| 戦いのコマンドのページを足す | `World.CommandPage` の case を足し、`make check` が並べる所（`WorldBattle.pageLengthOf` / `withCursor` / `cursorOf` / `parentOf` / `confirm`・`ViewBattle.sideOf`・`Bot.wantedRowOf`・`E2e.commandPageOf`）を埋める |
| 戦いの間の仲間とふくろ | `Battle.Rec` の `party` と `bag` が正（World へは `WorldBattle.leave` が勝ち・逃げ・全滅のどれでも書き戻す） |
| ボス（逃げられない固定の戦い・HP で技を替える） | マップの `objects` に `guard`（`sprite` は敵の絵。大きい絵は下端の中央をマスに合わせて上と左右に重なる）と会話の `<<fight 敵 勝ちのノード>>`、敵の行に `noFlee` と `phase2At`（割合）、技は `rpg.foe_moves.json` の `phase` 2 の行（HP が切った手番の後のターンから。`Battle.foeActsOf`）。勝ちのノードで `<<open id>>`・`<<quest defeat>>`・`<<warp>>`（手本 `Boss` / `BossWon`。数は `make balance` のボスの区間 `BalanceSim.bossAt`） |
| 勝った後の経験値・レベルアップ | 式は `Battle.resolveVictory`（全滅の 1 枚は `Battle.wipedBeat`）。表と伸びは `rpg.party.json` の `exp` と `hpUp…agiUp` |

### 入力・Doc・乱数

| やりたいこと | 触る所 |
|---|---|
| キーを足す・替える | `assets/rpg.keys.json` と `KeysDoc.Rec`（コードに `Key.Z` と書かない。方向は `KeysDoc.dirKeys`） |
| Doc に欄を足す | `bin/fge refactor add-field` で型と既定に足し、`fromRoot` で読み、JSON とスキーマと `TestDocs` を足す（手本 `rules.fxSeconds`） |
| Doc のファイルを足す | `src/<名前>Doc.flix`（手本 `RulesDoc`）と `Res` の束・`Controls.docTable`・`project.json` の `editor.resources` に足す |
| 規則の出来事に音を付ける | `World.Event` の case を足し、`Controls.soundOf` と `project.json` の `sounds` を埋める（素材は `art/sfx.snd.star` に足して `bin/fge snd build art/sfx.snd.star` → `atelier/sfx` から `assets/sfx` へ） |
| 乱数を引く | `Dice.roll(Dice.Channel.<用途>, w)`（用途は `Dice.Channel` の case と `numberOf` に足す） |

### 確かめる

| やりたいこと | 触る所 |
|---|---|
| テストを書く | 場面は `Fixtures.started`、キーは `Fixtures.play`（中身は実機と同じ道の `Drive.play`）、期待値は Doc から（書く前に `/quality-assurance`） |
| 戦いをテストする | 式は `Battle.resolveRound` / `resolveVictory` を直に、画面は `Fixtures.started("battle", …)` + `Fixtures.confirmEach` |
| 会話のコマンドをテストする | `Fixtures.openTree(Fixtures.command(…) + "," + Fixtures.line(…), h)` で 1 ノードの会話を開く |
| 始まりの場面を足す | `Starts.all` に 1 行足す（`make run`・flow・テスト・描き出しが同じ表を引く） |
| 仕掛けの途中から始める | Starts の field に `flags=`（旗）・`opened=`（立つマップの開けた物・点けた水晶）・`rocks=id:x:y`（動かした岩）・`light=`（たいまつの残り） |
| e2e を足す | `e2e/<名前>.flow` を書いて `make flow FLOW=e2e/<名前>.flow`（戦いの問いは `foes`・`mp`（仲間の MP の合計）・`page`（コマンドのページ）。手本 `e2e/battle_magic.flow`） |
| 描き出す場面を足す | `SceneRender.shotNames` / `worldOf` と Makefile の `SHOTS` に足す（場面を進めるのは `Drive.play` でキーを流す） |
| テストプレイ（bot・つり合い） | `make bot`（`Bot.goalOf` の表）・`make balance`（`BalanceSim.sectionTable`。区間のふくろも書く）。戦いの方針は `Bot.battlePlans` の 1 か所（BalanceSim も同じ物を回す）。流れを変えたら `Bot.goalOf` も直す。岩の部屋は押す手を `Bot.rockPlanOf` に、トロッコとレバーは歩いて着けない時に `Bot.detourOf` が自分で選ぶ。1 周の人の目安はレポートの「人の目安」（歩き + 戦い × 33 秒 + ウィンドウ × 3 秒） |
| 描き出しの場面の作り方 | どの場面も `SceneRender.worldOf` で Starts から組んで決まった手（`Drive.play`・`confirmTimes`・`playSeconds`）を進めた World を、実機と同じ `View.frame` / `hud` で描く（直に組んだ絵の場面は無い） |
| 通しの手を流し直す | `make bot` の 1 本目が `debug/bot/playthrough.flow` を書く（区間の頭ごとに `mark` と `expect`）。`make flow FLOW=debug/bot/playthrough.flow` でタイトルからエンディングまで同じ指紋で流れる（bot の 1 フレームはナノ秒に丸めた 1/60 秒 = `BotRun.dt`） |
| 古い書き方を止める | 1 行の正規表現は `bin/lint-rules/forbid.local.json`、型と呼び出しの向きは `lint/rules.flix`（`make lint-flixlint`） |

## この画面の画風

<!-- 人の注文（style-interview 2026-10-28 で聞き取り。以下は制約 — 満たし方は engine の docs/art-ref/visual-dict.md で決める） -->
- 視点: 見下ろし（村・ワールドマップ・ダンジョン）＋ 正面の戦闘
- スタイル: 粗いピクセルアート
- パレット: FC 実機風の限定パレット
- 輪郭: くっきり黒縁
- トーン: ビビッド
- ポストエフェクト: かけない

- 題材: 山あいの湖の村と、水晶の坑道。色 3 つ: 草の緑 / 主人公の青いマント / 灯りの橙。
- やらないこと: なめらかなグラデーションを使わない（階調は FC の色の段とディザだけ）。
- 色の予算: 極小 — 256×240 / 背景 1 タイル = 墨 + 3 色 / スプライト = 3 色 + 透明 / 画面 25 色前後 / 広い動かない面はディザ
- 色の実体は `assets/rpg.palette.json`（FC の 54 色。黒だけ墨 `ink` に置き換え）。色を足さない。
