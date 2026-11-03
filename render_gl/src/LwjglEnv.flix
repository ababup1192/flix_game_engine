// LwjglEnv — LwjglLayer が自分で読む環境変数（窓・撮影・音量・時計）を、withLwjgl の頭で 1 回だけ読んで値にする。
// 2D と 3D のどちらの描き物にも効く。どれも開発の道具（突き合わせ・撮影・測り）のための口で、置いていなければ実機の振る舞いは変わらない。
// 起動画面（FLIX_GE_NO_SPLASH は RenderSplash）と字（FLIX_GE_GLYPHS・FLIX_GE_CACHE_DIR・FLIX_GE_NO_FONT_CACHE は RenderFont / FontCache）の旗は、
// 画面なしの描き手（GlOffscreen）も同じ物を読むので、それぞれの持ち主が読む。
mod LwjglEnv {

    /// 実機の窓の起動を変える環境変数の値。
    /// hidden: FLIX_GE_HIDDEN を置いた（値は問わない）。隠しウィンドウで framebuffer を design の大きさに固定し、垂直同期を待たない。
    /// muted: FLIX_GE_MUTE が空でも "0" でもない。全体の音量を 0 にする。
    /// frameStats: FLIX_GE_FRAME_STATS が空でない。1 コマの時間を数える（RenderFrameStats）。
    /// frameShotDir: FLIX_GE_FRAME_SHOT のフォルダ（空なら無し）。swap の直前の絵を frame-N.png へ書く。
    /// splashShotPath: FLIX_GE_SPLASH_SHOT のパス（空なら無し）。起動画面を数枚書く。
    /// fixedDt: FLIX_GE_FIXED_DT の秒（空なら無し）。毎コマの dt を実時間の代わりにこの値にする（同じ操作で同じ絵になるかを確かめる用）。
    pub type alias Settings = {
        hidden = Bool,
        muted = Bool,
        frameStats = Bool,
        frameShotDir = Option[String],
        splashShotPath = Option[String],
        fixedDt = Option[Float64]
    }

    /// 今のプロセスの環境変数から読む。FLIX_GE_FIXED_DT が読めない値なら実時間のまま続け、1 行言う。
    // WhyNot: 読めない FLIX_GE_FIXED_DT で起動を止めない — 開発の道具の口なので、遊べる窓を落とすほどではない。
    // 黙って実時間に戻すと「固定したつもりで絵が揺れる」になるので、知らせだけは出す。
    pub def load(): Settings \ IO =
        let env = ProcessEnv.snapshot();
        let settings = fromMap(env);
        warnUnreadableFixedDt(env, settings);
        settings

    /// 環境変数の表から読む（知らせは出さない）。FLIX_GE_FIXED_DT が読めない値なら fixedDt は None。
    pub def fromMap(env: Map[String, String]): Settings =
        let filled = name -> Map.get(name, env) |> Option.filter(value -> value != "");
        { hidden = Map.memberOf("FLIX_GE_HIDDEN", env),
          muted = filled("FLIX_GE_MUTE") |> Option.exists(value -> value != "0"),
          frameStats = Option.nonEmpty(filled("FLIX_GE_FRAME_STATS")),
          frameShotDir = filled("FLIX_GE_FRAME_SHOT"),
          splashShotPath = filled("FLIX_GE_SPLASH_SHOT"),
          fixedDt = filled("FLIX_GE_FIXED_DT") |> Option.flatMap(text -> Result.toOption(parseFixedDt(text))) }

    /// 1 コマの dt（秒）。fixedDt があれば実時間（elapsedNanos）の代わりにそれを使う。どちらも maxDt で切る（Platform.FrameClock.getDeltaTime の約束）。
    // WhyNot: dt の計算を LwjglLayer の handler の中に書かない — 固定と実時間の分かれ目をテストで固定したい。
    pub def frameDt(fixedDt: Option[Float64], maxDt: Float64, elapsedNanos: Int64): Float64 =
        let raw = Option.getWithDefault(Int64.toFloat64(elapsedNanos) / 1000000000.0, fixedDt);
        Float64.min(raw, maxDt)

    /// FLIX_GE_FIXED_DT の字を秒にする。0 より大きい有限の数だけを受ける（"0.016"・"1/60" は分数として読む）。
    pub def parseFixedDt(text: String): Result[String, Float64] =
        let trimmed = String.trim(text);
        let parsed = match String.splitOn({ substr = "/" }, trimmed) {
            case numerator :: denominator :: Nil =>
                Option.flatMap(n -> Float64.fromString(String.trim(denominator)) |> Option.map(d -> n / d),
                               Float64.fromString(String.trim(numerator)))
            case _ => Float64.fromString(trimmed)
        };
        match parsed {
            case Some(seconds) if seconds > 0.0 and Float64.isFinite(seconds) => Ok(seconds)
            case Some(_) => Err("0 より大きい有限の秒を書く（例 0.016・1/60）")
            case None    => Err("数として読めない（例 0.016・1/60）")
        }

    def warnUnreadableFixedDt(env: Map[String, String], settings: Settings): Unit \ IO =
        match (Map.get("FLIX_GE_FIXED_DT", env) |> Option.filter(text -> text != ""), settings#fixedDt) {
            case (Some(text), None) =>
                checked_ecast(Log.fellBack("lwjgl", "FLIX_GE_FIXED_DT=${text}", "実時間の dt", parseFailureOf(text)))
            case _ => ()
        }

    /// parseFixedDt が受けなかった理由（受けた字なら空）。
    def parseFailureOf(text: String): String = match parseFixedDt(text) {
        case Err(why) => why
        case Ok(_)    => ""
    }
}
