// World — ゲームの状態の形と、どの規則も使う小さな口（すべて純粋）。
// 規則は仕組みごとのファイルに分けてある（どれも World を使い、World はそれらを呼ばない）:
//   WorldField … マップを歩く（当たり・出入口・イベントのマス・出会いの歩数）・話しかける。マスにある物は見つけて WorldObject へ渡す
//   WorldObject … マスにある物（宝箱・扉…）の規則を種類ごとに（塞ぐか・調べる・着く・押す）。物の今は objectsNow の 1 か所
//   WorldTransition … 暗転を時間で進め、覆い切った時に World を変える（行き先へ移る・宿で全快とセーブ・戦いへ）
//   WorldTalk  … 会話のウィンドウ（文字送り・選択肢・コマンドで World を変える・World の値を会話の変数へ写す）
//   WorldMenu  … フィールドのメニュー（どうぐ・つよさ・そうび・はなす・しらべる）と、その知らせ（Notice）
//   WorldShop  … 道具屋（かう / うる → 品 → 個数 → 確かめ）と宿（泊まる → 全快 → セーブ）・宿の前
//   WorldBattle … 戦いの見せ方（コマンドを選ぶ・1 ターンの Beat を遊びの時計で 1 枚ずつ見せる・勝ち / 全滅 / 逃げ切りでフィールドへ）
//   Battle     … 戦いの式（1 ターンを解く resolveRound・ダメージ・行動順・にげる・勝った後の経験値とレベルアップ。時計を見ない）
//   Party / Bag / Progress … 仲間の加わった順と今の値・ふくろとお金・依頼の段階と旗（それぞれ 1 case の enum で包んだ値と、変える関数）
//   Saves      … セーブの中身（仲間・ふくろ・進み具合・乱数の回数）と読み書き
//   Dice       … 乱数（引いた回数 dice から引く）
//
// ── 状態の形: 「その場面でしか触れない値は、その場面の enum の中に持つ」──
//   scene … Title(カーソルの項目) / Field(FieldState = いるマップ・先頭のマス・向き・歩きの途中・開いたウィンドウ・暗転) /
//           Battle(BattleState = 戦いの値・コマンドのページか見せている Beat・戻る先の FieldState・選んだ行動・勝った後の会話) /
//           Ending(EndingState = 入った時刻・下敷きに描くフィールド)
//   残りの欄は場面をまたぐ物だけ: 仲間・ふくろ・進み具合・乱数の回数・遊びの時計・実時間・終了の確認・出来事・セーブ。
//
//     Title ──はじめから──▶ Field（rules の始まりのマス。暗転を晴らして入る）
//     Title ──つづきから──▶ Field（save の中身で仲間・ふくろ・進み具合・乱数を置き換え、宿の前 = rules の home に立つ）
//     Field ──出入口のマスに着く──▶ 暗転（TransitionThen.Warp）──▶ 行き先のマップの Field ──▶ 暗転を晴らす（TransitionThen.FadeIn）
//       暗転の間は歩きを進めない（Controls.tick が WorldTransition か WorldField のどちらか一方を流す）。
//     Field の上に開くウィンドウ（FieldWindow）: Closed ⇄ Talk（会話）/ Menu（取消のキー）⇄ Notice（メニューの知らせ）/
//       Talk ──<<shop>>──▶ Shop（閉じると同じ会話の続きへ戻る）/ Talk ──<<inn>>──▶ 暗転（TransitionThen.InnRest）の間は会話を止め、
//       覆い切ったら全快してセーブ（save と saveRev）を書き、晴れたら会話の続きへ。
//     party・bag・progress を変えるのは会話のコマンド（<<quest accept>>・<<join mina>>・<<give>>・<<gold>>・<<inn>>）と、
//       メニュー（道具を使う・装備を替える）と店（かう・うる）だけ。
//     出入口の gate（その仲間が加わっていなければ通れない）は、そのマスへ進ませずに gateNode の会話を開く。
//     イベントのマス（マップの events）に着くと、そこで止まってその会話を開く（台詞の出ないノードなら何も開かない）。
//     マスにある物（マップの objects。宝箱・扉・レバー・開く物・番をする者）は決定・しらべるで WorldObject.examine が働かせる
//       （宝箱と扉とレバーは知らせ（Notice）を出し、番をする者は会話を開く）。
//       開けた物は progress の opened、物が立てて別の物が読む名前付きの旗は progress の flags。
//     Field ──出会いの組のあるマップで歩数が 0（何も無いマスに着いた時）・会話の <<fight>>──▶ 点滅（TransitionThen.StartBattle）
//       ──▶ Battle（WorldBattle.enter）──勝つ──▶ 戻る先の Field（お金と経験値・afterWin の会話）/ 逃げ切る ──▶ 戻る先の Field /
//       全滅 ──▶ 宿の前の Field（お金は goldKeep 倍・全快・暗転を晴らす）。戦いの間の仲間の正は Battle の値で、終える時に World へ書き戻す。
//     ボス: B3 の扉の奥の番をする者 ──<<fight gemeater BossWon>>──▶ 勝つと BossWon の会話（<<quest defeat>> で段階 BossDown）
//       ──<<warp to_surface>>──▶ 暗転して坑道の入口（ワールドマップ）。負ければ宿の前で、ボスは残る（挑み直せる）。
//     依頼の段階（progress の quest）でマップの人と小物が替わる（MapDoc.Span。BossDown から泉に水が戻り、村長たちが泉に集まる）。
//     Field ──村長への報告（<<quest report>> でお礼・<<ending>>）──▶ 暗転（TransitionThen.Ending）──▶ Ending（報告した村を下敷きに
//       スタッフの字が流れる）──流れ切った後の決定──▶ Title（セーブはそのまま）。
//     Esc の終了の確認（ask）はどの場面より手前。開いている間は遊びの時計が止まる。
//
// 規則のファイルどうしの横の向き（逆へは呼ばない）: WorldTitle → WorldField → WorldObject、WorldField → WorldTalk → WorldShop、
//   WorldMenu → WorldField（メニューの はなす・しらべる）、WorldTransition → WorldShop（宿の暗転を覆い切った時の全快とセーブ）・
//   WorldTransition → WorldBattle（点滅し終えたら戦う）。WorldField は店と戦いを呼ばない。
//   店を閉じて会話へ戻すのは、ウィンドウを Talk に戻すだけ（続きは WorldTalk.tick が流す）なので WorldShop は WorldTalk を呼ばない。
//
// 遷移を起こす関数の doc には [遷移: X→Y] を付けてある（探すときの目印）。
// 場面・ウィンドウ・Doc の欄を足す時に触る所の一覧は AGENTS.local.md の早見表。
//
// ── 出来事（Emit）── 規則は音を直に鳴らさない。出来事 Event を Emit.emit で出し、鳴らす音は Controls が選ぶ。
//
// 時計は 2 本（型で分けてあり、取り違えるとコンパイルが止まる）:
//   遊びの時計 play（Clock[Play]） … 歩き・暗転・文字送り。終了の確認の間は止まる（paceOf）。進めるのは App だけ。
//   実時間 realNow（Time[Clock.Real]） … カーソルの点滅・水のゆれ・その場足踏み。止まらない。
mod World {
    use fge::{Clock, Dir4, Emit, Grid, UiTypewriter, Yarn, YarnRunner}

    /// 遊びの時計の名前。
    pub enum Play

    /// 遊びの時計を止める理由。
    pub enum Halt with Eq {
        case Asking
    }

    /// タイトルのメニューの項目。
    pub enum TitleItem with Eq, ToString {
        case NewGame
        case Continue
    }

    /// 確認のウィンドウの答え（カーソルもこれで持つ）。
    pub enum Answer with Eq, ToString {
        case Yes
        case No
    }

    /// 一番手前の確認で尋ねている事と、カーソル。
    pub enum Ask with Eq, ToString {
        case Quit(Answer)
    }

    /// 確認のカーソルがある答え。
    pub def answerOf(ask: Ask): Answer = match ask {
        case Ask.Quit(answer) => answer
    }

    /// 規則の中で起きた出来事（音の材料）。
    ///   Cursor … カーソルが動いた / Confirm … 決めた・送った / Cancel … 取り消した /
    ///   Bump … 壁へ向かって進めなかった / Door … 出入口を通った / Denied … 選べない項目（灰色）を選んだ /
    ///   TalkOpen … 会話か知らせのウィンドウが開いた / TalkNext … 台詞を出し切った・次へ送った /
    ///   TalkBlip(声) … 文字送りが 2 字ぶん進んだ（話し手の声の高さ）/ Lever … レバーを動かした /
    ///   Switch … 床のスイッチが沈んで旗が立った（踏んだ・岩で押さえ揃った）/
    ///   RockPush … 岩を押して動かした / CartRide … トロッコが走り出した / CrystalLit … 水晶を点けた / CrystalReset … 水晶が全部消えた。
    pub enum Event with Eq, ToString {
        case Cursor
        case Confirm
        case Cancel
        case Bump
        case Door
        case Denied
        case TalkOpen
        case TalkNext
        case TalkBlip(TextDoc.Voice)
        case Lever
        case Switch
        case RockPush
        case CartRide
        case CrystalLit
        case CrystalReset
    }

    /// 先頭の歩き。Walking(前にいたマス, 歩き始めた時刻)。今のマス（FieldRec#hero）へ向かって動いている。
    /// Boarding = 前のトロッコに乗ると決めた（会話の <<ride>>。次のフレームに WorldField が道を引いて走り出すか、走れなければ止まる）/
    /// Riding = トロッコで走っている（乗ったトロッコ・走る道。道は乗ったマスから降りるマスまでで、FieldRec#hero は降りるマス）。
    /// WhyNot: <<ride>> の所で道を引かない — 会話（WorldTalk）から物の今（WorldObject）を読むと、物 → 会話 → 物の輪になる。
    pub enum Stride {
        case Still
        case Walking(Grid.Cell, Clock.Time[Play])
        case Boarding
        case Riding(Ride)
    }

    /// トロッコで走っている所（ほかの歩きなら None）。
    pub def rideOf(r: FieldRec): Option[Ride] = match r#stride {
        case Stride.Riding(ride) => Some(ride)
        case _                   => None
    }

    /// トロッコに乗ると決めたか走っているか（入力を受けない）。
    pub def isRiding(r: FieldRec): Bool = match r#stride {
        case Stride.Boarding  => true
        case Stride.Riding(_) => true
        case _                => false
    }

    /// トロッコで走っている所。cart = 乗ったトロッコの objects の id（走っている間は駅に描かない）・path = 乗ったマスから降りるマスまで・
    /// startedAt = 走り出した時刻（1 マスは rules の secondsPerRail 秒）。
    pub type alias Ride = { cart = String, path = List[Grid.Cell], startedAt = Clock.Time[Play] }

    /// 暗転のあとにすること。Warp = そのマップのマスへ移って晴らす / FadeIn = 晴らすだけ /
    /// InnRest = 宿に泊まる（覆い切ったら全快してセーブを書き、晴らす。開いている会話は晴れるまで止まる）/
    /// StartBattle = 点滅し終えたら戦う（敵の並び・勝った後に開く会話のノード）/
    /// Ending = 覆い切ったらエンディングへ（会話の <<ending>>。今のフィールドを絵の下敷きに持って入る）。
    pub enum TransitionThen {
        case Warp(MapDoc.MapId, Grid.Cell, Dir4.Dir4)
        case FadeIn
        case InnRest
        case StartBattle(List[FoesDoc.FoeId], Option[String])
        case Ending
    }

    /// 暗転の途中（startedAt から片道。長さは WorldTransition.secondsOf: InnRest は rules の innSeconds・StartBattle は flashSeconds・ほかは fadeSeconds）。
    pub type alias Transition = { startedAt = Clock.Time[Play], then = TransitionThen }

    /// 会話のウィンドウの中身。line = 出している台詞、reveal = その文字送り、choices / cursor = 出している選択肢とカーソル、
    /// npc = 話しかけた人の id（その人を主人公の方へ向かせる）。
    pub type alias TalkRec = {
        runner = YarnRunner.Runner[Play],
        line = Option[Yarn.Line],
        reveal = UiTypewriter.Reveal,
        choices = List[YarnRunner.DialogueOption],
        cursor = Int32,
        npc = Option[String]
    }

    enum TalkOf(TalkRec)

    /// 会話のウィンドウ（外では wrapTalk と talkRecOf を通す）。
    pub type alias TalkState = TalkOf

    pub def wrapTalk(r: TalkRec): TalkState = TalkOf.TalkOf(r)

    pub def talkRecOf(t: TalkState): TalkRec = match t { case TalkOf.TalkOf(r) => r }

    /// フィールドのメニューのページ（カーソルの番号を持つ）。取消で戻る先は WorldMenu.parentOf の 1 か所。
    ///   Root      … はなす / じゅもん / つよさ / どうぐ / そうび / しらべる（2 列 × 3 行）
    ///   SpellWho  … 誰が唱えるか → Spells（その人の覚えた呪文）→ SpellTarget（誰に。回復の呪文）
    ///   Items     … ふくろの一覧 → ItemTarget（誰に使うか）
    ///   Status    … つよさ（左右で仲間を替える）
    ///   EquipWho  … 誰の装備か → EquipSlot（ぶき / よろい）→ EquipPick（「はずす」とふくろの中の付けられる物）
    pub enum MenuPage with Eq, ToString {
        case Root(Int32)
        case SpellWho(Int32)
        case Spells(Member.Member, Int32)
        case SpellTarget(Member.Member, SpellsDoc.SpellId, Int32)
        case Items(Int32)
        case ItemTarget(ItemsDoc.ItemId, Int32)
        case Status(Member.Member)
        case EquipWho(Int32)
        case EquipSlot(Member.Member, Int32)
        case EquipPick(Member.Member, Party.Slot, Int32)
    }

    /// 店で かう か うる か。
    pub enum ShopMode with Eq, ToString {
        case Buy
        case Sell
    }

    /// 店のページ。Top = かう / うる / やめる・Goods = 品の一覧・Count = 個数（1 から）・
    /// Confirm = 「〜G で かいますか？」の はい / いいえ（道具・個数・カーソル）。取消で戻る先は WorldShop.parentOf。
    pub enum ShopPage with Eq, ToString {
        case Top(Int32)
        case Goods(ShopMode, Int32)
        case Count(ShopMode, ItemsDoc.ItemId, Int32)
        case Confirm(ShopMode, ItemsDoc.ItemId, Int32, Answer)
    }

    /// 知らせを送った後に行く所。Close = ウィンドウを閉じる / BackTo = メニューのそのページへ戻る。
    pub enum NoticeThen {
        case Close
        case BackTo(MenuPage)
    }

    /// 知らせ（1 枚）。reveal = 文字送り（字は reveal#text）。
    pub type alias NoticeState = { reveal = UiTypewriter.Reveal, then = NoticeThen }

    /// フィールドの上に開いているウィンドウ。Shop は店（rpg.shops.json の品の shop。None は村の道具屋）と開いた会話を持ち、
    /// 閉じるとその続きへ戻る。
    pub enum FieldWindow {
        case Closed
        case Talk(TalkState)
        case Menu(MenuPage)
        case Shop(Option[ShopsDoc.ShopId], ShopPage, TalkState)
        case Notice(NoticeState)
    }

    /// マップを歩いている間だけの値。trail = 先頭が前にいたマスとその時の向き（新しい順に trailLength まで）。
    /// 2 人目は trail の 1 つ目に立つ（足りなければ先頭と同じマスに重なる）。
    /// awaitRelease = ウィンドウを閉じたフレームに押していた方向（Controls.step が入れる）。離すまで、その向きへは歩かない（向きだけ変える）。
    /// stepsToFight = 次の戦いまでの歩数（出会いの組のあるマップで 1 マスごとに減る。0 はまだ引いていない = 次の 1 歩で引く）。
    /// rocks = 押して動かした岩の今のマス（objects の id → マス。無い岩は Doc の位置。マップを移ると空に戻る）。
    /// light = たいまつの残りの歩数（暗いマップで 1 マスごとに減る。0 なら明かりは先頭のまわりだけ）。
    /// WhyNot: 岩とたいまつをセーブに書かない — 岩はマップを出ると戻す決まり（詰まない）で、セーブは宿（明るい村）でだけ書く。
    pub type alias FieldRec = {
        map = MapDoc.MapId,
        hero = Grid.Cell,
        facing = Dir4.Dir4,
        stride = Stride,
        trail = List[(Grid.Cell, Dir4.Dir4)],
        awaitRelease = List[Dir4.Dir4],
        stepsToFight = Int32,
        rocks = Map[String, Grid.Cell],
        light = Int32,
        window = FieldWindow,
        transition = Option[Transition]
    }

    /// trail に持つマスの数: 2 人目と 3 人目が立つ 2 つと、3 人目が歩き出す 1 つ前のマス。
    /// WhyNot: 2 つで切らない — 3 人目は「立つマス」の 1 つ古いマスから動いて見せるので、それが無いと歩きの途中で跳ぶ。
    pub def trailLength(): Int32 = 3

    enum FieldOf(FieldRec)

    /// マップを歩いている間の値（外では fieldRecOf と mapField を通す）。
    pub type alias FieldState = FieldOf

    // ── 戦い ──

    /// 戦いのコマンドのウィンドウの項目（上から）。選べるかは WorldBattle.isCommandOpen。
    pub enum BattleCommand with Eq, ToString {
        case Fight
        case Spell
        case Items
        case Defend
        case Flee
    }

    /// 戦いのコマンドを選んでいるページ。Commands = コマンドのウィンドウ（カーソル）/ FoeTarget = たたかう の的（生きている敵の何番目か）/
    /// SpellList = その仲間の覚えた呪文 / SpellTarget = 呪文の的（敵 1 体の呪文は生きている敵・回復は仲間の何番目か）/
    /// ItemList = 戦いのどうぐの一覧（WorldBattle.itemsOf）/ ItemTarget = 道具の的（burn の物は生きている敵・ほかは仲間）。
    /// 取消で戻る先は WorldBattle.cancel（的 → 一覧 → コマンド → 前の仲間の選び直し）。
    pub enum CommandPage with Eq, ToString {
        case Commands(Int32)
        case FoeTarget(Int32)
        case SpellList(Int32)
        case SpellTarget(SpellsDoc.SpellId, Int32)
        case ItemList(Int32)
        case ItemTarget(ItemsDoc.ItemId, Int32)
    }

    /// 伝言を出し終えた後にすること。Choose = 最初の仲間のコマンドへ（現れた時）/ Judge = 勝ち負けを見る（1 ターンの後）/
    /// Leave = 戦いを終える（勝ち・全滅・逃げ切りの伝言の後）。
    pub enum AfterShow with Eq, ToString {
        case Choose
        case Judge
        case Leave(Battle.Outcome)
    }

    /// 戦いの進み。Choose = その仲間のコマンドを選んでいる /
    /// Show = 伝言を 1 枚ずつ出している（今の 1 枚・その後に出す残り・今の 1 枚を出し始めた時刻・出し終えた後）。
    pub enum Phase {
        case Choose(Member.Member, CommandPage)
        case Show(Battle.Beat, List[Battle.Beat], Clock.Time[Play], AfterShow)
    }

    /// 戦いの間だけの値。battle = 戦いの値（ターンの後。表示は Show の今の Beat の after を読む）、
    /// back = 戻る先のフィールド、plans = このターンに選び終えた仲間の行動、afterWin = 勝った後に開く会話のノード。
    pub type alias BattleRec = {
        battle = Battle.Battle,
        phase = Phase,
        back = FieldState,
        plans = Map[Member.Member, Battle.Plan],
        afterWin = Option[String]
    }

    enum BattleOf(BattleRec)

    /// 戦いの間の値（外では battleRecOf と mapBattle を通す）。
    pub type alias BattleState = BattleOf

    // ── エンディング ──

    /// エンディングの間だけの値。startedAt = 入った時刻（スタッフの字はここから rules の creditSeconds かけて流れる）、
    /// back = 下敷きに描くフィールド（報告した村。ウィンドウと暗転は閉じてある）、skipped = 決定で字を流れ切った所まで早送りした。
    pub type alias EndingRec = { startedAt = Clock.Time[Play], back = FieldState, skipped = Bool }

    enum EndingOf(EndingRec)

    /// エンディングの間の値（外では endingRecOf を通す。作るのは enterEnding だけ）。
    pub type alias EndingState = EndingOf

    /// 今の場面と、その場面だけが持つ値。
    pub enum Scene {
        case Title(TitleItem)
        case Field(FieldState)
        case Battle(BattleState)
        case Ending(EndingState)
    }

    /// 場面の名前だけ（比べる・字にする）。
    pub enum SceneKind with Eq, ToString {
        case Title
        case Field
        case Battle
        case Ending
    }

    /// ゲームの状態（遊びの状態だけ。Doc と絵は Res が持つ）。dice = 乱数を引いた回数（Dice）、
    /// save = 書く（起動の時に読んだ）セーブの中身（タイトルの「つづきから」もここを読む）、
    /// saveRev = セーブを書く合図（App.addOutput がこの値の変わった時だけ save を書く。0 は書く物が無い）。
    pub type alias World = {
        scene = Scene,
        party = Party.Party,
        bag = Bag.Bag,
        progress = Progress.Progress,
        dice = Int32,
        play = Clock.Clock[Play],
        realNow = Clock.Time[Clock.Real],
        ask = Option[Ask],
        events = Emit.Events[Event],
        save = Option[Saves.SaveData],
        saveRev = Int32
    }

    /// 起動の World。タイトルから始まる（カーソルは「はじめから」。仲間と手持ちのお金は「はじめから」で Doc から入る）。
    /// save = 起動の時に読んだセーブ（無ければ「つづきから」は灰色）。
    pub def initial(save: Option[Saves.SaveData]): World =
        { scene = Scene.Title(TitleItem.NewGame), party = Party.empty(), bag = Bag.withGold(0), progress = Progress.initial(), dice = 0, play = Clock.start(), realNow = Clock.zero(),
          ask = None, events = Emit.empty(), save = save, saveRev = 0 }

    // ── 場面を読む・書く口 ──

    pub def sceneKindOf(w: World): SceneKind = match w#scene {
        case Scene.Title(_) => SceneKind.Title
        case Scene.Field(_) => SceneKind.Field
        case Scene.Battle(_) => SceneKind.Battle
        case Scene.Ending(_) => SceneKind.Ending
    }

    /// マップを歩いている間の値（タイトルなら None）。
    pub def fieldRecOf(w: World): Option[FieldRec] = match w#scene {
        case Scene.Field(FieldOf.FieldOf(r)) => Some(r)
        case _                               => None
    }

    /// 描くフィールド: 歩いている間はそのフィールド、エンディングの間は下敷きのフィールド（ほかは None）。
    /// WhyNot: fieldRecOf にエンディングの下敷きを混ぜない — 歩き・入力・出会いの規則がエンディングの間にも動き出す。
    pub def shownFieldOf(w: World): Option[FieldRec] = match w#scene {
        case Scene.Field(FieldOf.FieldOf(r))    => Some(r)
        case Scene.Ending(EndingOf.EndingOf(e)) => Some(fieldRecOfState(e#back))
        case _                                  => None
    }

    /// エンディングの間の値（ほかの場面では None）。
    pub def endingRecOf(w: World): Option[EndingRec] = match w#scene {
        case Scene.Ending(EndingOf.EndingOf(e)) => Some(e)
        case _                                  => None
    }

    /// 今のフィールドを下敷きにエンディングへ入る（at = 入った時刻。ウィンドウと暗転は閉じる）。フィールドでなければ何もしない。
    /// [遷移: Field→Ending]
    pub def enterEnding(at: Clock.Time[Play], w: World): World = match w#scene {
        case Scene.Field(FieldOf.FieldOf(r)) =>
            let back = FieldOf.FieldOf({ window = FieldWindow.Closed, transition = None, stride = Stride.Still | r });
            { scene = Scene.Ending(EndingOf.EndingOf({ startedAt = at, back = back, skipped = false })) | w }
        case _ => w
    }

    /// スタッフの字を流れ切った所まで早送りする（エンディングでなければ何もしない）。
    pub def skipCredits(w: World): World = match w#scene {
        case Scene.Ending(EndingOf.EndingOf(e)) => { scene = Scene.Ending(EndingOf.EndingOf({ skipped = true | e })) | w }
        case _                                  => w
    }

    /// タイトルへ戻る（仲間・ふくろ・進み具合は起動の時と同じ空に戻す。セーブと時計はそのまま。カーソルは「はじめから」）。
    /// WhyNot: セーブを消さない・書かない — エンディングの後の「つづきから」は、最後に泊まった宿から（ボスの前）。[遷移: Ending→Title]
    pub def toTitle(w: World): World =
        { play = w#play, realNow = w#realNow, events = w#events, saveRev = w#saveRev, dice = w#dice | initial(w#save) }

    /// 持っているフィールドの値の中身（戦いの戻る先を読む）。
    pub def fieldRecOfState(f: FieldState): FieldRec = match f { case FieldOf.FieldOf(r) => r }

    /// マップを歩いている間だけ f を掛ける（ほかの場面ではそのまま）。
    pub def mapField(f: FieldRec -> FieldRec \ ef, w: World): World \ ef = match w#scene {
        case Scene.Field(FieldOf.FieldOf(r)) => { scene = Scene.Field(FieldOf.FieldOf(f(r))) | w }
        case _                               => w
    }

    /// 戦いの間の値（戦いでなければ None）。
    pub def battleRecOf(w: World): Option[BattleRec] = match w#scene {
        case Scene.Battle(BattleOf.BattleOf(r)) => Some(r)
        case _                                  => None
    }

    /// 戦いの間だけ f を掛ける（ほかの場面ではそのまま）。
    pub def mapBattle(f: BattleRec -> BattleRec \ ef, w: World): World \ ef = match w#scene {
        case Scene.Battle(BattleOf.BattleOf(r)) => { scene = Scene.Battle(BattleOf.BattleOf(f(r))) | w }
        case _                                  => w
    }

    /// 戦いを始める（back = 戻る先のフィールド）。[遷移: Field→Battle]
    pub def placeBattle(r: BattleRec, w: World): World = { scene = Scene.Battle(BattleOf.BattleOf(r)) | w }

    /// 戦いから back のフィールドへ戻る（暗転・歩き・ウィンドウは無し）。[遷移: Battle→Field]
    pub def returnToField(back: FieldState, w: World): World = { scene = Scene.Field(back) | w }

    /// 今のフィールドの値（Battle に入る時に戻る先として持つ）。
    pub def fieldStateOf(w: World): Option[FieldState] = match w#scene {
        case Scene.Field(f) => Some(f)
        case _              => None
    }

    /// 点滅を始め、点滅し終えたら foes と戦う（afterWin = 勝った後に開く会話のノード）。歩きは止める。
    pub def startEncounter(foes: List[FoesDoc.FoeId], afterWin: Option[String], w: World): World =
        startTransition(TransitionThen.StartBattle(foes, afterWin), w)

    /// 今から暗転（点滅）を始め、覆い切ったら then をする（WorldTransition）。歩きは止める。フィールドでなければ何もしない。
    pub def startTransition(then: TransitionThen, w: World): World =
        mapField(r -> { stride = Stride.Still, transition = Some({ startedAt = now(w), then = then }) | r }, w)

    /// 遊びの時計の今。
    pub def now(w: World): Clock.Time[Play] = Clock.nowOf(w#play)

    /// 実時間の今（秒）。点滅と足踏みのコマを選ぶ所だけで使う。
    pub def realSeconds(w: World): Float64 = Clock.secondsOf(w#realNow)

    // ── 場面の移り ──

    /// 開いているウィンドウを閉じる（どのウィンドウもここを通す）。
    /// 閉じたフレームに押していた方向は、Controls.step が holdUntilReleased で awaitRelease に入れる。
    /// WhyNot: 閉じる時の向き 1 つだけを待たない — メニューは方向キーと関係なく開くので、カーソルを動かした方向を押したまま閉じると、
    /// その方向へすぐ歩き出す（会話でも、押したまま閉じた方向へ出口の gate や人の会話がすぐまた開く）。
    pub def closeWindow(r: FieldRec): FieldRec = match r#window {
        case FieldWindow.Closed => r
        case _                  => { window = FieldWindow.Closed | r }
    }

    /// ウィンドウが開いているか。
    pub def isWindowOpen(w: World): Bool =
        fieldRecOf(w) |> Option.exists(r -> match r#window {
            case FieldWindow.Closed => false
            case _                  => true
        })

    /// 出入口を通って行き先のマスに着いた所（歩き・隊列・ウィンドウ・閉じた向きの待ち・動かした岩を消す。暗転はそのまま）。
    pub def arriveAt(map: MapDoc.MapId, cell: Grid.Cell, facing: Dir4.Dir4, r: FieldRec): FieldRec =
        { map = map, hero = cell, facing = facing, stride = Stride.Still, trail = Nil, awaitRelease = Nil, rocks = Map.empty(),
          window = FieldWindow.Closed | r }

    /// 閉じたフレームに押していた方向を、離すまで歩かない方向にする（Controls.step がウィンドウの閉じたフレームに呼ぶ）。
    pub def holdUntilReleased(dirs: List[Dir4.Dir4], w: World): World = mapField(r -> { awaitRelease = dirs | r }, w)

    /// 離すまで歩かない方向を、まだ押している方向だけに減らす（Controls が歩けるフレームに呼ぶ）。
    pub def releaseAwait(stillHeld: List[Dir4.Dir4], w: World): World =
        mapField(r -> { awaitRelease = r#awaitRelease |> List.filter(dir -> List.memberOf(dir, stillHeld)) | r }, w)

    /// 開いているウィンドウを window にする（閉じるのは closeWindow）。
    pub def withWindow(window: FieldWindow, w: World): World = mapField(r -> { window = window | r }, w)

    /// 文字送りをしているウィンドウ（会話・知らせ）の話し手の id（地の文と知らせは空）と文字送り。無ければ None。
    pub def typingOf(w: World): Option[(String, UiTypewriter.Reveal)] =
        fieldRecOf(w) |> Option.flatMap(r -> match r#window {
            case FieldWindow.Talk(t)   => talkRecOf(t)#line |> Option.map(line -> (line#speaker, talkRecOf(t)#reveal))
            case FieldWindow.Notice(n) => Some(("", n#reveal))
            case _                     => None
        })

    /// 知らせを 1 枚出す（then = 送った後に行く所）。
    pub def showNotice(text: String, then: NoticeThen, w: World): World =
        withWindow(FieldWindow.Notice({ reveal = UiTypewriter.start(text), then = then }), w)

    // ── セーブ ──

    /// 今の World のセーブの中身。
    pub def saveDataOf(w: World): Saves.SaveData =
        Saves.of({ party = w#party, bag = w#bag, progress = w#progress, dice = w#dice })

    /// 今の中身をセーブにし、書く合図（saveRev）を 1 進める。
    pub def writeSave(w: World): World = { save = Some(saveDataOf(w)), saveRev = w#saveRev + 1 | w }

    /// マップのマスに立つ（ウィンドウは閉じ、暗転は無し）。[遷移: Title / Field→Field]
    pub def placeField(map: MapDoc.MapId, hero: Grid.Cell, facing: Dir4.Dir4, w: World): World =
        { scene = Scene.Field(FieldOf.FieldOf({ map = map, hero = hero, facing = facing, stride = Stride.Still, trail = Nil,
                                                awaitRelease = Nil, stepsToFight = 0, rocks = Map.empty(), light = 0,
                                                window = FieldWindow.Closed, transition = None })) | w }

    /// マップのマスに立ち、暗転を晴らして入る。[遷移: Title→Field]
    pub def enterField(map: MapDoc.MapId, hero: Grid.Cell, facing: Dir4.Dir4, w: World): World =
        placeField(map, hero, facing, w)
            |> mapField(r -> { transition = Some({ startedAt = now(w), then = TransitionThen.FadeIn }) | r })

    /// タイトルのカーソルの項目（タイトルでなければ None）。
    pub def titleCursorOf(w: World): Option[TitleItem] = match w#scene {
        case Scene.Title(item) => Some(item)
        case _                 => None
    }

    /// タイトルのカーソルを item へ。
    pub def withTitleCursor(item: TitleItem, w: World): World = match w#scene {
        case Scene.Title(_) => { scene = Scene.Title(item) | w }
        case _              => w
    }

    // ── 終了の確認 ──

    /// 終了を尋ねる（カーソルは「いいえ」から）。もう尋ねていれば何もしない。
    pub def askQuit(w: World): World =
        if (Option.isEmpty(w#ask)) { ask = Some(Ask.Quit(Answer.No)) | w } else w

    /// 確認のカーソルを answer へ。
    pub def moveAsk(answer: Answer, w: World): World \ Emit[Event] = match w#ask {
        case Some(Ask.Quit(at)) if at != answer => { Emit.emit(Event.Cursor); { ask = Some(Ask.Quit(answer)) | w } }
        case _                                  => w
    }

    /// 確認を閉じる（いいえ・取消）。
    pub def closeAsk(w: World): World \ Emit[Event] =
        Emit.emit(Event.Cancel);
        { ask = None | w }

    /// 遊びの時計のこのフレームの進み方。止める理由は確認のウィンドウ。
    pub def paceOf(w: World): Clock.Pace[Play, Halt] =
        if (Option.nonEmpty(w#ask)) Clock.paceOf(Clock.Run.Paused(Halt.Asking))
        else Clock.paceOf(Clock.Run.Running)
}
