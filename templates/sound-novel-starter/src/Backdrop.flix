// Backdrop — 背景の写真を、時間帯の色でぼかして塗る宣言シェーダー（ShaderDoc.Spec）をコードで組む。
// 実機は GPU（ShaderGen が GLSL にする）、描き出しは CPU（ShaderEval）が同じ Spec から同じ絵を作る。
//
// 1 画素の色の作り方（チャンネル c ごと。数は BackdropDoc の Grade）:
//   c0 = 写真をぼかして読んだ c（ShaderDoc の blur の節。半径は blur × (1 + focusPull × (1 − 進み))）
//   l  = 明るさ 0.299r + 0.587g + 0.114b
//   c1 = l + saturation × (c0 − l)                    彩度
//   c2 = c1 × exposure × tint.c + lift.c               露出と色味（昼の写真を夕方・夜・朝へ）
//   c3 = c2 + sky.c × skyStrength × (1 − smoothstep(0, skyReach, v))   上から差す光
//   c4 = c3 × (1 − vignette × smoothstep(0.45, 1.05, 中心からの距離))    四隅を落とす
// 不透明さは「切り替えの進み」（面の t。0 → 1）。前の背景の上に新しい背景を重ね、進みで現す = クロスフェード。
// WhyNot: 進みを Const で Spec に埋め込まない — Spec が毎フレーム変わると、実機はシェーダーを組み直し続ける。
//         t（uTime）で渡せば、写真と時間帯の組ごとにシェーダーは 1 本で済む。
mod Backdrop {
    use fge::{Color, Rect2, Render, ShaderDoc}
    use fge::ShaderDoc.{BinOp, Field, Shade, Out, TexChan}

    /// 写真 1 枚を時間帯の色で塗る Spec。key = 写真と時間帯の組の名前（Spec の name になる）。
    /// WhyNot: name を写真だけから作らない —— 実機は name でシェーダーを覚えるので、同じ写真を別の時間帯で
    ///         同じフレームに描く（セーブの枠のサムネ）と、毎フレーム組み直しになる。
    pub def specOf(key: String, photo: BackdropDoc.Photo, grade: BackdropDoc.Grade): ShaderDoc.Spec =
        let progress = Field.Un({ op = ShaderDoc.UnOp.Sat, of = Field.Time({ scale = 1.0, offset = k(0.0) }) });
        let amount = add(k(1.0), mul(k(grade#focusPull), Field.Un({ op = ShaderDoc.UnOp.OneMinus, of = progress })));
        let blur = chan -> Field.TexBlur({ name = photo#texture, chan = chan,
                                           radius = { x = grade#blur, y = grade#blur * aspect() },
                                           taps = ShaderDoc.blurTaps(grade#taps), amount = amount });
        let luma = add(add(mul(k(0.299), Field.Ref("r")), mul(k(0.587), Field.Ref("g"))), mul(k(0.114), Field.Ref("b")));
        let skyFade = Field.Un({ op = ShaderDoc.UnOp.OneMinus,
                                 of = Field.Smoothstep({ lo = 0.0, hi = Float64.max(0.01, grade#skyReach),
                                                         of = Field.Uv({ axis = ShaderDoc.Axis.V }) }) });
        let vignette = sub(k(1.0), mul(k(grade#vignette),
            Field.Smoothstep({ lo = 0.45, hi = 1.05, of = Field.RadialAspect({ cx = 0.5, cy = 0.5, aspect = aspect() }) })));
        let channel = (name, tint, lift, sky) -> {
            let c1 = add(Field.Ref("l"), mul(k(grade#saturation), sub(Field.Ref(name), Field.Ref("l"))));
            let c2 = add(mul(c1, k(grade#exposure * tint)), k(lift));
            let c3 = add(c2, mul(k(sky * grade#skyStrength), Field.Ref("sky")));
            mul(c3, Field.Ref("vig"))
        };
        { name = "backdrop_${key}", cycleRate = 0.0,
          bindings = ("r", blur(TexChan.R)) :: ("g", blur(TexChan.G)) :: ("b", blur(TexChan.B)) ::
                     ("l", luma) :: ("sky", skyFade) :: ("vig", vignette) :: Nil,
          out = Out.Fill({
              shade = Shade.Rgb({ r = channel("r", grade#tint#r, grade#lift#r, grade#sky#r),
                                  g = channel("g", grade#tint#g, grade#lift#g, grade#sky#g),
                                  b = channel("b", grade#tint#b, grade#lift#b, grade#sky#b) }),
              alpha = progress }) }

    /// 背景の面。progress = 切り替えの進み（0 = まだ見えない・1 = 現れ切った）。
    pub def surface(spec: ShaderDoc.Spec, rect: Rect2.Rect2, progress: Float64, z: Int32): Render.PlacedItem =
        Render.shaderFill(spec, rect, Float64.max(0.0, Float64.min(1.0, progress)), z)

    /// 画面の横÷縦（ぼかしの縦の半径を横とそろえ、四隅の落ち方を丸くする）。
    def aspect(): Float64 = World.width() / World.height()

    def k(v: Float64): Field = Field.Const(v)

    def add(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Add, a = a, b = b })

    def sub(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Sub, a = a, b = b })

    def mul(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Mul, a = a, b = b })

    /// 色を使わない時の地（写真が無い・読めない時に敷く夜の色）。
    pub def groundColor(): Color = { r = 0.04, g = 0.05, b = 0.08 }
}
