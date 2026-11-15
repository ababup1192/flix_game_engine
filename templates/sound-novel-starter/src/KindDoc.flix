// KindDoc — novel.kind.json（手触りの数: 字の大きさ・行の数・オートとスキップの間・揺れ・パーティクル）の宣言ドキュメント層。
// 設定の画面で人が変える値（文字の速さ・オートの待ち・音量・ウィンドウの濃さ）の出発点もここ（変えた値はセーブの config が持つ）。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod KindDoc {
    use fge::{Color, DocJson, JsonCodec}
    use Util.Json.Json

    /// bodySize / rubySize / nameSize = 本文・ルビ・名前の字の大きさ（px）、lineGap = 行の間（ルビが入るので rubySize 以上）、
    /// advRows / nvlRows = ADV のウィンドウ・NVL の頁に入る行の数（あふれる前に頁をめくる）、
    /// cps / autoWait / masterVolume / ambienceVolume / seVolume / windowAlpha = 設定の既定（1 秒の字数・オートで読み終えてから送るまでの秒・
    /// 全体と環境音と効果音の音量 0〜1・文章のウィンドウの濃さ 0〜1）、
    /// autoPerChar = オートの待ちに足す 1 字あたりの秒（長い行ほど長く待つ）、skipInterval = スキップで 1 行を出す間（秒）、
    /// logMax = ログに残す行の数、shakeSeconds / shakePx = 強さを書かない <<shake>> の長さと揺れ幅、shakes = 名前付きの揺れの強さ（<<shake 名前>>）、
    /// overlayStart = <<overlay>> を一度も書いていない間の覆いの濃さ（0〜1）、overlayLayer = <<overlay layer=stage>> の層の数（world の中・大きいほど手前）、
    /// fireflies = <<fx fireflies>> のパーティクルの数、snow = <<fx snow>> の雪（Snow）、creditsSpeed = クレジットが流れる速さ（px/秒）、toastSeconds = 知らせを出す秒、
    /// holdFadeSeconds = 素材を待つ時に黒へ重ねる秒（戻す秒も同じ）、holdGiveUpSeconds = 黒のまま待って諦めるまでの秒、
    /// holdMarkSeconds = 黒になってから隅に待ちの印を出すまでの秒（ブラウザ版で後回しの背景・環境音がまだ届いていない時）、
    /// tapSlop / longPressSeconds / swipeMin / swipeSeconds = 読む画面の 1 回の押しを分ける数（Gesture.Limits。押した所から tapSlop px より
    /// 離れずに離せばタップで送る、longPressSeconds 秒以上置けば長押し、swipeMin px 以上を swipeSeconds 秒の内に動かせば払い。長押しと左の払いの外は離すと送る）、
    /// *Slider = 設定の画面のスライダーの範囲と 1 押しの量（文字の速さの最大はノーウェイト = isNoWait）。
    pub type alias Rec = {
        version = Int32,
        bodySize = Float64,
        rubySize = Float64,
        nameSize = Float64,
        lineGap = Float64,
        advRows = Int32,
        nvlRows = Int32,
        cps = Float64,
        autoWait = Float64,
        masterVolume = Float64,
        ambienceVolume = Float64,
        seVolume = Float64,
        windowAlpha = Float64,
        autoPerChar = Float64,
        skipInterval = Float64,
        logMax = Int32,
        shakeSeconds = Float64,
        shakePx = Float64,
        shakes = Map[String, Shake],
        overlayStart = Float64,
        overlayLayer = Int32,
        fireflies = Int32,
        snow = Snow,
        creditsSpeed = Float64,
        toastSeconds = Float64,
        holdFadeSeconds = Float64,
        holdGiveUpSeconds = Float64,
        holdMarkSeconds = Float64,
        tapSlop = Float64,
        longPressSeconds = Float64,
        swipeMin = Float64,
        swipeSeconds = Float64,
        cpsSlider = Slider,
        autoWaitSlider = Slider,
        masterVolumeSlider = Slider,
        ambienceVolumeSlider = Slider,
        seVolumeSlider = Slider,
        windowAlphaSlider = Slider
    }

    /// <<fx snow>> の雪。count = 粒子の数、fallSpeed = 落ちる速さ（px/秒・粒子ごとに 0.6〜1.4 倍）、
    /// size = 粒子の半径（px・粒子ごとに 0.5〜1.3 倍）、sway = 横に揺れる幅（px）、fadeIn = 降り始めてから全部の粒子がそろうまでの秒、
    /// glow = 粒子の周りのにじみの濃さ（0〜1・明るい粒子ほど強い）、glowRadius = にじみの半径（粒子の半径の倍率）、
    /// twinkleEvery / twinkleSeconds / twinkleGain = 粒子が光を拾って明るくなる平均の間（秒・粒子ごとにばらつく）・1 回の長さ（秒）・にじみが強まる割合
    /// （光を拾うのは手前の大きな粒子と灯りの側の粒子）、
    /// warmPhotos = 灯りのある背景の写真の名前（novel.backdrops.json の photos）、warmFromX = 暖かくなり始める横の位置（画面の幅に対する割合・右端で一番強い）、
    /// warmColor = 暖かい色、warmStrength = 右端で色を近づける割合（0〜1）。
    pub type alias Snow = { count = Int32, fallSpeed = Float64, size = Float64, sway = Float64, fadeIn = Float64,
                            glow = Float64, glowRadius = Float64, twinkleEvery = Float64, twinkleSeconds = Float64, twinkleGain = Float64,
                            warmPhotos = List[String], warmFromX = Float64, warmColor = Color, warmStrength = Float64 }

    /// 揺れの強さ 1 つ。seconds = 揺れる秒（だんだん収まる）、px = 揺れ幅。
    pub type alias Shake = { seconds = Float64, px = Float64 }

    /// スライダーの下限・上限・1 押しの量。
    pub type alias Slider = { min = Float64, max = Float64, step = Float64 }

    /// 型検査が record を展開しないため、World が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.kind.json"

    /// コード側の既定値（assets/novel.kind.json と同じ値から出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1, bodySize = 22.0, rubySize = 11.0, nameSize = 19.0, lineGap = 14.0,
                  advRows = 3, nvlRows = 11, cps = 40.0, autoWait = 1.2, masterVolume = 1.0, ambienceVolume = 0.7, seVolume = 0.8, windowAlpha = 0.74,
                  autoPerChar = 0.04, skipInterval = 0.06, logMax = 120, shakeSeconds = 0.35, shakePx = 7.0,
                  shakes = Map.empty(), overlayStart = 0.0, overlayLayer = 900,
                  fireflies = 28, snow = snowDefaults(), creditsSpeed = 34.0, toastSeconds = 1.6,
                  holdFadeSeconds = 0.4, holdGiveUpSeconds = 20.0, holdMarkSeconds = 0.4,
                  tapSlop = 12.0, longPressSeconds = 0.65, swipeMin = 60.0, swipeSeconds = 0.5,
                  cpsSlider = { min = 10.0, max = 130.0, step = 10.0 }, autoWaitSlider = { min = 0.2, max = 4.0, step = 0.2 },
                  masterVolumeSlider = volume(), ambienceVolumeSlider = volume(), seVolumeSlider = volume(),
                  windowAlphaSlider = { min = 0.2, max = 1.0, step = 0.1 } })

    def snowDefaults(): Snow =
        { count = 120, fallSpeed = 28.0, size = 2.4, sway = 12.0, fadeIn = 1.5,
          glow = 0.08, glowRadius = 2.2, twinkleEvery = 8.0, twinkleSeconds = 0.45, twinkleGain = 0.7,
          warmPhotos = "studio_eaves" :: Nil, warmFromX = 0.6,
          warmColor = Color.hex("#ffd9a8") |> Option.getWithDefault({ r = 1.0, g = 0.85, b = 0.66 }), warmStrength = 0.3 }

    def snowOf(fallback: Snow, o: Map[String, Json]): Snow =
        let num = (key, v) -> JsonCodec.floatOr(key, v, o);
        { count = JsonCodec.intOr("count", fallback#count, o), fallSpeed = num("fallSpeed", fallback#fallSpeed),
          size = num("size", fallback#size), sway = num("sway", fallback#sway), fadeIn = num("fadeIn", fallback#fadeIn),
          glow = num("glow", fallback#glow), glowRadius = num("glowRadius", fallback#glowRadius),
          twinkleEvery = num("twinkleEvery", fallback#twinkleEvery), twinkleSeconds = num("twinkleSeconds", fallback#twinkleSeconds),
          twinkleGain = num("twinkleGain", fallback#twinkleGain),
          warmPhotos = Map.get("warmPhotos", o) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString)) |> Option.getWithDefault(fallback#warmPhotos),
          warmFromX = num("warmFromX", fallback#warmFromX),
          warmColor = Map.get("warmColor", o) |> Option.flatMap(JsonCodec.expectString) |> Option.flatMap(Color.hex) |> Option.getWithDefault(fallback#warmColor),
          warmStrength = num("warmStrength", fallback#warmStrength) }

    def shakeFrom(d: Rec, json: Json): Option[Shake] =
        JsonCodec.expectObject(json) |> Option.map(o -> { seconds = JsonCodec.floatOr("seconds", d#shakeSeconds, o), px = JsonCodec.floatOr("px", d#shakePx, o) })

    /// 強さを書かない <<shake>> の揺れ。
    pub def defaultShake(kind: Doc): Shake = let r = rec(kind); { seconds = r#shakeSeconds, px = r#shakePx }

    def volume(): Slider = { min = 0.0, max = 1.0, step = 0.1 }

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let num = (key, fallback) -> JsonCodec.floatOr(key, fallback, root);
        let int = (key, fallback) -> JsonCodec.intOr(key, fallback, root);
        let slider = (key, fallback: Slider) -> Map.get(key, root) |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(o -> { min = JsonCodec.floatOr("min", fallback#min, o), max = JsonCodec.floatOr("max", fallback#max, o),
                                 step = JsonCodec.floatOr("step", fallback#step, o) })
            |> Option.getWithDefault(fallback);
        let snow = Map.get("snow", root) |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(o -> snowOf(d#snow, o)) |> Option.getWithDefault(d#snow);
        Doc.Doc({ version = int("version", d#version),
                  bodySize = num("bodySize", d#bodySize), rubySize = num("rubySize", d#rubySize),
                  nameSize = num("nameSize", d#nameSize), lineGap = num("lineGap", d#lineGap),
                  advRows = int("advRows", d#advRows), nvlRows = int("nvlRows", d#nvlRows),
                  cps = num("cps", d#cps), autoWait = num("autoWait", d#autoWait),
                  masterVolume = num("masterVolume", d#masterVolume),
                  ambienceVolume = num("ambienceVolume", d#ambienceVolume), seVolume = num("seVolume", d#seVolume),
                  windowAlpha = num("windowAlpha", d#windowAlpha),
                  autoPerChar = num("autoPerChar", d#autoPerChar), skipInterval = num("skipInterval", d#skipInterval),
                  logMax = int("logMax", d#logMax),
                  shakeSeconds = num("shakeSeconds", d#shakeSeconds), shakePx = num("shakePx", d#shakePx),
                  shakes = Map.get("shakes", root) |> Option.flatMap(JsonCodec.decodeStringMap(shakeFrom(d))) |> Option.getWithDefault(d#shakes),
                  overlayStart = num("overlayStart", d#overlayStart), overlayLayer = int("overlayLayer", d#overlayLayer),
                  fireflies = int("fireflies", d#fireflies), snow = snow, creditsSpeed = num("creditsSpeed", d#creditsSpeed),
                  toastSeconds = num("toastSeconds", d#toastSeconds),
                  holdFadeSeconds = num("holdFadeSeconds", d#holdFadeSeconds),
                  holdGiveUpSeconds = num("holdGiveUpSeconds", d#holdGiveUpSeconds),
                  holdMarkSeconds = num("holdMarkSeconds", d#holdMarkSeconds),
                  tapSlop = num("tapSlop", d#tapSlop), longPressSeconds = num("longPressSeconds", d#longPressSeconds),
                  swipeMin = num("swipeMin", d#swipeMin), swipeSeconds = num("swipeSeconds", d#swipeSeconds),
                  cpsSlider = slider("cpsSlider", d#cpsSlider), autoWaitSlider = slider("autoWaitSlider", d#autoWaitSlider),
                  masterVolumeSlider = slider("masterVolumeSlider", d#masterVolumeSlider),
                  ambienceVolumeSlider = slider("ambienceVolumeSlider", d#ambienceVolumeSlider),
                  seVolumeSlider = slider("seVolumeSlider", d#seVolumeSlider),
                  windowAlphaSlider = slider("windowAlphaSlider", d#windowAlphaSlider) })

    /// 読む画面の 1 回の押しを分ける数。
    pub def gestureLimits(kind: Doc): Gesture.Limits =
        let r = rec(kind);
        { slop = r#tapSlop, longPressSeconds = r#longPressSeconds, swipeMin = r#swipeMin, swipeSeconds = r#swipeSeconds }

    /// 文字の速さがスライダーの最大か（= ノーウェイト。行を一度に全部出す）。
    pub def isNoWait(cps: Float64, kind: Doc): Bool = cps >= rec(kind)#cpsSlider#max

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
