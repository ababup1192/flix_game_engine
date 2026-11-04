// Splash — 起動画面 1 枚ぶんの絵を組み立てる。
//
// 読み込みの間、ウィンドウは出ているのに何も描かれない時間があると「固まった」ように見える。
// ここが出すのは、ロゴ・進み具合のゲージ・いま何をしているかの一行だけ。
//
// GL も時計も触らない純粋な組み立てなので、GL の準備しかできていない起動の最初（render_gl）と、
// ゲームの下ごしらえ中（engine_world）の両方から同じ絵を出せる。
//
// 文言は英語にしてある。組み込みフォント（BootFont）は ASCII しか持たない — 日本語まで
// 抱えると起動画面のためだけに埋め込みが数倍に膨らむ。
pub mod Splash {

    /// 起動画面 1 枚の見え方。
    ///   design   … 画面の設計サイズ（px）
    ///   atlas    … 組み込みフォント（BootFont.atlas()）
    ///   logoSize … ロゴのテクスチャの実寸。0 ならロゴを描かない
    ///   phase    … いま何をしているか（"loading fonts..."）
    ///   ratio    … 進み具合 0..1。None なら本数が分からない状態（ゲージは流れるバーになる）
    ///   turns    … バーの位置（1 周 = 1.0）
    pub type alias View = {
        design = Vec2.Vec2,
        atlas = FontAtlas,
        logoSize = Vec2.Vec2,
        phase = String,
        ratio = Option[Float64],
        turns = Float64
    }

    /// 組み込みの素材で埋めた見え方。フォントもロゴも決まっているので、
    /// 呼び側は「いま何をしているか」と「進み具合」だけを渡せばよい。
    pub def bootView(design: Vec2.Vec2, phase: String, ratio: Option[Float64], turns: Float64): View =
        let side = Int32.toFloat64(BootFont.logoSide());
        { design = design, atlas = BootFont.atlas(), logoSize = { x = side, y = side },
          phase = phase, ratio = ratio, turns = turns }

    /// 起動画面 1 枚を描画命令にする。
    pub def drawables(v: View): List[GameEngine.Drawable] =
        let scale = textScaleOf(v#design);
        let logoH = logoHeightOf(v);
        let lineH = lineHeightOf(v#atlas, scale);
        let gaugeH = Float64.max(2.0, 3.0 * scale);
        let gap = 4.0 * scale;

        // ロゴ・題字・ゲージ・一行 を縦に積んだ塊として、画面の真ん中に置く。
        let blockH = logoH + gap + lineH + gap * 2.0 + gaugeH + gap + lineH;
        let top = Float64.floor((v#design#y - blockH) / 2.0);
        let cx = Float64.floor(v#design#x / 2.0);

        let logoTop = top;
        let titleTop = logoTop + logoH + gap;
        let gaugeTop = titleTop + lineH + gap * 2.0;
        let phaseTop = gaugeTop + gaugeH + gap;

        List.flatten(
            (background(v#design) :: Nil)
            :: logoDrawables(v, cx, logoTop, logoH)
            :: label("Flix_GE", v#atlas, scale, cx, titleTop, brand(), 2)
            :: gauge(v, cx, gaugeTop, gaugeH, scale)
            :: label(v#phase, v#atlas, scale, cx, phaseTop, dim(), 2)
            :: Nil)

    /// 0..1 に収めた進み具合。本数が 0 以下なら None（＝まだ何本あるか分からない）。
    pub def clampRatio(done: Int32, total: Int32): Option[Float64] =
        if (total <= 0) None
        else Some(Float64.max(0.0, Float64.min(1.0, Int32.toFloat64(done) / Int32.toFloat64(total))))

    /// 流れるバーの位置。1 秒で 1 周する。
    pub def turnsOf(elapsedSec: Float64): Float64 =
        elapsedSec - Float64.floor(elapsedSec)

    // ── 部品 ──────────────────────────────────────────────────

    def background(design: Vec2.Vec2): GameEngine.Drawable =
        box({ x = 0.0, y = 0.0 }, design, backdrop(), 1.0, 0)

    def logoDrawables(v: View, cx: Float64, top: Float64, logoH: Float64): List[GameEngine.Drawable] =
        if (v#logoSize#x <= 0.0 or v#logoSize#y <= 0.0) Nil
        else {
            let w = logoH * v#logoSize#x / v#logoSize#y;
            DrawCmd.make({
              texture  = BootFont.logoTextureName(),
              position = { x = Float64.floor(cx - w / 2.0), y = top },
              scale    = { x = w / v#logoSize#x, y = logoH / v#logoSize#y },
              rotation = 0.0,
              color    = white(),
              alpha    = 1.0,
              centered = false,
              uvOffset = { x = 0.0, y = 0.0 },
              uvScale  = { x = 1.0, y = 1.0 },
              zIndex   = 2,
              style    = None,
              clip     = None,
              blend    = DrawCmd.BlendMode.Normal,
              mask     = Nil }) :: Nil
        }

    /// 進み具合のゲージ。本数が分かっていれば左から溜まり、分からなければバーが流れる。
    def gauge(v: View, cx: Float64, top: Float64, h: Float64, scale: Float64): List[GameEngine.Drawable] =
        let w = Float64.floor(Float64.min(v#design#x - 16.0 * scale, v#design#x * 0.6));
        let left = Float64.floor(cx - w / 2.0);
        let track = box({ x = left, y = top }, { x = w, y = h }, white(), 0.18, 1);
        let fill = match v#ratio {
            case Some(r) =>
                let fw = Float64.floor(w * r);
                if (fw < 1.0) Nil
                else box({ x = left, y = top }, { x = fw, y = h }, white(), 1.0, 2) :: Nil
            case None =>
                let bw = Float64.floor(w * 0.25);
                let x = left + Float64.floor((w - bw) * v#turns);
                box({ x = x, y = top }, { x = bw, y = h }, white(), 1.0, 2) :: Nil
        };
        track :: fill

    def label(text: String, atlas: FontAtlas, scale: Float64, cx: Float64, top: Float64,
              color: Color, z: Int32): List[GameEngine.Drawable] =
        if (String.isEmpty(text)) Nil
        else
            Text.make(text, atlas, atlas#fontSize * scale)
                |> Text.setHorizontalAlignment(HorizontalAlignment.Center)
                |> Text.mapVisual(Visual.setColor(color) >> Visual.setZIndex(z))
                |> (t -> Text.toDrawables(t, { x = cx, y = top }))

    def box(pos: Vec2.Vec2, size: Vec2.Vec2, color: Color, alpha: Float64,
            z: Int32): GameEngine.Drawable =
        DrawCmd.make({
          texture  = "",
          position = pos,
          scale    = size,
          rotation = 0.0,
          color    = color,
          alpha    = alpha,
          centered = false,
          uvOffset = { x = 0.0, y = 0.0 },
          uvScale  = { x = 1.0, y = 1.0 },
          zIndex   = z,
          style    = Some(DrawCmd.defaultStyle(color)),
          clip     = None,
          blend    = DrawCmd.BlendMode.Normal,
          mask     = Nil })

    // ── 寸法と色 ──────────────────────────────────────────────

    /// 字とゲージの太さの倍率。ビットマップフォントなので整数倍にしか広げない。
    def textScaleOf(design: Vec2.Vec2): Float64 =
        Float64.max(1.0, Float64.floor(design#y / 200.0))

    /// ロゴの高さ。素の一辺の 1/4・1/2・等倍・2 倍から、画面の 3 割に収まる最大を選ぶ
    /// （半端な倍率で縮めるとドットが濁るため）。
    def logoHeightOf(v: View): Float64 =
        if (v#logoSize#y <= 0.0) 0.0
        else {
            let limit = v#design#y * 0.3;
            let base = v#logoSize#y;
            ((base / 4.0) :: (base / 2.0) :: base :: (base * 2.0) :: Nil)
                |> List.filter(h -> h <= limit)
                |> List.foldLeft((acc, h) -> Float64.max(acc, h), base / 4.0)
        }

    def lineHeightOf(atlas: FontAtlas, scale: Float64): Float64 =
        (atlas#ascent + atlas#descent + atlas#lineGap) * scale

    def backdrop(): Color = { r = 0.043, g = 0.055, b = 0.071 }
    def white(): Color = { r = 1.0, g = 1.0, b = 1.0 }
    def brand(): Color = { r = 0.62, g = 0.80, b = 0.95 }
    def dim(): Color = { r = 0.55, g = 0.58, b = 0.64 }
}
