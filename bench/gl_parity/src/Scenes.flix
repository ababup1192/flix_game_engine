// 突き合わせに使う場面（scene）の宣言。GL と SoftRaster の両方が同じこの列を描き出す。
//
// A 段階（バイト一致を主張する層）の scene 規約:
//   1. 整数座標・整数寸法・整数倍率のみ（小数の丸めの差を測るのは B 段階の仕事）。
//      倍率 = texel→画素の拡大率が整数、の意味（sprite の scale 値そのものではない —
//      blitRegion の scale が 0.5 でも、貼り先/切り出し元の比が整数なら規約内）
//   2. 色は k/255 で表せる値のみ・alpha は 1.0（8bit に落ちない中間値は正規化で ±1 が出うる）
//   3. 縞は軸平行（dir=1/2）と市松だけ。45° 縞・角丸・枠は GL だけ AA が掛かるので入れない
//   4. 時刻は固定値（アニメ無し — 2 回描き出して同じ絵になることが決定性検証の前提）
mod Scenes {

    use fge::{Color, DrawCmd, Light, RawDraw, Render, RenderTarget, ShaderDoc, Vec2}

    // 寸法の権威は整数側 — Float 側を権威にすると Int へ戻す丸めが要る。
    pub def designWi(): Int32 = 320
    pub def designHi(): Int32 = 180

    pub def designW(): Float64 = Int32.toFloat64(designWi())
    pub def designH(): Float64 = Int32.toFloat64(designHi())

    /// pass 名の一覧。pass は常に design 寸なので、寸法引きはこの名前だけで足りる。
    pub def passNames(): List[String] =
        all() |> List.flatMap(sc -> sc#passes) |> List.map(p -> p#name)

    /// 画面口（FLIX_GE_FRAME_SHOT）で撮るか、ターゲット口（GlReadback 直呼び）で撮るか。
    pub enum ShotVia with Eq {
        case ViaTarget
        case ViaScreen
    }

    pub type alias Scene = {
        name = String,
        via = ShotVia,
        passes = List[Render.Pass],
        items = List[Render.PlacedItem]
    }

    pub def all(): List[Scene] =
        boxes() :: spriteNearest() :: passPaste() :: texField() :: lightMap() :: radial() :: Nil

    /// 8bit の値そのままの色（k/255）。A 段階の規約 2 をこの入口で守る。
    def c8(r: Int32, g: Int32, b: Int32): Color =
        { r = f255(r), g = f255(g), b = f255(b) }

    def f255(k: Int32): Float64 =
        Int32.toFloat64(k) / 255.0

    def at(x: Float64, y: Float64, item: Render.Item): Render.PlacedItem =
        { at = { x = x, y = y }, item = item }

    // ── scene 1: 単色 box の重なり（塗り・並び順・ブレンド式・軸平行縞・市松）──

    def boxes(): Scene =
        { name = "boxes", via = ShotVia.ViaTarget, passes = Nil, items =
            // 左上の白枠なし赤箱 = 向きの目印（gl/soft で同じ隅に出なければ上下反転を疑う）
            at(8.0, 8.0, RawDraw.box({ x = 16.0, y = 16.0 }, c8(255, 64, 64), 10)) ::
            // zIndex 交差: 青(z1) の上に 緑(z2)
            at(40.0, 30.0, RawDraw.box({ x = 80.0, y = 60.0 }, c8(40, 80, 200), 1)) ::
            at(80.0, 60.0, RawDraw.box({ x = 80.0, y = 60.0 }, c8(40, 180, 90), 2)) ::
            // Add: 暗色ベース + 加算（飽和しない値で式そのものを見る）
            at(180.0, 20.0, RawDraw.box({ x = 60.0, y = 40.0 }, c8(60, 60, 60), 1)) ::
            at(200.0, 30.0, RawDraw.box({ x = 60.0, y = 40.0 }, c8(120, 80, 40), 2)
                |> Render.blended(DrawCmd.BlendMode.Add)) ::
            // Multiply: 白ベース × 灰（積が 8bit で割り切れる組）
            at(180.0, 90.0, RawDraw.box({ x = 60.0, y = 40.0 }, c8(255, 255, 255), 1)) ::
            at(200.0, 100.0, RawDraw.box({ x = 60.0, y = 40.0 }, c8(100, 100, 100), 2)
                |> Render.blended(DrawCmd.BlendMode.Multiply)) ::
            // 軸平行の縞（横 dir=1・縦 dir=2）と市松
            at(20.0, 130.0, RawDraw.box({ x = 48.0, y = 40.0 }, c8(200, 60, 140), 3)
                |> Render.striped({ color = c8(255, 255, 255), alpha = 1.0,
                                    width = 4.0, period = 8.0, dir = 1 })) ::
            at(80.0, 130.0, RawDraw.box({ x = 48.0, y = 40.0 }, c8(60, 140, 200), 3)
                |> Render.striped({ color = c8(255, 255, 255), alpha = 1.0,
                                    width = 4.0, period = 8.0, dir = 2 })) ::
            at(140.0, 130.0, RawDraw.box({ x = 48.0, y = 40.0 }, c8(220, 180, 60), 3)
                |> Render.checker({ color = c8(0, 0, 0), alpha = 1.0, cell = 4.0 })) ::
            Nil }

    // ── scene 2: 市松アトラスの sprite（UV 解決と NEAREST・反転・整数倍率）──

    /// アトラスの辺長（assets/atlas.png と対で決める）。
    pub def atlasSide(): Float64 = 16.0

    def atlasSprite(spec: { srcPos = Vec2.Vec2, srcSize = Vec2.Vec2, sx = Float64, sy = Float64,
                            fH = Bool, fV = Bool, z = Int32 }): Render.Item =
        Render.Item.Sprite({ texture = "atlas", tint = { r = 1.0, g = 1.0, b = 1.0 },
            alpha = 1.0, scale = { x = spec#sx, y = spec#sy }, rotation = 0.0, centered = true,
            flipH = spec#fH, flipV = spec#fV,
            regionRect = Some({ position = spec#srcPos, size = spec#srcSize }),
            zIndex = spec#z, blend = DrawCmd.BlendMode.Normal, maskPolys = Nil })

    def fullAtlas(sx: Float64, fH: Bool, fV: Bool, z: Int32): Render.Item =
        atlasSprite({ srcPos = { x = 0.0, y = 0.0 }, srcSize = { x = 16.0, y = 16.0 },
                      sx = sx, sy = sx, fH = fH, fV = fV, z = z })

    def spriteNearest(): Scene =
        { name = "spriteNearest", via = ShotVia.ViaTarget, passes = Nil, items =
            // 等倍の全面（regionRect = 全面）
            at(40.0, 40.0, fullAtlas(1.0, false, false, 1)) ::
            // 左上 8x8 の区画を 2 倍
            at(80.0, 40.0, atlasSprite({ srcPos = { x = 0.0, y = 0.0 }, srcSize = { x = 8.0, y = 8.0 },
                                         sx = 2.0, sy = 2.0, fH = false, fV = false, z = 1 })) ::
            // 右上 8x8 の区画を 3 倍
            at(120.0, 40.0, atlasSprite({ srcPos = { x = 8.0, y = 0.0 }, srcSize = { x = 8.0, y = 8.0 },
                                          sx = 3.0, sy = 3.0, fH = false, fV = false, z = 1 })) ::
            // 反転 3 種（白 texel の目印が移る隅で判別できる）
            at(170.0, 40.0, fullAtlas(2.0, true, false, 1)) ::
            at(220.0, 40.0, fullAtlas(2.0, false, true, 1)) ::
            at(270.0, 40.0, fullAtlas(2.0, true, true, 1)) ::
            // 右下区画 4 倍と、角に掛からない途中区画（uvOffset が端でない値）
            at(80.0, 120.0, atlasSprite({ srcPos = { x = 8.0, y = 8.0 }, srcSize = { x = 8.0, y = 8.0 },
                                          sx = 4.0, sy = 4.0, fH = false, fV = false, z = 1 })) ::
            at(170.0, 120.0, atlasSprite({ srcPos = { x = 4.0, y = 4.0 }, srcSize = { x = 8.0, y = 8.0 },
                                           sx = 2.0, sy = 2.0, fH = false, fV = false, z = 1 })) ::
            Nil }

    // ── scene 3: ターゲットに描いて本編へ NEAREST 拡大で貼る ──

    def passPaste(): Scene =
        let p3: Render.Pass = { name = "p3", clear = RenderTarget.LoadOp.Clear(c8(16, 24, 40)), items =
            at(0.0, 0.0, RawDraw.box({ x = 40.0, y = 20.0 }, c8(200, 60, 60), 1)) ::
            at(40.0, 0.0, RawDraw.box({ x = 40.0, y = 20.0 }, c8(60, 200, 60), 1)) ::
            at(0.0, 20.0, RawDraw.box({ x = 80.0, y = 25.0 }, c8(60, 60, 200), 1)) ::
            at(10.0, 5.0, RawDraw.box({ x = 8.0, y = 8.0 }, c8(255, 255, 255), 2)) ::
            Nil };
        { name = "passPaste", via = ShotVia.ViaScreen, passes = p3 :: Nil, items =
            // 左上 80x45 を 2 倍（整数倍）で画面中央へ
            Render.blitRegion({ name = "p3", design = { x = designW(), y = designH() },
                                src = { position = { x = 0.0, y = 0.0 }, size = { x = 80.0, y = 45.0 } },
                                at = { x = 160.0, y = 90.0 }, size = { x = 160.0, y = 90.0 }, z = 2 }) ::
            Nil }

    // ── scene 4: pass に模様を描き出し、シェーダー面の tex 場が素通しで読む（Wave D の主役）──

    /// pass を r/g/b 素通しで読む Spec。テクスチャ値以降の float 合成をほぼ無くし、
    /// 標本の量子化 4 点（NEAREST・CLAMP・8bit 正規化・上下逆の吸収）だけを見る。
    def passthroughSpec(texName: String): ShaderDoc.Spec =
        { name = "parity_passthrough",
          cycleRate = 0.0,
          bindings = Nil,
          out = ShaderDoc.Out.Fill({
              shade = ShaderDoc.Shade.Rgb({
                  r = ShaderDoc.Field.Tex({ name = texName, chan = ShaderDoc.TexChan.R }),
                  g = ShaderDoc.Field.Tex({ name = texName, chan = ShaderDoc.TexChan.G }),
                  b = ShaderDoc.Field.Tex({ name = texName, chan = ShaderDoc.TexChan.B }) }),
              alpha = ShaderDoc.Field.Const(1.0) }) }

    def texField(): Scene =
        let p4: Render.Pass = { name = "p4", clear = RenderTarget.LoadOp.Clear(c8(0, 0, 0)), items =
            at(0.0, 0.0, RawDraw.box({ x = 160.0, y = 90.0 }, c8(200, 40, 40), 1)) ::
            at(160.0, 0.0, RawDraw.box({ x = 160.0, y = 90.0 }, c8(40, 200, 40), 1)) ::
            at(0.0, 90.0, RawDraw.box({ x = 160.0, y = 90.0 }, c8(40, 40, 200), 1)) ::
            at(160.0, 90.0, RawDraw.box({ x = 160.0, y = 90.0 }, c8(200, 200, 40), 1)) ::
            // 白の目印（左上）と市松（texel が細かく変わる領域）
            at(8.0, 8.0, RawDraw.box({ x = 16.0, y = 16.0 }, c8(255, 255, 255), 2)) ::
            at(120.0, 60.0, RawDraw.box({ x = 80.0, y = 60.0 }, c8(90, 90, 90), 2)
                |> Render.checker({ color = c8(30, 30, 30), alpha = 1.0, cell = 4.0 })) ::
            Nil };
        { name = "texField", via = ShotVia.ViaScreen, passes = p4 :: Nil, items =
            Render.shaderFill(passthroughSpec("p4"),
                { position = { x = 0.0, y = 0.0 }, size = { x = designW(), y = designH() } },
                0.0, 1) ::
            Nil }

    // ── scene 5: 光マップの配管（Light.lightMapPass → Multiply blit。Wave F の主役）──
    //
    // A 段階に載せるのは配管（環境光 → pass 内 Add → Multiply 貼り）だけ:
    //   - 影ポリゴンは載せない（斜め縁は GL だけ AA が掛かる — 規約 3）
    //   - 放射（Render.lightAt の組み込み放射テクスチャ）はここでは Add の単色 box で
    //     代役し、放射そのものは radial scene が単体で見る（配管と放射で不一致の源を
    //     切り分けたまま保つ）
    //   - Multiply 貼りの下地は白 1 面（Multiply が恒等になり光マップ値がそのまま画面へ通る）
    // 影の正しさは純関数テスト（TestLight）と feature_lab の目視が担う。

    def lightMap(): Scene =
        let white = c8(255, 255, 255);
        let cfg: Light.LightMapConfig = {
            lights = Nil,
            occluders = Nil,
            viewport = { x = designW(), y = designH() },
            ambient = c8(16, 16, 24),
            shadowStrength = 1.0,
            extrudeLength = 2000.0,
            passName = "lm",
            z = 5 };
        // 灯りの代役 = Add の単色 box 2 枚（重なりの領域で Add の積み上がりも見る）。
        // lightMapPass の items へ追記できることは公式の拡張口（Pass はただのレコード）。
        let base = Light.lightMapPass(cfg);
        let lamps =
            at(48.0, 45.0, RawDraw.box({ x = 128.0, y = 90.0 }, c8(96, 96, 64), 10)
                |> Render.blended(DrawCmd.BlendMode.Add)) ::
            at(144.0, 45.0, RawDraw.box({ x = 128.0, y = 90.0 }, c8(64, 80, 96), 10)
                |> Render.blended(DrawCmd.BlendMode.Add)) ::
            Nil;
        let p = { items = List.append(base#items, lamps) | base };
        { name = "lightmap", via = ShotVia.ViaScreen,
          passes = p :: Nil,
          items =
            at(0.0, 0.0, RawDraw.box({ x = designW(), y = designH() }, white, 1)) ::
            Light.lightMapOverlay(cfg) ::
            Nil }

    // ── scene 6: 組み込み放射テクスチャ（Render.lightAt / darkAt）──
    //
    // 一致が成り立つ土台 = 放射テクスチャの alpha が常に 255（RadialBuiltin）。
    //   - lightAt（Add）は d+s の整数の足し算になり、下地が何色でも一致する。
    //     重ね置き（Add の積み上がり）と飽和クランプもここで一緒に見る
    //   - darkAt（Multiply）の d×s/255 が割り切れるのは下地が白か黒のときだけ。
    //     下地をその 2 色に限り、光の当たった画素へ掛からないよう z 順を
    //     darkAt → lightAt にする（Add は何にでも exact に乗るが、逆は成り立たない）
    //   - radius = 128 で拡大率 1.0（texel→画素が等倍）。tint 白・strength 1.0 のみ
    //     （中間の tint / strength は float 乗算が入り 8bit に落ちない — 規約 2）
    //   - 四角の左上は画面内（負にしない）。SoftRaster の出力矩形の丸め
    //     （SoftRaster.ri = 0 方向切り捨て）が負座標で 1px 内側にずれ、貼りが等倍で
    //     なくなる — 右下への はみ出しは正の座標のままなので等倍が保たれる

    def radial(): Scene =
        { name = "radial", via = ShotVia.ViaTarget, passes = Nil, items =
            // 右側の白下地（darkAt の Multiply が exact になる面）
            at(192.0, 0.0, RawDraw.box({ x = 128.0, y = 180.0 }, c8(255, 255, 255), 2)) ::
            // 翳り: 白と黒の下地にだけ掛かる
            Render.darkAt({ at = { x = 256.0, y = 128.0 }, radius = 128.0,
                            strength = 1.0, z = 3 }) ::
            // 明かり 2 枚（重なりで Add の積み上がり・白下地に掛かる所で飽和クランプ）
            Render.lightAt({ at = { x = 128.0, y = 128.0 }, radius = 128.0,
                             color = c8(255, 255, 255), strength = 1.0, z = 4 }) ::
            Render.lightAt({ at = { x = 174.0, y = 158.0 }, radius = 128.0,
                             color = c8(255, 255, 255), strength = 1.0, z = 5 }) ::
            Nil }
}
