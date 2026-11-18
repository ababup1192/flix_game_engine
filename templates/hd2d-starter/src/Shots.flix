// Shots — ギャラリーの場面（make render-all の 1 枚）の World を組む。描き出し（SceneRender）と実機（Game の App.withShots。
// START=shot:<場面>）が同じ関数で組むので、実機で開いた場面はギャラリーの絵と同じ World から始まる。
// WhyNot: 描き出しの物（HeadlessRender・HeadlessFont・java.io）を引かない — Game.app から engine_tools へつながり、ブラウザ版で組めなくなる。
mod Shots {
    /// 描き出せる場面の名前。make render の使い方も SHOT の当たり判定も、この並びが source of truth。
    /// 場面を足したら、ここと sceneOf と Makefile の SHOTS を一緒に足す。
    pub def names(): List[String] = "title" :: "start" :: "avenue" :: "quit" :: Nil

    /// 名前 → 描き出しと同じ初めの World から組んだ場面の World。
    pub def worldOf(name: String, res: Res.Res): Option[World.World] = sceneOf(name, res, { time = renderTime() | World.initial(res) })

    /// 生成するときの時刻（秒）。実時間でなく固定値を使う — 小物と待機モーションのコマはこの時刻だけで決まるので、
    /// 何度生成しても同じ PNG が出る（スナップショットのバイト比較が成り立つ）。
    def renderTime(): Float64 = 3.0

    /// 名前 → その場面の World。names と対で保つ。
    def sceneOf(name: String, res: Res.Res, w0: World.World): Option[World.World] =
        match name {
            // 十字の広場の真ん中で、隊列がこちらを向いて立つ（Studio のジャンルカードの絵）。
            case "title"  => Some(World.placeLeader(res, 13, 47, Facing.Dir.South, w0))
            // 立ち始め（南の大通り・北を向く）。
            case "start"  => Some(w0)
            // 北の大通り（門へ向かう並木）。
            case "avenue" => Some(World.placeLeader(res, 13, 36, Facing.Dir.North, w0))
            // Esc・閉じるボタンで出る終了の確認（HUD）。
            case "quit"   => Some(World.askQuit(w0))
            case _        => None
        }
}
