// World — 遊びの状態そのものと、次の状態を作る規則（すべて純粋）。
// 主人公を矢印キーで動かすだけの最小の骨組み。Doc（速さ・キー・色・絵・空の塗り）と
// Doc から作る物（仕上げたドット絵・アトラス）は Res が持ち、World は持たない（読む口は res を受ける）。
//
// ── 場面 ──
// 画面は Screen の enum で分け、その画面だけが持つ値は payload に入れる。今は Play の 1 つだけ。
// 表紙・クリア等を足すときは Screen に case を足し、step と View を match で分ける（手本は tidepool-starter）。
mod World {

    use fge::{Num, PxSprite, Vec2}

    /// このフレームの入力（横・縦の軸値。-1 / 0 / +1）。
    pub type alias Input = { x = Float64, y = Float64 }

    /// 終了の確認。Esc か窓の閉じるボタンで Asking（確認の窓を出し、主人公は止まる）、
    /// はいで Confirmed（Main の App.quitWhen がこれを見て閉じる）、いいえで Playing へ戻る。
    pub enum Quit with Eq, ToString {
        case Playing
        case Asking
        case Confirmed
    }

    /// マウスで押せる物（View が描く木に ZStack.hit で積み、Controls が SortingLayer.pickFrom で引く）。
    pub enum Press with Eq, ToString {
        case QuitYes   // 終了の確認の窓の中（Enter と同じ）
        case QuitNo    // 窓の外（Esc と同じ）
    }

    /// どの画面か。その画面だけが持つ値を payload に持つ。
    pub enum Screen {
        /// 主人公を動かしている。
        case Play(Session)
    }

    /// 遊んでいる間の中身（主人公の中心の位置）。
    pub type alias SessionRec = {
        x = Float64,
        y = Float64
    }

    /// 遊んでいる間の中身。作るのは World の中（initial・mapSessionRec）だけ。読む口は sessionRecOf・書く口は mapSession。
    enum SessionOf(SessionRec)

    pub type alias Session = SessionOf

    /// 遊びの状態。t は積み上げた秒（空の流れ・塵・待ち姿の揺れがこれを見る）。
    /// t と quit はどの画面でも使うので、Screen の外に置く。
    pub type alias World = {
        t = Float64,
        screen = Screen,
        quit = Quit
    }

    // ── 盤の寸法（design __W__×__H__ の中の定数。project.json と同じ値） ──

    pub def width(): Float64 = __W__.0
    pub def height(): Float64 = __H__.0

    /// ドット絵を何倍の大きさで描くか（1 セル = 何 px か）。
    pub def spriteScale(): Int32 = 2

    /// 主人公の大きさ = 絵の大きさ。
    /// WhyNot: 固定値にしない。絵だけ大きくして当たりが古いまま、という食い違いが出る。
    /// 絵がまだ読めていないときだけ 16×16 にする（fail-open）。
    pub def heroBox(res: Res.Res): Vec2.Vec2 =
        PxSprite.sizeOf(res#sprites, "hero", "idle", spriteScale())
            |> Option.getWithDefault({ x = 16.0, y = 16.0 })

    pub def spritePath(): String = "assets/__NAME__.sprite.json"

    pub def shaderPath(): String = "assets/__NAME__.shader.json"

    /// ゲーム開始時の状態。主人公は画面の真ん中。
    pub def initial(): World =
        { t = 0.0, screen = Screen.Play(SessionOf.SessionOf({ x = width() / 2.0, y = height() / 2.0 })),
          quit = Quit.Playing }

    def sessionRec(session: Session): SessionRec = match session {
        case SessionOf.SessionOf(rec) => rec
    }

    def mapSessionRec(f: SessionRec -> SessionRec, session: Session): Session = SessionOf.SessionOf(f(sessionRec(session)))

    /// 遊んでいる間の中身（Play の外は None）。
    def sessionRecOf(w: World): Option[SessionRec] = match w#screen {
        case Screen.Play(session) => Some(sessionRec(session))
    }

    /// 遊んでいる間の中身を f で替える（Play の外はそのまま）。
    def mapSession(f: SessionRec -> SessionRec, w: World): World = match w#screen {
        case Screen.Play(session) => { screen = Screen.Play(mapSessionRec(f, session)) | w }
    }

    /// 主人公の中心（主人公が出ていない画面では None）。
    pub def heroAt(w: World): Option[Vec2.Vec2] =
        sessionRecOf(w) |> Option.map(rec -> { x = rec#x, y = rec#y })

    /// 大きさ box の物が画面から出ない位置へ丸める（端で止まるのはルール）。
    def clampInside(box: Vec2.Vec2, p: Vec2.Vec2): Vec2.Vec2 =
        { x = Num.clamp(box#x / 2.0, width() - box#x / 2.0, p#x),
          y = Num.clamp(box#y / 2.0, height() - box#y / 2.0, p#y) }

    /// 入力の向きに Doc（sample.kind.json）の速さで主人公を動かす。
    def moveHero(res: Res.Res, input: Input, dt: Float64, rec: SessionRec): SessionRec =
        let speed = SampleDoc.rec(res#sample)#speed;
        let moved = { x = rec#x + input#x * speed * dt, y = rec#y + input#y * speed * dt };
        let p = clampInside(heroBox(res), moved);
        { x = p#x, y = p#y }

    /// 入力と経過時間から次の状態を作る。
    /// 終了の確認の窓が出ている間は動かない（時刻だけ進むので空や塵は流れ続ける）。
    pub def step(res: Res.Res, input: Input, dt: Float64, w: World): World =
        let advanced = { t = w#t + dt | w };
        if (w#quit != Quit.Playing) advanced
        else mapSession(rec -> moveHero(res, input, dt, rec), advanced)

    // ── 終了の確認 ──

    /// Esc・閉じるボタン: 遊んでいる間なら確認の窓を出す。
    pub def askQuit(w: World): World =
        if (w#quit == Quit.Playing) { quit = Quit.Asking | w } else w

    /// 確認の窓への答え（yes なら終わる・no なら遊びへ戻る）。窓が出ていないときは何もしない。
    pub def answerQuit(yes: Bool, w: World): World =
        if (w#quit != Quit.Asking) w
        else if (yes) { quit = Quit.Confirmed | w }
        else { quit = Quit.Playing | w }

    pub def isAskingQuit(w: World): Bool = w#quit == Quit.Asking

    pub def isQuitting(w: World): Bool = w#quit == Quit.Confirmed
}
