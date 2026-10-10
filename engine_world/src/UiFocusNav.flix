// UiFocusNav — 画面の選べる物を名前付きで登録すると、矢印キー・Tab・マウスのホバーで
// フォーカス（いま見ている物）が巡る。ホバーとキーのフォーカスが同じ 1 つの値になるので、
// 説明の窓（UiTooltip）やカーソルの枠を「どちらの入力か」で書き分けずに済む。
// 利用例: 画面に散らばったカード・アイコンを矢印で巡って説明を出す / 一覧の項目にマウスでもキーでも乗る。
//
// 使い方（毎フレーム）:
//   1. いまの画面で選べる物を Target の列にする（名前 key と画面の枠 rect。列の順 = Tab の順、
//      重なっているときは前にある物ほど先に当たる）。UiDoc / UiStore で組んだ画面なら
//      `targetsOfUi(listPath, ui, design)` がメニューの項目列からそのまま作る。
//   2. `update(input, targets, focus)` で入力を当てて、次のフォーカスを得る（最後に触った入力が勝つ）。
//   3. `rectOf(focus, targets)` で枠を引き、説明の窓（UiTooltip.computePlacement）・カーソルの枠を
//      そこへ出す。枠をキーで動かしたときだけ見せたいなら `isFocusVisible`
//      （web の :focus-visible・Bevy の InputFocusVisible と同じ考え）。
//
// 矢印の行き先は「その向きの前にある物のうち、まっすぐ前に近い物」（横のずれは asideWeight 倍に数える）。
// 決まった並び（行・列）を持つメニューは UiMenu のカーソルの方が素直 —— こちらは並びの決まって
// いない、絵の上に散らばった物を巡るための物。ゲーム側に既にカーソルがある画面では
// `focusByKey(そのカーソルの物の名前)` を置けば、ホバーと同じ説明の窓の口へ乗る。
//
// UiMenu.syncCursor との違い: あちらはマウスが項目の外へ出てもカーソルを残す（選んでいる物は消えない）。
// こちらはマウスで乗ったフォーカスは指が何も無い所へ出ると外れる（ホバーの説明は指を離せば消える）。
// キーで動かしたフォーカスはマウスを動かすまで残る。
//
// 純粋（状態はゲームが持つ Focus の値だけ）。Bevy の InputFocus / DirectionalNavigation と同じ役。
// マウスの下の物を UI ツリーから引く（クリックの宛先を決める）のは UiFocus.hitTestUi の仕事。

pub mod UiFocusNav {

    /// 選べる物 1 つ。key = 名前（ゲームが決める。"card:2" のような文字列でも enum でもよい）、
    /// rect = 画面の枠（当たり判定と、説明の窓をどこの脇に出すかの両方に使う）。
    pub type alias Target[k] = { key = k, rect = Rect2.Rect2 }

    /// いまのフォーカス。key = 乗っている物（無ければ None）、byKey = キーで動かしたか
    /// （マウスで乗ったときは false）。
    pub type alias Focus[k] = { key = Option[k], byKey = Bool }

    /// 1 フレームの入力。step = 矢印の向き（(-1|0|1, -1|0|1)。y は下が正）、
    /// tab = Tab の進み（+1 / -1 / 0）、pointerMoved = マウスがこのフレームに動いたか。
    pub type alias Input = { pointer = Vec2.Vec2, pointerMoved = Bool, step = (Int32, Int32), tab = Int32 }

    /// 何にも乗っていないフォーカス。
    pub def empty(): Focus[k] = { key = None, byKey = false }

    /// キーで置いたフォーカス（ゲーム側のカーソルが指している物を写すとき）。
    pub def focusByKey(key: k): Focus[k] = { key = Some(key), byKey = true }

    /// マウスで乗ったフォーカス。
    pub def focusByPointer(key: k): Focus[k] = { key = Some(key), byKey = false }

    /// 何も押していない入力（マウスは動いていない）。ここからレコード更新で 1 つだけ足して使う。
    pub def noInput(): Input = { pointer = { x = -1.0, y = -1.0 }, pointerMoved = false, step = (0, 0), tab = 0 }

    /// 入力を当てて次のフォーカスを返す。最後に触った入力が勝つ:
    /// 矢印 → その向きの一番近い物（前に何も無ければ動かない）、Tab → 列の次（端で反対側へ回る）、
    /// マウスが動いた → その下の物（何も無い所なら外れる）。どれも無いフレームは、マウスで乗っている
    /// フォーカスだけ指の下を見直す（指を止めたまま下の物が動いたら、いま指の下にある物を指す）。
    /// 乗っていた物が列から消えたら外す。何にも乗っていないときの最初の矢印・Tab は列の先頭
    /// （Tab で戻るときは末尾）に乗る。
    pub def update(input: Input, targets: List[Target[k]], focus: Focus[k]): Focus[k] with Eq[k] =
        let (dx, dy) = input#step;
        let current = focus#key |> Option.filter(key -> List.exists(t -> t#key == key, targets));
        if (dx != 0 or dy != 0) { key = stepDirection(input#step, targets, current), byKey = true }
        else if (input#tab != 0) { key = stepTab(input#tab, targets, current), byKey = true }
        else if (input#pointerMoved or not focus#byKey) { key = hitTest(input#pointer, targets), byKey = false }
        else { key = current, byKey = true }

    /// 点の下にある物の名前（列の前にある物ほど先に当たる）。
    pub def hitTest(point: Vec2.Vec2, targets: List[Target[k]]): Option[k] =
        targets |> List.find(t -> Rect2.hasPoint(point, t#rect)) |> Option.map(t -> t#key)

    /// フォーカスしている物の枠（乗っていない・列に無いなら None）。
    pub def rectOf(focus: Focus[k], targets: List[Target[k]]): Option[Rect2.Rect2] with Eq[k] =
        focus#key |> Option.flatMap(key -> targets |> List.find(t -> t#key == key) |> Option.map(t -> t#rect))

    /// キーで動かしたフォーカスか（カーソルの枠を出すかの判定。マウスで乗った物には枠を出さない）。
    pub def isFocusVisible(focus: Focus[k]): Bool =
        focus#byKey and Option.nonEmpty(focus#key)

    /// UiDoc / UiStore で組んだメニュー（listPath の項目列 = UiMenu.itemIds）を Target の列にする。
    /// key は項目の名前パス、rect は design 空間でレイアウトした枠（UiFocus.layoutRects）。
    /// 見えていない項目・大きさの無い項目は入れない。
    pub def targetsOfUi(listPath: String, ui: UiStore.UiWorld, design: Vec2.Vec2): List[Target[String]] =
        let rects = UiFocus.layoutRects(ui, design);
        UiMenu.itemIds(listPath, ui) |> List.filterMap(id ->
            Option.flatMap(rect -> Option.map(path -> { key = path, rect = rect }, UiStore.pathOf(id, ui)),
                           Map.get(id, rects)))

    /// 横のずれを前への距離の何倍に数えるか（大きいほど「まっすぐ前」を好む）。
    def asideWeight(): Float64 = 2.0

    /// 「前にある」とみなす最小の距離（px）。同じ行・列に並んだ物を前と数えないための遊び。
    def minAhead(): Float64 = 0.5

    /// 矢印 1 回ぶん動かした先。いまの物の中心から見て、その向きの前にある物のうち
    /// 「前への距離 + 横のずれ × asideWeight」が一番小さい物（同じ点なら列の前の物）。
    def stepDirection(step: (Int32, Int32), targets: List[Target[k]], current: Option[k]): Option[k] with Eq[k] =
        let (dx, dy) = step;
        match current |> Option.flatMap(key -> targets |> List.find(t -> t#key == key)) {
            case None         => List.head(targets) |> Option.map(t -> t#key)
            case Some(origin) =>
                let c = Rect2.center(origin#rect);
                // 点数が同じなら列の前の物（番号も組にして比べる —— 標準ライブラリの選び方に頼らない）。
                let scored = targets |> List.zipWithIndex
                    |> List.filter(entry -> { let (_, t) = entry; t#key != origin#key })
                    |> List.filterMap(entry -> {
                        let (index, t) = entry;
                        let p = Rect2.center(t#rect);
                        let ahead = (p#x - c#x) * Int32.toFloat64(dx) + (p#y - c#y) * Int32.toFloat64(dy);
                        let aside = Float64.abs((p#x - c#x) * Int32.toFloat64(dy) - (p#y - c#y) * Int32.toFloat64(dx));
                        if (ahead > minAhead()) Some((ahead + aside * asideWeight(), index, t#key)) else None
                    });
                match List.minimumBy((a, b) -> { let (sa, ia, _) = a; let (sb, ib, _) = b; (sa, ia) <=> (sb, ib) }, scored) {
                    case Some((_, _, key)) => Some(key)
                    case None           => Some(origin#key)
                }
        }

    /// Tab 1 回ぶん動かした先（列の順。端で反対側へ回る）。
    def stepTab(delta: Int32, targets: List[Target[k]], current: Option[k]): Option[k] with Eq[k] =
        let count = List.length(targets);
        if (count == 0) None
        else {
            let at = current |> Option.flatMap(key -> List.indexOf(key, targets |> List.map(t -> t#key)));
            let next = match at {
                case Some(i) => UiMenu.moveCursor(delta, count, i)
                case None    => if (delta >= 0) 0 else count - 1
            };
            List.nth(next, targets) |> Option.map(t -> t#key)
        }
}
