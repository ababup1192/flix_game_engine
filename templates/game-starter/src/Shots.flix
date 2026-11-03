// Shots — ギャラリーの場面（make render-all の 1 枚）の World を組む。描き出し（SceneRender）と実機（Game の App.withShots。
// START=shot:<場面>）が同じ関数で組むので、実機で開いた場面はギャラリーの絵と同じ World から始まる。
// WhyNot: 描き出しの物（HeadlessRender・HeadlessFont・java.io）を引かない — Game.app から engine_tools へつながり、ブラウザ版で組めなくなる。
mod Shots {
    /// 描き出せる場面の名前。make render の使い方も SHOT の当たり判定も、この並びが source of truth。
    /// 場面の題と一言（Studio のギャラリーに出るラベル）は assets/*.scenes.json 側で、
    /// name をここの名前とそろえる。ラベルを足しても描き出す場面は増えない。
    /// 場面を足したら、ここと sceneOf と Makefile の SHOTS を一緒に足す。
    pub def names(): List[String] =
        "main" :: "quit" :: Nil

    /// 名前 → 描き出しと同じ初めの World（initialWorld）から組んだ場面の World。描き出しはこの World をそのまま描く。
    pub def worldOf(name: String, _res: Res.Res): Option[World.World] = sceneOf(name, initialWorld())

    /// 描き出しの初めの World（時刻は renderTime）。アトリエの候補テーマもこの World で描く。
    pub def initialWorld(): World.World = { t = renderTime() | World.initial() }

    /// 生成するときの時刻（秒）。実時間でなく固定値を使う — 空の流れも塵の位置もこの t
    /// だけで決まるので、何度生成しても同じ PNG が出る（スナップショットのバイト比較が成り立つ）。
    def renderTime(): Float64 = 3.0

    /// 名前 → その場面の World。names と対で保つ。名前で引く形にしてあるので、
    /// SHOT で 1 枚だけ生成するときに残りの場面は組まない。
    def sceneOf(name: String, w0: World.World): Option[World.World] =
        match name {
            case "main" => Some(w0)
            case "quit" => Some(World.askQuit(w0))   // Esc・閉じるボタンで出る終了の確認（Layer.Prompt）
            case _      => None
        }
}
