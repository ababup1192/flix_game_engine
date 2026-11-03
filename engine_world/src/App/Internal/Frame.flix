// App.Internal.Frame — 1 フレームの入力（Frame）を組む純粋な部品: カーソルの位置と動いた量・固定刻みの回数・押した瞬間の持ち越し。
// ゲームからは呼ばない（App の中身。ゲームの src・test で App.Internal. を書くと lint が止める）。
pub mod App.Internal.Frame {
    /// Frame#cursor に置く位置: キャプチャしている間（applied = Some(true)）は前の位置 prev のまま止め、ほかは読んだ位置 raw。
    /// キャプチャ中の GLFW の位置は窓の外へ流れていく仮の値なので、UI のホバーと mouseMoved に渡さない。
    pub def heldCursor(applied: Option[Bool], prev: Option[Vec2.Vec2], raw: Vec2.Vec2): Vec2.Vec2 =
        if (applied == Some(true)) Option.getWithDefault(raw, prev) else raw

    /// 前の位置 prev から今の位置 cursor へ動いた量（前の位置が無ければ 0）。
    pub def cursorDelta(prev: Option[Vec2.Vec2], cursor: Vec2.Vec2): Vec2.Vec2 =
        prev |> Option.map(p -> Vec2.sub(cursor, p)) |> Option.getWithDefault(Vec2.zero())

    /// withFixedStep の accumulator。持ち越し carry と実フレームの経過秒 realDt を足し、
    /// fixedDt の倍数だけサブステップ回数を出し、端数を次フレームへの持ち越しとして返す。
    /// 回数は 5 を上限にクランプする（暴走防止）。上限に達したフレームは処理落ちの貯金を
    /// 素通しさせず切り捨てる（carry を 0 にする）— そうしないと処理落ちが翌フレーム以降に
    /// 尾を引き、追いつこうとしてさらに重くなる悪循環になる。
    pub def fixedSteps(carry: Float64, realDt: Float64, fixedDt: Float64): (Int32, Float64) =
        let total = carry + realDt;
        let rawSteps = Float64.floor(total / fixedDt);
        if (rawSteps > 5.0)
            (5, 0.0)
        else
            (Float64.tryToInt32(rawSteps) |> Option.getWithDefault(0), total - rawSteps * fixedDt)

    /// withFixedStep の 2 サブステップ目以降に渡す Frame: エッジ 5 種（justPressed /
    /// mouseClicked / mouseMoved / wheel / mouseDelta）だけを「今フレームでは既に消費済み」に潰す。
    /// down / mouseDown のような押しっぱなし状態はそのまま残すので、複数サブステップに
    /// またがっても連続入力（移動など）は各回とも効く。
    pub def suppressEdges(frame: App.Frame): App.Frame =
        withEdges(noPending(), frame)

    /// 未消費エッジなし。
    pub def noPending(): App.PendingEdges =
        { justPressed = Set.empty(), mouseClicked = false, mouseMoved = false, wheel = 0.0, mouseDelta = Vec2.zero() }

    /// バッファしたエッジを今フレームの Frame へ合流させる: justPressed は和集合・
    /// クリックと移動は「どちらかで起きた」・wheel と mouseDelta は量なので加算。
    /// held 系（down / mouseDown / cursor / dt）は今フレームの値をそのまま使う。
    pub def mergeEdges(pending: App.PendingEdges, frame: App.Frame): App.Frame =
        withEdges(addEdges(pending, pendingOf(frame)), frame)

    /// 2 つのエッジを 1 つに: 押した瞬間は和集合・クリックと移動は「どちらかで起きた」・wheel と mouseDelta は量なので足す。
    def addEdges(a: App.PendingEdges, b: App.PendingEdges): App.PendingEdges =
        { justPressed = Set.union(a#justPressed, b#justPressed),
          mouseClicked = a#mouseClicked or b#mouseClicked,
          mouseMoved = a#mouseMoved or b#mouseMoved,
          wheel = a#wheel + b#wheel,
          mouseDelta = Vec2.add(a#mouseDelta, b#mouseDelta) }

    /// frame のエッジの欄を edges で置き換える（held 系はそのまま）。エッジの種類は PendingEdges の欄と同じ並び。
    def withEdges(edges: App.PendingEdges, frame: App.Frame): App.Frame =
        { justPressed = edges#justPressed, mouseClicked = edges#mouseClicked, mouseMoved = edges#mouseMoved,
          wheel = edges#wheel, mouseDelta = edges#mouseDelta | frame }

    /// Frame からエッジ 5 種を抜き出してバッファの形にする（0 ステップのフレームの持ち越し用）。
    pub def pendingOf(frame: App.Frame): App.PendingEdges =
        { justPressed = frame#justPressed, mouseClicked = frame#mouseClicked,
          mouseMoved = frame#mouseMoved, wheel = frame#wheel, mouseDelta = frame#mouseDelta }

    /// システムの列を追加順（左から右）に World へ畳み込む。
    pub def applySystems(frame: App.Frame, systems: List[(App.Frame, w) -> w \ ef], world: w): w \ ef =
        List.foldLeft((acc, sys) -> sys(frame, acc), world, systems)
}
