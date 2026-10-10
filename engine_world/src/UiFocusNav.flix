// UiFocusNav — 画面の選べる物を名前付きで登録すると、矢印キー・Tab・マウスのホバーで
// フォーカス（いま見ている物）が巡る。ホバーとキーのフォーカスが同じ 1 つの値になるので、
// 説明の窓（UiTooltip）やカーソルの枠を「どちらの入力か」で書き分けずに済む。
// 利用例: 戦いの場のカード・状態アイコンを矢印で巡って説明を出す / 一覧のカードにマウスでもキーでも乗る。
//
// 使い方（毎フレーム）:
//   1. いまの画面で選べる物を Target の列にする（名前 key と画面の枠 rect。列の順 = Tab の順、
//      重なっているときは前にある物ほど先に当たる）。
//   2. `update(input, targets, focus)` で入力を当てて、次のフォーカスを得る（最後に触った入力が勝つ）。
//   3. `rectOf(focus, targets)` で枠を引き、説明の窓・カーソルの枠をそこへ出す。
//      枠をキーで動かしたときだけ見せたいなら `isFocusVisible`（web の :focus-visible と同じ考え）。
//
// 矢印の行き先は「その向きの前にある物のうち、まっすぐ前に近い物」（ずれは 2 倍に数える）。
// 決まった並び（行・列）を持つメニューは UiMenu のカーソルの方が素直 —— こちらは並びの決まって
// いない、絵の上に散らばった物を巡るための物。ゲーム側に既にカーソルがある画面では `focusOn` で
// そのカーソルの物をフォーカスにすれば、ホバーと同じ説明の窓の口へ乗る。
//
// 純粋（状態はゲームが持つ Focus の値だけ）。Bevy の InputFocus / DirectionalNavigation と同じ役。

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

    /// 何も押していない入力（マウスは動いていない）。テストや、キーだけで動かす画面の土台に使う。
    pub def noInput(): Input = { pointer = { x = -1.0, y = -1.0 }, pointerMoved = false, step = (0, 0), tab = 0 }

    /// 入力を当てて次のフォーカスを返す。最後に触った入力が勝つ:
    /// 矢印 → その向きの一番近い物、Tab → 列の次（端で反対側へ回る）、マウスが動いた →
    /// その下の物（何も無い所なら外れる）。どれも無いフレームはそのまま。
    /// 乗っていた物が列から消えたら外す（次の矢印は列の先頭から始まる）。
    pub def update(input: Input, targets: List[Target[k]], focus: Focus[k]): Focus[k] with Eq[k] =
        let (dx, dy) = input#step;
        let kept = if (hasKey(focus#key, targets)) focus else { key = None | focus };
        if (dx != 0 or dy != 0) { key = stepDirection(input#step, targets, kept#key), byKey = true }
        else if (input#tab != 0) { key = stepTab(input#tab, targets, kept#key), byKey = true }
        else if (input#pointerMoved) { key = hovered(input#pointer, targets), byKey = false }
        else kept

    /// フォーカスを名前で置く（ゲーム側のカーソルが別にある画面で、その物を説明の窓の口へ乗せる）。
    pub def focusOn(key: k, byKey: Bool): Focus[k] = { key = Some(key), byKey = byKey }

    /// 点の下にある物の名前（列の前にある物ほど先に当たる）。
    pub def hovered(point: Vec2.Vec2, targets: List[Target[k]]): Option[k] =
        targets |> List.find(t -> Rect2.hasPoint(point, t#rect)) |> Option.map(t -> t#key)

    /// フォーカスしている物の枠（乗っていない・列に無いなら None）。
    pub def rectOf(focus: Focus[k], targets: List[Target[k]]): Option[Rect2.Rect2] with Eq[k] =
        focus#key |> Option.flatMap(key -> targets |> List.find(t -> t#key == key) |> Option.map(t -> t#rect))

    /// キーで動かしたフォーカスか（カーソルの枠を出すかの判定。マウスで乗った物には枠を出さない）。
    pub def isFocusVisible(focus: Focus[k]): Bool =
        focus#byKey and Option.nonEmpty(focus#key)

    /// 矢印 1 回ぶん動かした先。いまの物の中心から見て、その向きの前にある物のうち
    /// 「前への距離 + 横のずれ × 2」が一番小さい物。前に何も無ければ動かない。
    /// どこにも乗っていなければ列の先頭へ（最初の 1 回でまず何かに乗る）。
    pub def stepDirection(step: (Int32, Int32), targets: List[Target[k]], current: Option[k]): Option[k] with Eq[k] =
        let (dx, dy) = step;
        match current |> Option.flatMap(key -> targets |> List.find(t -> t#key == key)) {
            case None       => List.head(targets) |> Option.map(t -> t#key)
            case Some(origin) =>
                let c = Rect2.center(origin#rect);
                let scored = targets
                    |> List.filter(t -> t#key != origin#key)
                    |> List.filterMap(t -> {
                        let p = Rect2.center(t#rect);
                        let ahead = (p#x - c#x) * Int32.toFloat64(dx) + (p#y - c#y) * Int32.toFloat64(dy);
                        let aside = Float64.abs((p#x - c#x) * Int32.toFloat64(dy) - (p#y - c#y) * Int32.toFloat64(dx));
                        if (ahead > 0.5) Some((ahead + aside * 2.0, t#key)) else None
                    });
                match List.minimumBy((a, b) -> { let (sa, _) = a; let (sb, _) = b; sa <=> sb }, scored) {
                    case Some((_, key)) => Some(key)
                    case None           => Some(origin#key)
                }
        }

    /// Tab 1 回ぶん動かした先（列の順。端で反対側へ回る）。どこにも乗っていなければ
    /// 進むときは先頭・戻るときは末尾へ。
    pub def stepTab(delta: Int32, targets: List[Target[k]], current: Option[k]): Option[k] with Eq[k] =
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

    /// 名前が列にあるか。
    def hasKey(key: Option[k], targets: List[Target[k]]): Bool with Eq[k] =
        match key {
            case Some(name) => List.exists(t -> t#key == name, targets)
            case None       => true
        }
}
