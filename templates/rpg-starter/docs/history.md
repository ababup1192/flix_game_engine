# 作った道筋の記録 — ルーネの泉

**作った時の記録。写す時は読まなくてよい。**

読み手: このテンプレートが今の形になった順番と理由を知りたい人。今の設計は `docs/DESIGN.md`、つり合いの最終の数は `docs/balance.md`。
ここは記録なので、書いた時の名前・数のまま残す（今のコードとずれていてよい）。文中の「N 節」「5.4」は、設計を書いていた計画書（今の `docs/DESIGN.md`）の当時の番号。

1. フェーズ（P1〜P8）
2. 絵の段階の描き出しコードの育て方
3. 早見表の作り方
4. P5 の `make balance` で直した数
5. 依頼主のテストプレイ 1 回目（2026-10-28・P4 まで）

## 1. フェーズ

**P7 の終わりに遊べた物**: タイトル → 村を歩く・家に出入りする・村人と話す・依頼を受ける・ミナが仲間に加わる・村の外周の端の出口と gate・
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
| P8 | 最終の数（区間ごとの戦う数・Lv・時間）を 5.4 の表と並べて README へ | 最終の表を `docs/balance.md` に写す（debug/ は git 管理外） | 作って撮る。依頼主へ渡す |

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
  - bot（`Bot.goalOf`）はトトの前に「岩穴のレバー → ほりモグ → トトに話す」の 3 行。~~`Aim.Open`~~ は `Aim.Examine`（物を調べる。宝箱・レバー・番をする者）に、端の出口へは端のマスで外へ押す（`BotRoute.Arrive.Push`）。
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
  - **bot** の戦いの方針（`BotBattle.battlePlans`）: HP 35% 未満の仲間（このターンにまだ誰も回復しない人）を回復の呪文 → HP の戻る道具で回復。逃げられない組では回復の呪文の MP を残して攻めの呪文（敵 2 体以上なら敵全部の呪文）→ たたかう の 2 倍より強い burn の道具。ほかは HP の一番少ない敵を たたかう。
    フィールドでは HP 60% 未満の人に回復の呪文（`Goal.Cast`）→ やくそう。コマンドのページは `BotBattle.wantedRowOf` が方針の行動へ向けて送る。ばくだんいしは攻めの弱い人（トト）だけが投げるので、ボス（P7）まで残る。
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
    x / y の書き忘れを「通らない出口」と読まないよう、`none` は書かせる。bot のマップの間の道はこの出口を通らない（`BotRoute.isWalkable`）。
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
- 作った（P8 中ごろ）: つり合い・長さ・クレジット（下の「P8 で決めた事」）。
- 作った（P8 後半・テンプレとしての出荷）: `make video`（`VideoRender` と `e2e/video.flow`。bot の通しの手（数千行・種で変わる）は使わず、
  Starts から区間ごとに始め直す手を e2e に書いて `mark in_ / out_` の間だけ撮る。約 80 秒）・`reference/SHA256SUMS.txt` と `ITEMS.tsv`・
  `/add-template` の 7 手順・`AGENTS.local.md` の早見表の見直し・README・この計画書を `docs/DESIGN.md`（設計）と `docs/history.md`（この記録）に分けた。
  依頼主の指摘で、杖の番人を ほりモグ → おやぶんモグ（色違い brown）に替え、くろがねゴブリンとひとくいばこを強くした（固定の戦いの目安は受けるダメージ 40〜80%）。
- 完了の条件: `/add-template` のチェックリストが全部埋まる。`make reference-check` が緑。音の下限を満たす。`debug/video/rune.mp4` を依頼主が見られる。`make bot BOT_RUNS=10` が緑のまま。
- テスト（`TestSounds`・済み）: 出来事 → 音の名前の表 / project.json の sounds に全部ある（出来事・呪文の fx・曲）/ 階段は扉と別の音 / 曲の宣言はマップの bgm に従い（どのマップにも曲がある）、戦いの間は戦いの曲・逃げられない敵はボスの曲・勝ちの伝言の間は止めてからマップの曲へ戻る。
- P8 で決めた事（つり合い・長さ・クレジット。数の全部は `docs/balance.md`）:
  - **ボス**: ジェムイーター HP 360 → 560・ちから 41 → 40、技の重みを phase 1 = attack 1・sweep 1 / phase 2 = attack 3・sweep 1 に（後半は 1 人を狙う）。
    bot の着く Lv 7 で勝率 84%・12 ターン（9 割 14）・全滅 16%、たたかうだけでは 1%。Lv 8 は 99%・10 ターン、Lv 6 は 37%。
    目安は「bot の着く Lv で 10〜14 ターン・70〜85%・たたかうだけ 40% 以下」（`BalanceSim.bossLv` = 7。前後の Lv は見比べるだけ）。
  - **ボスでの全滅は設計の内**: 勝率 70〜85% のボスに bot が同じ方針で挑むので、10 本に 1〜3 本はボスで全滅して宿から挑み直す（P8 の数では種 0・5 の 2 本）。
    `make bot` の全滅の欄はボス戦を `boss` と書き分ける（`BotRun.observe`）。雑魚戦と道中の全滅は 0 のまま。
  - **長さ**: 人の目安（+ 仕掛けを考える 3.1 分）は 10 本とも 20 分台（20:33〜27:03。全滅の無い本は 20:33〜23:06）。伸ばしたのは出会いの歩数だけ（rules 12..20 → 7..11 = ワールドマップ・B1 30..44 → 26..38）。
    坑道コウモリ HP 22 → 26・ちから 12 → 14（B2 で 1 発で倒れていた）。
  - **クレジット**: `rpg.text.json` の `credits` を 後日談（泉・ミナの父・ミナ・トト・ルカ）→ ぼうけんの きろく → スタッフ（きかく・プログラム・ドットえ・おんがく = 「Flix Game Engine」「rpg-starter」と使った道具）の 49 行に。
    流れ切ると `menu` の `theEnd`（おわり）。写した人が名前を替える所は `rpg.text.json` の note に書いた。`rules.creditSeconds` 24 → 42 秒（行が増えた分）。
  - **bot を 3 つに分けた**: `Bot`（道筋の表とキー）・`BotRoute`（道の計算）・`BotBattle`（戦いの方針と、見比べの `attackOnlyPlans`）。
  - **テスト**: `TestMine.testFloorPlateActsOnArrive` / `testRockActsOnPush`（`MapDoc.profileOf` の steps / pushable が真の種類ごとに、onArrive / onPush が Some を返す場面を 1 本ずつ）。


## 2. 絵の段階の描き出しコードの育て方

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


## 3. 早見表に書く事（AGENTS.local.md。P1 の後に作った。フェーズごとに足した仕組みの行を 1 行ずつ足す）

場面の表（場面・payload・入る関数・View・Starts の名前）と、「この変更 → このファイル」の表（敵を足す → foes.json・foe_moves.json・マップの encounter / 色違いを足す → recolors.json と foes の recolor / 呪文を足す → spells.json と Battle の act / マップを足す → maps/*.map.json と exits / 会話を足す → rune.yarn と npcs の node / コマンドを足す → Talk.Command と WorldTalk の枝）。internet_dungeon の `internet_dungeon/docs/world-map.md` 4 節の形。


## 4. P5 の `make balance` で直した数

直した数（PLAN 5.3 の表は直した後の値）: くさウサ HP 12→16（ルカ Lv1 の 1 発で倒れた）・はなウサ ちから 13→11・
坑道コウモリ ちから 14→12・ひのこコウモリ ちから 18→17・こおりヤドカリ まもり 26→22（4 発かかった）・あかぼうしゴブリン HP 56→50・ちから 25→20。
出会いの組も 3 つ軽くした（3 体の組の受けるダメージが 40〜50%）: ワールドの はなウサ・くさウサ・くさウサ → はなウサ・くさウサ、
B1 の 坑道コウモリ×2・コケだま → 坑道コウモリ・コケだま×2、B3 の あかぼうし・つるはし×2 → あかぼうし・つるはし。

## 5. 依頼主のテストプレイ 1 回目（2026-10-28・P4 まで）

依頼主が `make run` で遊んで出した指摘と、どう片付けるか。P5 の後のフィードバック対応で、コードの直しはまとめて入れる。

| # | 指摘 | 片付け方 | 担当 |
|---|---|---|---|
| 1 | 会話時に効果音がなくて寂しい | 文字送りの音（1〜2 字ごとの短い音・話し手で高さを変える）と、送り・ウィンドウを開く音。`docs/audio.md` | 実装（P5.5 前半で済み） |
| 2 | ミナの顔が傾いている | ハンマーに替えた時に頭を 1 列寄せた崩れ。顔を体の中心線に戻す | 絵（済み） |
| 3 | トトが唐突に仲間になる。条件やストーリー性が欲しい | 案を `docs/proposals/toto-and-mine.md` に出して依頼主が選ぶ（T1「なくした杖」に決定） | 実装（P5.5 前半で済み） |
| 4 | トトだけ移動がカクカクする | 隊列の trail が 2 マスしか無く、3 人目が 1 つ古いマスから跳ぶ（P2 で弱点として挙げていた物）。3 人目もなめらかに追う | 実装（P5.5 前半で済み） |
| 5 | 街の出口が分かりづらい。端に行ったら出られるように | 村の外周の端のマス全部を出口にする（PLAN の exits の edge の欄）。出口の見た目も道で示す | 実装（P5.5 前半で済み） |
| 6 | 装備画面で文字が被っている | そうびのページの行の重なりを直し、描き出しで確かめる | 実装（P5.5 前半で済み） |
| 7 | まりょくのみが使えない | フィールドのどうぐで MP を戻せるように（P3 で HP だけ見ていた所） | 実装（P5.5 前半で済み） |
| 8 | ダンジョンが迷路になっていなくて短くてつまらない | 案 B（`docs/proposals/toto-and-mine.md` 改訂 2）で坑道 3 枚を作り直した（B1 32×30・B2 48×30 の暗い迷路・B3 32×30。行き止まりに宝・帰りの近道） | 実装（P5.5 後半で済み） |
| 9 | 宝箱の開閉（空っぽの状態）が分かりづらい | chest / chest_open の絵を描き直す | 絵（済み） |
| 10 | ダンジョンに仕掛けもなく、手に入る物もしょぼい | 階ごとの仕掛け（トロッコと分かれ目・岩と床のスイッチ・暗さとたいまつ・落とし穴・水晶と飛び石）・中ボスとひとくいばこ・宝の表（てつのつるはし・はがねのつるぎ・みずのはごろも・ばくだんいし ほか） | 実装（P5.5 後半で済み） |
