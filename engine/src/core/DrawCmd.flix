// DrawCmd — 1 フレームぶんの描画命令の型。
//
// フロント（engine のシーングラフ）が組み立て、バックエンド（render_gl の GL 描画・
// engine_tools の SoftRaster）が受け取って絵にする。両者が同じ型を見るための共有語彙。
// engine（契約層）に置くことで、ゲーム・フロント・各バックエンドが 1 つの定義を共有する。

pub mod DrawCmd {

    /// ピクセルの重ね方（ブレンドモード）。
    /// Normal = ふつうの半透明合成。Add = 光が重なるように明るく足す（グロー・炎・魔法）。
    /// Multiply = 下の色に掛けて暗く沈める（影・暗くするオーバーレイ。2D 光源の土台）。
    /// バックエンド（GL / SoftRaster）は同じ式で合成する:
    ///   Add      : out = min(1, dst + src×srcAlpha)
    ///   Multiply : out = dst×(1 − srcAlpha×(1 − src))  （srcAlpha=1 で dst×src・白は素通し・黒は黒）
    pub enum BlendMode with Eq, Order, ToString {
        case Normal
        case Add
        case Multiply
    }

    /// 角丸＋枠線スタイル。`Drawable.style = Some(..)` かつ texture="" のとき、
    /// 単色矩形を「塗り＋枠＋角丸＋AA」で 1 フラグメント描画する。長さはすべて px。
    ///
    /// stripe* は塗り領域に重ねる斜線ハッチ（CSS の repeating-linear-gradient 相当）。
    /// `stripeWidth <= 0` または `stripeAlpha <= 0` でハッチ無効＝塗りのみ。
    /// stripePeriod は縞の周期 px、stripeWidth は縞 1 本の幅 px。
    /// checker* は塗り領域に重ねる市松のタイル。`checkerCell <= 0` または
    /// `checkerAlpha <= 0` で無効。重なる順は 塗り → 縞 → 市松 → 枠。
    ///
    /// payload は Color を r, g, b のフィールドへ展開してフラットに持つ — Drawable と同じ理由で、
    /// 毎フレーム数千個作る値ではレコードの入れ子は確保量が大きすぎるため。
    /// 構築の入口は `makeStyle`（名前付きで安全）と `styleFromParts`（毎フレーム大量に通る
    /// 変換用 — spec レコードを作らない）と `defaultStyle`（無飾の既定値）。部分更新は
    /// `withCornerRadius` / `withBorder` / `withStripe` / `withChecker`。位置引数の並びに
    /// 触るのはこのモジュールの中だけ。毎フレーム大量に通る読み出しだけ、match で
    /// 全フィールドを一度に受けてよい。分解の写経元（変数名はこの並びで統一する）:
    ///   let DrawCmd.BoxStyle.BoxStyle(rad, bw, br, bg, bb, ba,
    ///                                 sr, sg, sb, sa, sw, sp, sd,
    ///                                 kr, kg, kb, ka, kc) = st;
    pub enum BoxStyle {
        case BoxStyle(
            Float64,                    // cornerRadius
            Float64,                    // borderWidth
            Float64, Float64, Float64,  // borderColor.r, g, b
            Float64,                    // borderAlpha
            Float64, Float64, Float64,  // stripeColor.r, g, b
            Float64,                    // stripeAlpha
            Float64,                    // stripeWidth
            Float64,                    // stripePeriod
            Int32,                      // stripeDir: 0 = 斜め 45° / 1 = 横縞 / 2 = 縦縞
            Float64, Float64, Float64,  // checkerColor.r, g, b
            Float64,                    // checkerAlpha（0 で無効）
            Float64                     // checkerCell（セル一辺 px・0 で無効）
        )
    }

    /// BoxStyle の全フィールドを名前で持つレコード（`makeStyle` の入力・`styleToSpec` の出力）。
    pub type alias BoxStyleSpec = {
        cornerRadius = Float64,
        borderWidth  = Float64,
        borderColor  = Color,
        borderAlpha  = Float64,
        stripeColor  = Color,
        stripeAlpha  = Float64,
        stripeWidth  = Float64,
        stripePeriod = Float64,
        stripeDir    = Int32,
        checkerColor = Color,
        checkerAlpha = Float64,
        checkerCell  = Float64
    }

    /// 名前付きで安全に組む入口（テスト・部分上書き・めったに呼ばれない構築用）。
    /// 毎フレーム大量に通る変換は spec レコードを作らない `styleFromParts` を使う。
    pub def makeStyle(spec: BoxStyleSpec): BoxStyle =
        BoxStyle.BoxStyle(
            spec#cornerRadius,
            spec#borderWidth,
            spec#borderColor#r, spec#borderColor#g, spec#borderColor#b,
            spec#borderAlpha,
            spec#stripeColor#r, spec#stripeColor#g, spec#stripeColor#b,
            spec#stripeAlpha,
            spec#stripeWidth,
            spec#stripePeriod,
            spec#stripeDir,
            spec#checkerColor#r, spec#checkerColor#g, spec#checkerColor#b,
            spec#checkerAlpha,
            spec#checkerCell)

    /// 毎フレーム大量に通る変換用の入口。Color は値のまま受けて中で r, g, b に展開する。
    /// 隣り合う Float64 の取り違えはコンパイルが通ってしまうので、並びはフィールドの
    /// 宣言順（corner → border → stripe → checker）で固定し、呼び手は名前付きの引数を
    /// 組めない毎フレーム経路だけに限る。
    pub def styleFromParts(cornerRadius: Float64, borderWidth: Float64,
                           borderColor: Color, borderAlpha: Float64,
                           stripeColor: Color, stripeAlpha: Float64,
                           stripeWidth: Float64, stripePeriod: Float64, stripeDir: Int32,
                           checkerColor: Color, checkerAlpha: Float64,
                           checkerCell: Float64): BoxStyle =
        BoxStyle.BoxStyle(
            cornerRadius,
            borderWidth,
            borderColor#r, borderColor#g, borderColor#b,
            borderAlpha,
            stripeColor#r, stripeColor#g, stripeColor#b,
            stripeAlpha,
            stripeWidth,
            stripePeriod,
            stripeDir,
            checkerColor#r, checkerColor#g, checkerColor#b,
            checkerAlpha,
            checkerCell)

    /// 全フィールドを名前付きレコードへ展開する（部分更新と、めったに呼ばれない経路の
    /// 読み出し用）。毎フレーム大量に通る経路ではレコードを作り直すぶん高くつくので、
    /// そこでは match で直接分解する。
    pub def styleToSpec(st: BoxStyle): BoxStyleSpec =
        let BoxStyle.BoxStyle(rad, bw, br, bg, bb, ba,
                              sr, sg, sb, sa, sw, sp, sd,
                              kr, kg, kb, ka, kc) = st;
        { cornerRadius = rad,
          borderWidth  = bw,
          borderColor  = {r = br, g = bg, b = bb},
          borderAlpha  = ba,
          stripeColor  = {r = sr, g = sg, b = sb},
          stripeAlpha  = sa,
          stripeWidth  = sw,
          stripePeriod = sp,
          stripeDir    = sd,
          checkerColor = {r = kr, g = kg, b = kb},
          checkerAlpha = ka,
          checkerCell  = kc }

    /// 何も飾らない素の BoxStyle（枠・縞・市松すべて無効）。色系は塗りと同じ base を入れておく。
    /// フィールドを足すときはここへ既定値を 1 つ足せば、組み立て側は上書きだけで済む。
    pub def defaultStyle(base: Color): BoxStyle =
        BoxStyle.BoxStyle(
            0.0, 0.0,
            base#r, base#g, base#b, 0.0,
            base#r, base#g, base#b, 0.0, 0.0, 0.0, 0,
            base#r, base#g, base#b, 0.0, 0.0)

    /// 枠線の太さ（px）だけ読む（バックエンドのはみ出し見積もり用）。
    pub def borderWidthOf(st: BoxStyle): Float64 =
        let BoxStyle.BoxStyle(_rad, bw, _br, _bg, _bb, _ba,
                              _sr, _sg, _sb, _sa, _sw, _sp, _sd,
                              _kr, _kg, _kb, _ka, _kc) = st;
        bw

    // ── BoxStyle の部分更新（元を変えず新しい BoxStyle を返す）─────────
    // Drawable の with* と同じ理由で match で受けて enum を直接組み直す。

    /// 角丸半径を差し替える。
    pub def withCornerRadius(radius: Float64, st: BoxStyle): BoxStyle =
        let BoxStyle.BoxStyle(_rad, bw, br, bg, bb, ba,
                              sr, sg, sb, sa, sw, sp, sd,
                              kr, kg, kb, ka, kc) = st;
        BoxStyle.BoxStyle(radius, bw, br, bg, bb, ba,
                          sr, sg, sb, sa, sw, sp, sd,
                          kr, kg, kb, ka, kc)

    /// 枠線（色・太さ・濃さ）を差し替える。
    pub def withBorder(color: Color, width: Float64, alpha: Float64, st: BoxStyle): BoxStyle =
        let BoxStyle.BoxStyle(rad, _bw, _br, _bg, _bb, _ba,
                              sr, sg, sb, sa, sw, sp, sd,
                              kr, kg, kb, ka, kc) = st;
        BoxStyle.BoxStyle(rad, width, color#r, color#g, color#b, alpha,
                          sr, sg, sb, sa, sw, sp, sd,
                          kr, kg, kb, ka, kc)

    /// 縞（色・濃さ・幅・周期・向き）を差し替える。
    pub def withStripe(color: Color, alpha: Float64, width: Float64, period: Float64,
                       dir: Int32, st: BoxStyle): BoxStyle =
        let BoxStyle.BoxStyle(rad, bw, br, bg, bb, ba,
                              _sr, _sg, _sb, _sa, _sw, _sp, _sd,
                              kr, kg, kb, ka, kc) = st;
        BoxStyle.BoxStyle(rad, bw, br, bg, bb, ba,
                          color#r, color#g, color#b, alpha, width, period, dir,
                          kr, kg, kb, ka, kc)

    /// 市松（色・濃さ・セル一辺）を差し替える。
    pub def withChecker(color: Color, alpha: Float64, cell: Float64, st: BoxStyle): BoxStyle =
        let BoxStyle.BoxStyle(rad, bw, br, bg, bb, ba,
                              sr, sg, sb, sa, sw, sp, sd,
                              _kr, _kg, _kb, _ka, _kc) = st;
        BoxStyle.BoxStyle(rad, bw, br, bg, bb, ba,
                          sr, sg, sb, sa, sw, sp, sd,
                          color#r, color#g, color#b, alpha, cell)

    /// px の長さを持つフィールド（角丸・枠線幅・縞の幅と周期・市松のセル）を一括で factor 倍する。
    /// zoom やスケール適用が同じ表を見るための共通ヘルパ。
    pub def scalePx(factor: Float64, st: BoxStyle): BoxStyle =
        let BoxStyle.BoxStyle(rad, bw, br, bg, bb, ba,
                              sr, sg, sb, sa, sw, sp, sd,
                              kr, kg, kb, ka, kc) = st;
        BoxStyle.BoxStyle(rad * factor, bw * factor, br, bg, bb, ba,
                          sr, sg, sb, sa, sw * factor, sp * factor, sd,
                          kr, kg, kb, ka, kc * factor)

    /// clip 矩形（design px・スクリーン空間）を出力ピクセルの整数矩形 (x0, y0, x1, y1) へ写す
    /// （top-left 原点・floor 量子化）。GL の glScissor と SoftRaster の setClip が同じ画素集合を
    /// 見るための共通式 — y の反転（GL は左下原点）は GL 側だけが行う。
    /// 端のちらつきを避けたい呼び側は clip 矩形を整数 design px で作ること。
    pub def clipPixels(scale: {scaleX = Float64, scaleY = Float64}, clip: Rect2.Rect2): (Int32, Int32, Int32, Int32) =
        let f = v -> Num.floorInt(v);
        (f(clip#position#x * scale#scaleX),
         f(clip#position#y * scale#scaleY),
         f((clip#position#x + clip#size#x) * scale#scaleX),
         f((clip#position#y + clip#size#y) * scale#scaleY))

    /// スプライト 1 つ分の描画命令（zIndex 順にソートして描画される）。
    /// `style = Some(..)` かつ texture="" のとき角丸スタイル矩形として描く。
    /// `clip` はスクリーン空間（design px）の切り抜き矩形 — None なら切らない。
    /// バックエンドはその矩形の外のピクセルを描かない（GL: scissor / SoftRaster: setClip）。
    /// `blend` はピクセルの重ね方（既定 Normal — 従来と同じ半透明合成）。
    /// `mask` は多角形の型抜き（空 = 抜かない）。頂点は表示クアッドのローカル座標
    /// （design px・原点 = クアッドの左上・回転前）で、rotation / 反転（scale の符号）は
    /// クアッドと同じ変換が掛かる — 形を 1 回定義すれば回転は rotation に任せられる。
    /// エッジは GL のステンシルも Java2D の clip も AA なしのハードエッジ（docs/backend-parity.md）。
    /// グリフ（font_ テクスチャ）には効かない。
    /// payload は Vec2 / Color を x, y / r, g, b のフィールドへ展開してフラットに持つ — 入れ子のオブジェクトを
    /// フィールドごとに持つ形にしないのは、毎フレーム数千個作る値では確保量が大きすぎるため。
    /// 構築の入口は 2 つ: `make`（名前付きで安全 — テスト・部分上書き・めったに呼ばれない構築）と
    /// `fromParts`（毎フレーム大量に通る変換用 — spec レコードを作らない）。位置引数の並びに
    /// 触るのはこのモジュールの中だけ（隣どうしの Float64 の取り違えはコンパイルが通ってしまう）。
    /// 部分更新は `with*` か `toSpec` + `make`。毎フレーム大量に通る読み出しだけ、match で
    /// 全フィールドを一度に受けてよい。分解の写経元（変数名はこの並びで統一する）:
    ///   let Drawable.Drawable(tex, px, py, sx, sy, rot,
    ///                         cr, cg, cb, a, cen,
    ///                         uox, uoy, usx, usy, z,
    ///                         style, clip, blend, mask) = d;
    pub enum Drawable {
        case Drawable(
            String,                // texture
            Float64, Float64,      // position.x, position.y
            Float64, Float64,      // scale.x, scale.y
            Float64,               // rotation
            Float64, Float64, Float64, // color.r, color.g, color.b
            Float64,               // alpha
            Bool,                  // centered
            Float64, Float64,      // uvOffset.x, uvOffset.y
            Float64, Float64,      // uvScale.x, uvScale.y
            Int32,                 // zIndex
            Option[BoxStyle],      // style
            Option[Rect2.Rect2],   // clip
            BlendMode,             // blend
            List[List[Vec2.Vec2]]  // mask
        )
    }

    /// Drawable の全フィールドを名前で持つレコード（`make` の入力・`toSpec` の出力）。
    pub type alias DrawableSpec = {
        texture = String,
        position = Vec2.Vec2,
        scale = Vec2.Vec2,
        rotation = Float64,
        color = Color,
        alpha = Float64,
        centered = Bool,
        uvOffset = Vec2.Vec2,
        uvScale = Vec2.Vec2,
        zIndex = Int32,
        style = Option[BoxStyle],
        clip = Option[Rect2.Rect2],
        blend = BlendMode,
        mask = List[List[Vec2.Vec2]]
    }

    /// 名前付きで安全に組む入口（テスト・部分上書き・めったに呼ばれない構築用）。
    /// 毎フレーム大量に通る変換は spec レコードを作らない `fromParts` を使う。
    pub def make(spec: DrawableSpec): Drawable =
        Drawable.Drawable(
            spec#texture,
            spec#position#x, spec#position#y,
            spec#scale#x, spec#scale#y,
            spec#rotation,
            spec#color#r, spec#color#g, spec#color#b,
            spec#alpha,
            spec#centered,
            spec#uvOffset#x, spec#uvOffset#y,
            spec#uvScale#x, spec#uvScale#y,
            spec#zIndex,
            spec#style,
            spec#clip,
            spec#blend,
            spec#mask)

    /// 毎フレーム大量に通る変換用の入口。`make` の spec レコードを作らないのは、
    /// 構築 1 回ごとに入れ物のレコード一式を確保することになり、enum へ平置きした
    /// 節約がそこで消えるため。Vec2 / Color は値のまま受けて中で x, y / r, g, b に展開する —
    /// 引数の型が互いに違うので、並びの取り違えがコンパイルを通るのは
    /// (position, scale) と (uvOffset, uvScale) の 2 ペアだけ。
    pub def fromParts(texture: String, position: Vec2.Vec2, scale: Vec2.Vec2,
                      rotation: Float64, color: Color, alpha: Float64, centered: Bool,
                      uvOffset: Vec2.Vec2, uvScale: Vec2.Vec2, zIndex: Int32,
                      style: Option[BoxStyle], clip: Option[Rect2.Rect2],
                      blend: BlendMode, mask: List[List[Vec2.Vec2]]): Drawable =
        Drawable.Drawable(
            texture,
            position#x, position#y,
            scale#x, scale#y,
            rotation,
            color#r, color#g, color#b,
            alpha,
            centered,
            uvOffset#x, uvOffset#y,
            uvScale#x, uvScale#y,
            zIndex,
            style,
            clip,
            blend,
            mask)

    /// 全フィールドを名前付きレコードへ展開する（部分更新と、めったに呼ばれない経路の
    /// 読み出し用）。毎フレーム大量に通る経路ではレコードを作り直すぶん高くつくので、
    /// そこでは match で直接分解する。
    pub def toSpec(d: Drawable): DrawableSpec =
        let Drawable.Drawable(tex, px, py, sx, sy, rot,
                              cr, cg, cb, a, cen,
                              uox, uoy, usx, usy, z,
                              style, clip, blend, mask) = d;
        { texture = tex,
          position = {x = px, y = py},
          scale = {x = sx, y = sy},
          rotation = rot,
          color = {r = cr, g = cg, b = cb},
          alpha = a,
          centered = cen,
          uvOffset = {x = uox, y = uoy},
          uvScale = {x = usx, y = usy},
          zIndex = z,
          style = style,
          clip = clip,
          blend = blend,
          mask = mask }

    // ── 読み用アクセサ ──────────────────────────────────────────
    // Vec2 / Color を返す物は呼ぶたびにレコードを 1 個作る。毎フレーム大量に通る経路では
    // 使わず、match で全フィールドを一度に受けること。

    pub def textureOf(d: Drawable): String =
        let Drawable.Drawable(tex, _px, _py, _sx, _sy, _rot, _cr, _cg, _cb, _a, _cen,
                              _uox, _uoy, _usx, _usy, _z, _style, _clip, _blend, _mask) = d;
        tex

    pub def positionOf(d: Drawable): Vec2.Vec2 =
        let Drawable.Drawable(_tex, px, py, _sx, _sy, _rot, _cr, _cg, _cb, _a, _cen,
                              _uox, _uoy, _usx, _usy, _z, _style, _clip, _blend, _mask) = d;
        {x = px, y = py}

    pub def scaleOf(d: Drawable): Vec2.Vec2 =
        let Drawable.Drawable(_tex, _px, _py, sx, sy, _rot, _cr, _cg, _cb, _a, _cen,
                              _uox, _uoy, _usx, _usy, _z, _style, _clip, _blend, _mask) = d;
        {x = sx, y = sy}

    pub def rotationOf(d: Drawable): Float64 =
        let Drawable.Drawable(_tex, _px, _py, _sx, _sy, rot, _cr, _cg, _cb, _a, _cen,
                              _uox, _uoy, _usx, _usy, _z, _style, _clip, _blend, _mask) = d;
        rot

    pub def colorOf(d: Drawable): Color =
        let Drawable.Drawable(_tex, _px, _py, _sx, _sy, _rot, cr, cg, cb, _a, _cen,
                              _uox, _uoy, _usx, _usy, _z, _style, _clip, _blend, _mask) = d;
        {r = cr, g = cg, b = cb}

    pub def alphaOf(d: Drawable): Float64 =
        let Drawable.Drawable(_tex, _px, _py, _sx, _sy, _rot, _cr, _cg, _cb, a, _cen,
                              _uox, _uoy, _usx, _usy, _z, _style, _clip, _blend, _mask) = d;
        a

    pub def zIndexOf(d: Drawable): Int32 =
        let Drawable.Drawable(_tex, _px, _py, _sx, _sy, _rot, _cr, _cg, _cb, _a, _cen,
                              _uox, _uoy, _usx, _usy, z, _style, _clip, _blend, _mask) = d;
        z

    pub def styleOf(d: Drawable): Option[BoxStyle] =
        let Drawable.Drawable(_tex, _px, _py, _sx, _sy, _rot, _cr, _cg, _cb, _a, _cen,
                              _uox, _uoy, _usx, _usy, _z, style, _clip, _blend, _mask) = d;
        style

    pub def clipOf(d: Drawable): Option[Rect2.Rect2] =
        let Drawable.Drawable(_tex, _px, _py, _sx, _sy, _rot, _cr, _cg, _cb, _a, _cen,
                              _uox, _uoy, _usx, _usy, _z, _style, clip, _blend, _mask) = d;
        clip

    pub def blendOf(d: Drawable): BlendMode =
        let Drawable.Drawable(_tex, _px, _py, _sx, _sy, _rot, _cr, _cg, _cb, _a, _cen,
                              _uox, _uoy, _usx, _usy, _z, _style, _clip, blend, _mask) = d;
        blend

    pub def maskOf(d: Drawable): List[List[Vec2.Vec2]] =
        let Drawable.Drawable(_tex, _px, _py, _sx, _sy, _rot, _cr, _cg, _cb, _a, _cen,
                              _uox, _uoy, _usx, _usy, _z, _style, _clip, _blend, mask) = d;
        mask

    // ── 部分更新（元を変えず新しい Drawable を返す）─────────────────
    // 実装は match で全フィールドを受けて enum を直接組み直す。`toSpec` + レコード更新 +
    // `make` の形にしないのは、毎フレーム全 Drawable が通る経路（drawInto の clip 刻み等）で
    // 部分更新 1 回ごとに中間レコードを 2 周ぶん確保することになるため。
    // 位置引数の並びに触る関数はこのモジュールの外に増やさない。

    /// clip 矩形を差し替える。
    pub def withClip(clip: Option[Rect2.Rect2], d: Drawable): Drawable =
        let Drawable.Drawable(tex, px, py, sx, sy, rot,
                              cr, cg, cb, a, cen,
                              uox, uoy, usx, usy, z,
                              style, _clip, blend, mask) = d;
        Drawable.Drawable(tex, px, py, sx, sy, rot,
                          cr, cg, cb, a, cen,
                          uox, uoy, usx, usy, z,
                          style, clip, blend, mask)

    /// color と zIndex を差し替える（テキストの文字色・重なり順の上書き用）。
    pub def withTintAndZIndex(color: Color, zIndex: Int32, d: Drawable): Drawable =
        let Drawable.Drawable(tex, px, py, sx, sy, rot,
                              _cr, _cg, _cb, a, cen,
                              uox, uoy, usx, usy, _z,
                              style, clip, blend, mask) = d;
        Drawable.Drawable(tex, px, py, sx, sy, rot,
                          color#r, color#g, color#b, a, cen,
                          uox, uoy, usx, usy, zIndex,
                          style, clip, blend, mask)

    /// scale を差し替える。
    pub def withScale(scale: Vec2.Vec2, d: Drawable): Drawable =
        let Drawable.Drawable(tex, px, py, _sx, _sy, rot,
                              cr, cg, cb, a, cen,
                              uox, uoy, usx, usy, z,
                              style, clip, blend, mask) = d;
        Drawable.Drawable(tex, px, py, scale#x, scale#y, rot,
                          cr, cg, cb, a, cen,
                          uox, uoy, usx, usy, z,
                          style, clip, blend, mask)

    /// scale と mask を一緒に差し替える（カメラの zoom は型抜きの形にも掛ける必要がある）。
    pub def withScaleAndMask(scale: Vec2.Vec2, mask: List[List[Vec2.Vec2]], d: Drawable): Drawable =
        let Drawable.Drawable(tex, px, py, _sx, _sy, rot,
                              cr, cg, cb, a, cen,
                              uox, uoy, usx, usy, z,
                              style, clip, blend, _mask) = d;
        Drawable.Drawable(tex, px, py, scale#x, scale#y, rot,
                          cr, cg, cb, a, cen,
                          uox, uoy, usx, usy, z,
                          style, clip, blend, mask)

    /// position と rotation を一緒に差し替える（グリフを文字列の置き場所のまわりに回す用）。
    pub def withPositionAndRotation(position: Vec2.Vec2, rotation: Float64, d: Drawable): Drawable =
        let Drawable.Drawable(tex, _px, _py, sx, sy, _rot,
                              cr, cg, cb, a, cen,
                              uox, uoy, usx, usy, z,
                              style, clip, blend, mask) = d;
        Drawable.Drawable(tex, position#x, position#y, sx, sy, rotation,
                          cr, cg, cb, a, cen,
                          uox, uoy, usx, usy, z,
                          style, clip, blend, mask)

    /// uvOffset と uvScale を一緒に差し替える（レンダーターゲットの上下反転用）。
    pub def withUv(uvOffset: Vec2.Vec2, uvScale: Vec2.Vec2, d: Drawable): Drawable =
        let Drawable.Drawable(tex, px, py, sx, sy, rot,
                              cr, cg, cb, a, cen,
                              _uox, _uoy, _usx, _usy, z,
                              style, clip, blend, mask) = d;
        Drawable.Drawable(tex, px, py, sx, sy, rot,
                          cr, cg, cb, a, cen,
                          uvOffset#x, uvOffset#y, uvScale#x, uvScale#y, z,
                          style, clip, blend, mask)

    /// タイルマップ 1 タイル分のインスタンスデータ。tilemap loader が組み立て、
    /// バックエンドの `initTileBuffer` が GPU へアップロードする素材。
    pub type alias TileInstance = {
        px    = Vec2.Vec2,
        uvOff = Vec2.Vec2,
        uvSc  = Vec2.Vec2,
        alpha = Float64,
        tint  = Color
    }

    /// タイルマップのインスタンス描画命令（1 draw call で全タイル）。
    /// `tileScale` はカメラの zoom を反映するスクリーン倍率で、zoom 未指定時は (1, 1)。
    /// `tileVaoId` は `initTileBuffer` が返したバックエンドのハンドル（中身はバックエンドだけが知る）。
    /// blend は持たない = タイルは常に Normal（光り物・暗くするオーバーレイの実需要はエンティティ側。必要になったら拡張）。
    pub type alias TileMapRenderCmd = {
        textureName = String,
        tileSize    = Float64,
        position    = Vec2.Vec2,
        tileScale   = Vec2.Vec2,
        color       = Color,
        zIndex      = Int32,
        tileVaoId   = GpuHandle.TileVao,
        tileCount   = Int32
    }

    /// 頂点 1 つぶんの色と濃さ。`PolygonRenderCmd#grad` が頂点列と同じ順で持つ。
    pub type alias VertexTint = {
        color = Color,
        alpha = Float64
    }

    /// 展開済みの色つき頂点（位置＋色＋濃さ）。バックエンドが三角形の中で線形に混ぜる単位。
    pub type alias GradVertex = {
        pos   = Vec2.Vec2,
        color = Color,
        alpha = Float64
    }

    /// 凸多角形の塗り潰し命令。vertices はスクリーン px に変換済みの頂点列を渡す。
    /// `clip` は Drawable と同じスクリーン空間の切り抜き矩形（None なら切らない）。
    /// `blend` はピクセルの重ね方（既定 Normal — 従来と同じ半透明合成）。
    /// `grad` は頂点ごとの色（vertices と同じ長さ・同じ順）。Some のとき color は
    /// 補いにだけ使い、面の中で頂点色が滑らかに混ざる（空・水面・光の帯のグラデ）。
    /// 展開が扇割りのため grad つきは凸の形で使うこと。None = color 一色（従来どおり）。
    /// 注意: Some(Nil) も grad 経路で描かれる（色は全頂点 color 補い＝一色だが、
    /// SoftRaster の縁の写りが None の AA 塗りと違う）。一色なら None を渡すこと。
    pub type alias PolygonRenderCmd = {
        vertices = List[Vec2.Vec2],
        color    = Color,
        alpha    = Float64,
        zIndex   = Int32,
        clip     = Option[Rect2.Rect2],
        blend    = BlendMode,
        grad     = Option[List[VertexTint]]
    }

    /// grad つき多角形を「色つき頂点の三角形列」に展開する。GL と SoftRaster が同じ
    /// 割り方・同じ補間の入力を見るための共通式で、grad = None なら空を返す
    /// （単色は従来の耳切り経路のまま — 絵を 1 バイトも変えないため）。
    /// 扇割り（頂点 0 を要）なので凸専用 — 凹ませたい形は呼び側で凸に割って並べる。
    /// 色列が頂点より短い分は color で補い、長い分は捨てる（fail-open — 落として
    /// 消すより一色で出るほうが調整中に気づける）。濃さは頂点 α × 全体 α を掛け合わせ済み。
    pub def gradTriangles(p: PolygonRenderCmd): List[(GradVertex, GradVertex, GradVertex)] =
        match p#grad {
            case None        => Nil
            case Some(tints) => fanTriangles(gradVertices(tints, p))
        }

    /// vertices と grad の色列を 1 本に綴じる（不足は color / α=1 で補う）。
    /// 掛け合わせは Float32 で行う — バックエンド（GL の頂点属性・SoftRaster の重み付き平均）が
    /// Float32 で受け取るので、掛ける前に落とさないと丸めの回数がバックエンドとずれる。
    def gradVertices(tints: List[VertexTint], p: PolygonRenderCmd): List[GradVertex] =
        let fallback: VertexTint = { color = p#color, alpha = 1.0 };
        let mulA = (a, b) -> Float32.toFloat64(RenderUtil.f32(a) * RenderUtil.f32(b));
        let folded = List.foldLeft((acc, v) -> {
            let (outRev, rest) = acc;
            let (tint, rest2) = match rest {
                case t :: more => (t, more)
                case Nil       => (fallback, Nil)
            };
            (({ pos = v, color = tint#color, alpha = mulA(tint#alpha, p#alpha) }: GradVertex) :: outRev, rest2)
        }, ((Nil: List[GradVertex]), tints), p#vertices);
        let (outRev, _) = folded;
        List.reverse(outRev)

    /// 頂点 0 を要にした扇割り（v0, v1, v2), (v0, v2, v3), …。凸の形なら面を過不足なく覆う。
    def fanTriangles(vs: List[GradVertex]): List[(GradVertex, GradVertex, GradVertex)] =
        match vs {
            case v0 :: v1 :: rest =>
                List.zip(v1 :: rest, rest) |> List.map(pair -> { let (a, b) = pair; (v0, a, b) })
            case _ => Nil
        }

    /// 静的多角形バッファのキャッシュキー。ゲームは「静的な中身を決める全入力」
    /// （フロア id・テーマ・作り直しの世代番号など）をこの 1 文字列にまとめて渡す。
    /// エンジンはキーが前フレームと同じなら生成した VBO を使い回し、変わったら古い VBO を
    /// 解放して作り直す（テクスチャを名前で 1 度だけ GPU に上げるのと同じ隠蔽）。
    /// ゲームは GL ハンドルも無効化ロジックも持たない — キーの組み立てだけが責務。
    pub type alias StaticKey = String

    /// 1 フレームぶんの静的レイヤー描画依頼。`renderCommands` の第 4 チャンネルに載せる。
    /// key が変わったときだけ polys を評価して GPU へ生成し直す（同じキーの間は頂点の作り直し・
    /// アップロードが毎フレームから消える）ので、polys は「作り方」を包んだ純粋関数で渡す
    /// — 副作用を持たせないことで renderCommands の op を効果多相にせずに済む。
    /// viewOffset / viewScale / halfDesign はカメラの平行移動・ズームを頂点シェーダの uniform
    /// で当てる値（カメラ無しなら世界座標そのままになる値を渡す）。
    /// SoftRaster は GPU バッファを持たないので polys を毎回描くだけ（キャッシュを見ない）。
    pub type alias StaticLayerCmd = {
        key        = StaticKey,
        polys      = Unit -> List[PolygonRenderCmd],
        viewOffset = Vec2.Vec2,
        viewScale  = Vec2.Vec2,
        halfDesign = Vec2.Vec2
    }

    /// エンジン内部でキャッシュした 1 レンジの目次（バックエンドだけが使う）。
    /// 入力の多角形を z 昇順に三角形化して 1 本の VBO に連続配置したときの、
    /// z / blend / 切り抜き矩形ごとの (開始頂点, 頂点数)。zIndex で動的アイテムと同じ
    /// z 安定ソート列に並べ、重なり順を壊さない。
    pub type alias StaticPolyMeta = {
        first  = Int32,
        count  = Int32,
        blend  = BlendMode,
        clip   = Option[Rect2.Rect2],
        zIndex = Int32
    }

}
