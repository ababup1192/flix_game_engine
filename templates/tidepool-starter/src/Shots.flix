// Shots — ギャラリーの場面（make render-all の 1 枚）の World を組む。描き出し（SceneRender）と実機（Game の App.withShots。
// START=shot:<場面>）が同じ関数で組むので、実機で開いた場面はギャラリーの絵と同じ World から始まる。
// WhyNot: 描き出しの物（HeadlessRender・HeadlessFont・java.io）を引かない — Game.app から engine_tools へつながり、ブラウザ版で組めなくなる。
mod Shots {
    /// 描き出せる場面の名前。make render の使い方も SHOT の当たり判定も、この並びが source of truth。
    /// 場面の題と一言（Studio のギャラリーに出るラベル）は assets/*.scenes.json 側で、
    /// name をここの名前とそろえる。ラベルを足しても描き出す場面は増えない。
    /// 場面を足したら、ここと sceneOf と Makefile の SHOTS を一緒に足す。
    pub def names(): List[String] =
        "title" :: "play" :: "flood" :: "dam" :: "clear" :: "washed" :: "ending" :: "quit" :: Nil

    /// 名前 → 描き出しと同じ初めの World（loadWorld）から組んだ場面の World。
    pub def worldOf(name: String, res: Res.Res): Option[World.World] = sceneOf(name, res, loadWorld())

    /// 名前 → その場面の World。names と対で保つ。名前で引く形にしてあるので、
    /// SHOT で 1 枚だけ生成するときに残りの場面は組まない。
    def sceneOf(name: String, res: Res.Res, w0: World.World): Option[World.World] =
        let settled = w -> World.tick(2.0, w);
        match name {
            // 面 1〜4 を解いた後に題名へ戻り、面 5 を選んでいる。
            case "title"  => Some(World.backToTitle(solvedUpTo(res, 4, w0)))
            // 面 5 の途中の上げ潮。破線が次の手の水際。
            case "play"   => Some(partway(res, 4, 7, w0))
            // 同じ盤の満ち潮。
            case "flood"  => Some(partway(res, 4, 9, w0))
            // 小石でせき止めた池が、引き潮でも外の潮より高い水を残している。
            case "dam"    => Some(partway(res, 4, 12, w0))
            case "clear"  => Some(settled(partway(res, 0, 99, w0)))
            // 面 1 で満ち潮の低い岩へ下りて流された。
            case "washed" => Some(settled(played(res, "RRD", World.enterLevel(res, 0, w0))))
            case "ending" => Some(settled(solvedUpTo(res, 6, w0)))
            case "quit"   => Some(World.askQuit(partway(res, 4, 7, w0)))   // Esc・閉じるボタンで出る終了の確認（Layer.Prompt）
            case _        => None
        }

    /// 生成するときの時刻（秒）から始めた、題名の画面の World。実時間でなく固定値を使う —
    /// 水の流れも泡の位置もこの t だけで決まるので、何度生成しても同じ PNG が出る（スナップショットのバイト比較が成り立つ）。
    def loadWorld(): World.World = World.tick(3.0, World.initial())

    /// 手の列（U D L R W）を 1 手ずつ World に流し、各手の動きを終わらせる。
    def played(res: Res.Res, moves: String, w: World.World): World.World =
        World.movesOf(moves) |> Option.getWithDefault(Nil)
            |> List.foldLeft((acc, move) -> World.tick(0.5, World.play(res, move, acc)), w)

    /// 面 index（0 から）を Doc の解き方の先頭 n 手まで遊んだ後。
    def partway(res: Res.Res, index: Int32, n: Int32, w: World.World): World.World =
        let solution = LevelsDoc.rec(res#levels)#levels |> List.drop(index) |> List.head
            |> Option.map(level -> String.takeLeft(n, level#solution)) |> Option.getWithDefault("");
        played(res, solution, World.enterLevel(res, index, w))

    /// 面 1 から面 count まで、解き方で解いて決定で次へ進んだ後。
    def solvedUpTo(res: Res.Res, count: Int32, w: World.World): World.World =
        List.range(0, count) |> List.foldLeft((acc, i) -> World.advance(res, partway(res, i, 99, acc)), w)
}
