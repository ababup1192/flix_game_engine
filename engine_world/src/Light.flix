// Light — 簡易2D光源から見せる絵の列を導く純関数。光は状態を持たない値（位置・半径・色・ハロの強さ）。
// maskSprite（Multiply専用の暗くするオーバーレイ）と haloSprite（Add専用の暖色グロー）は RadialGlow が生成した
// 別規約のテクスチャで、Light はその2枚をどこに・どれだけ拡大して置くかだけを決める。
pub mod Light {

    /// 簡易2D光源1個の値。at=位置、radius=光の届く目安半径、color=光の色、
    /// halo=Addハロの強さ0..1。
    pub type alias Light = { at = Vec2.Vec2, radius = Float64, color = Color, halo = Float64 }

    /// RadialGlow で生成した既定テクスチャの参照一式。sprite 名・元 px サイズ・穴の広さは
    /// 「描き出す側（RadialGlow の呼び出し）」と「読む側（items のスケール計算）」で
    /// 値が揃っていないと穴のサイズがずれるため、1 レコードにまとめて受け渡しの分裂を防ぐ。
    pub type alias GlowAssets = {
        maskSprite = String, maskSourceSize = Float64, maskHoleFrac = Float64,
        haloSprite = String, haloSourceSize = Float64
    }

    /// RadialGlow の既定値で生成したときの GlowAssets（sprite名は描き出し側の慣習
    /// "glow_mask"/"glow_halo" 固定）。別名のテクスチャを生成したゲームは自分で
    /// GlowAssets を組み立てて items に渡せばよい。
    /// maskHoleFrac=0.5 は engine_tools（描き出し専用パッケージ、engine_world から依存できない）
    /// の RadialGlow.defaultHoleFrac() と同じ値 — 生成する側を変えたらここも合わせて直すこと。
    pub def defaultGlowAssets(): GlowAssets =
        { maskSprite = "glow_mask", maskSourceSize = 512.0, maskHoleFrac = 0.5,
          haloSprite = "glow_halo", haloSourceSize = 256.0 }

    /// シーン全体の光源設定（items の唯一の入口）。lights は 0〜N 個、occluders は
    /// 遮蔽ポリゴンの列（Shadow.occluderOf 系で作る絶対座標の頂点列）。
    /// darkness/z は暗くするオーバーレイ・影・ハロの土台を貫く共通値（オーバーレイの縁と影の濃さを合わせて
    /// 「同じ暗闇の一部」に見せるため、光源ごとにばらけさせない）。
    /// rimWidth/rimStrength は Shadow.itemsFor に渡す照り返しフチのノブ、
    /// haloDiameterFactor はハロの見た目直径を「2×radius（穴の直径）」からさらに
    /// 拡大する倍率（1.0 で拡大なし。既定は defaultHaloDiameterFactor）— 穴の縁ぴったりに
    /// ハロを合わせると光が穴の輪郭で唐突に途切れて見えるため、ひとまわり大きく余す。
    /// lights が2個以上のとき occluders を渡しても影は描かれない（items の doc を参照）。
    pub type alias SceneLightConfig = {
        lights = List[Light], occluders = List[List[Vec2.Vec2]],
        viewport = Vec2.Vec2, glow = GlowAssets,
        darkness = Float64, z = Int32,
        rimWidth = Float64, rimStrength = Float64, haloDiameterFactor = Float64
    }

    /// haloDiameterFactor の既定の目安。穴（2×radius）よりひとまわり大きい見た目にする
    /// （ホラー演出での実運用値。ちょうど穴の縁で光が切れると不自然に見える）。
    pub def defaultHaloDiameterFactor(): Float64 = 1.25

    /// シーンの光源一式を絵にする唯一の入口。lights が
    ///   - 0 個なら全面オーバーレイのみ（multiLightItems を lights=Nil で呼ぶのと同じ）
    ///   - 1 個なら真の穴あきオーバーレイ+ハロ（singleLightItems）に、occluders があれば
    ///     Shadow.itemsFor の影・フチを合成する（呼び側の手動 append が不要になる）
    ///   - 2 個以上なら全面オーバーレイ+各光のハロ（multiLightItems）の近似に振り分ける
    /// **複数光源では影が出ない**（items 自身は今も全面オーバーレイ+ハロの近似のまま。occluders を
    /// 渡しても黙って無視される — 松明集団シーンのような「影は要らないが灯りだけ複数欲しい」
    /// 用途向けの割り切り。複数光源で影まで欲しいときは光マップ方式
    /// （`lightMapPass` / `lightMapOverlay`）を使う）。
    /// 最小の呼び出し例（灯り 1 個・影なし）:
    ///   Light.items({ lights = { at = fireAt, radius = 48.0, color = warmOrange, halo = 0.6 } :: Nil,
    ///                 occluders = Nil, viewport = designSize, glow = Light.defaultGlowAssets(),
    ///                 darkness = 0.8, z = 99, rimWidth = 6.0, rimStrength = 0.35,
    ///                 haloDiameterFactor = Light.defaultHaloDiameterFactor() })
    pub def items(cfg: SceneLightConfig): List[Render.PlacedItem] =
        match cfg#lights {
            case light :: Nil => singleWithShadow(cfg, light)
            case lights       => multiLightItems({
                lights = lights, darkness = cfg#darkness, viewport = cfg#viewport,
                haloSprite = cfg#glow#haloSprite, haloSourceSize = cfg#glow#haloSourceSize, z = cfg#z })
        }

    /// items の単一光源ぶん: singleLightItems（GlowAssets → SingleLightConfig の変換は
    /// ここだけが知っていればよい）にハロの追加拡大を掛け、occluders があれば
    /// Shadow.itemsFor の影を同じ darkness/z で合成する。
    def singleWithShadow(cfg: SceneLightConfig, light: Light): List[Render.PlacedItem] =
        let lightItems = singleLightItems({
            light = light, viewport = cfg#viewport,
            maskSprite = cfg#glow#maskSprite, maskSourceSize = cfg#glow#maskSourceSize,
            maskHoleFrac = cfg#glow#maskHoleFrac,
            haloSprite = cfg#glow#haloSprite, haloSourceSize = cfg#glow#haloSourceSize,
            darkness = cfg#darkness, z = cfg#z })
            |> growHalo(cfg#haloDiameterFactor);
        let shadows = if (List.isEmpty(cfg#occluders))
                List.empty()
            else
                Shadow.itemsFor(light, cfg#occluders,
                    { darkness = cfg#darkness, z = cfg#z, extrudeLength = Shadow.infiniteExtrude(),
                      rimWidth = cfg#rimWidth, rimStrength = cfg#rimStrength });
        List.append(lightItems, shadows)

    /// singleLightItems が返す列の末尾（ハロ）だけを factor 倍する（先頭のオーバーレイ・周囲黒帯は
    /// そのまま）。末尾がハロであることは singleLightItems の実装順序に依存するので、
    /// この関数を単独で公開はせず items の内部でだけ使う。
    def growHalo(factor: Float64, items: List[Render.PlacedItem]): List[Render.PlacedItem] =
        match List.reverse(items) {
            case Nil          => Nil
            case halo :: rest =>
                let grown = { item = Render.scaled(factor, halo#item) | halo };
                List.reverse(grown :: rest)
        }

    // ── 低レベル口（通常は items を使う。影や haloDiameterFactor が要らず、
    //    穴あきオーバーレイ+ハロだけをピンポイントに組みたいときに使う） ──

    /// singleLightItems の設定。maskSprite/haloSprite は RadialGlow で生成したテクスチャ名、
    /// maskSourceSize/haloSourceSize はそれぞれの元 px サイズ（正方形前提）。
    /// maskHoleFrac は maskSprite を生成した RadialGlow.maskCurveWithHole の holeFrac と
    /// 同じ値（既定は RadialGlow.defaultHoleFrac()）— 「穴の実寸半径 = light#radius」を
    /// 逆算するのに使うため、生成する側と読む側で値が揃っていないと穴のサイズがずれる。
    /// darkness は mask 全体の暗さ0..1（1で穴の外が完全な黒。既定0.95）— 周囲4枚の黒帯と
    /// 同じ値を使うことで、mask の縁（完全減衰）と黒帯の濃度が連続する。
    /// z はオーバーレイ→ハロの土台（cfg#z がオーバーレイ、cfg#z + 1 がハロ）。
    /// 背景・目印など「穴の中に見せたい景色」は cfg#z 未満の zIndex に置くこと
    /// （Render.blended は自分より奥＝小さい zIndex にしか効かない）。
    pub type alias SingleLightConfig = {
        light = Light, viewport = Vec2.Vec2,
        maskSprite = String, maskSourceSize = Float64, maskHoleFrac = Float64,
        haloSprite = String, haloSourceSize = Float64,
        darkness = Float64,
        z = Int32
    }

    /// 単一光源の真の穴あき描画。中心の穴あきオーバーレイ（Multiply, maskSprite）を「穴の実寸半径が
    /// light#radius になる」倍率へ引き伸ばして光の位置に1枚 → 四辺を敷き詰める黒帯4枚
    /// （mask 正方形の外側を隙間なく覆う。mask の縁と同じ darkness で連続に見える）→
    /// 色付きAddハロ（haloSprite, tint=light#color, alpha=light#halo）を光の半径ぶんに
    /// 拡大して同じ位置に重ねる。
    pub def singleLightItems(cfg: SingleLightConfig): List[Render.PlacedItem] =
        let scale = maskScale(cfg#light#radius, cfg#maskSourceSize, cfg#maskHoleFrac);
        let maskSize = cfg#maskSourceSize * scale;
        let mask = { at = cfg#light#at,
                      item = Render.sprite(cfg#maskSprite, cfg#z)
                          |> Render.scaled(scale)
                          |> Render.blended(DrawCmd.BlendMode.Multiply)
                          |> Render.fade(cfg#darkness) };
        let surround = surroundBoxes(cfg#light#at, maskSize, cfg#viewport, cfg#darkness, cfg#z);
        let halo = { at = cfg#light#at,
                      item = Render.sprite(cfg#haloSprite, cfg#z + 1)
                          |> tintHalo(cfg#light)
                          |> Render.scaled(haloScale(cfg#light#radius, cfg#haloSourceSize))
                          |> Render.blended(DrawCmd.BlendMode.Add) };
        mask :: List.append(surround, halo :: Nil)

    /// オーバーレイの拡大倍率。「穴の実寸半径 = light#radius」になる倍率のみ
    /// （maskCurveWithHole の平坦部 holeFrac が画像半径に占める割合なので、
    /// holeFrac × 画像半径 × scale = radius から逆算する）。画面対角線カバレッジの
    /// 下限は持たない — mask 正方形の外側は surroundBoxes が敷く黒帯が担うため、
    /// 「穴半径=radius」の不変条件を radius の大小に関わらず常に守れる。
    def maskScale(radius: Float64, maskSourceSize: Float64, holeFrac: Float64): Float64 =
        radius / (holeFrac * maskSourceSize / 2.0)

    /// mask 正方形（一辺 maskSize、at 中心）の外側を上下左右4枚の黒 box（Multiply,
    /// alpha=darkness）で隙間なく敷く。mask の縁（maskCurveWithHole の t=1 相当、
    /// 完全減衰=1−darkness）と黒帯（同じ darkness）の濃度が揃うことで、正方形の輪郭が
    /// 見えずに済む。viewport の外側まで大きめに伸ばし、画面のどの隅・どんな光位置でも
    /// 黒帯が画面全体を覆い切るようにする。
    def surroundBoxes(at: Vec2.Vec2, maskSize: Float64, viewport: Vec2.Vec2,
                       darkness: Float64, z: Int32): List[Render.PlacedItem] =
        let pad = Vec2.length(viewport);
        let half = maskSize / 2.0;
        let blackBox = (center: Vec2.Vec2, size: Vec2.Vec2) ->
            RawDraw.boxAt(center, size, { r = 0.0, g = 0.0, b = 0.0 }, z)
                |> (placed -> { item = Render.blended(DrawCmd.BlendMode.Multiply, placed#item)
                                    |> Render.fade(darkness) | placed });
        let wideW = maskSize + pad * 2.0;
        let tallH = maskSize + pad * 2.0;
        // 上下は mask 正方形と同じ横幅、左右は上下の面も覆う縦幅（四隅の抜けを防ぐ）。
        blackBox({ x = at#x, y = at#y - half - pad / 2.0 }, { x = wideW, y = pad })            ::  // 上
        blackBox({ x = at#x, y = at#y + half + pad / 2.0 }, { x = wideW, y = pad })            ::  // 下
        blackBox({ x = at#x - half - pad / 2.0, y = at#y }, { x = pad, y = tallH })            ::  // 左
        blackBox({ x = at#x + half + pad / 2.0, y = at#y }, { x = pad, y = tallH })            ::  // 右
        Nil

    /// ハロを光の半径ぶんの直径へ拡大する倍率。
    def haloScale(radius: Float64, haloSourceSize: Float64): Float64 =
        radius * 2.0 / haloSourceSize

    /// ハロに光の色と強さを乗せる（Sprite の tint と alpha を差し替える薄い修飾）。
    def tintHalo(light: Light, item: Render.Item): Render.Item =
        match item {
            case Render.Item.Sprite(s) =>
                Render.Item.Sprite({ tint = light#color, alpha = light#halo | s })
            case other => other
        }

    // ── 低レベル口（通常は items を使う。多灯シーンで occluders 判定を挟まず
    //    直接呼びたいときに使う） ──

    /// multiLightItems の設定。darkness は全面オーバーレイの濃さ0..1（1で真っ黒）。
    pub type alias MultiLightConfig = {
        lights = List[Light], darkness = Float64, viewport = Vec2.Vec2,
        haloSprite = String, haloSourceSize = Float64, z = Int32
    }

    /// 複数光源の近似。全面オーバーレイ（Multiply, 一様darkness）+各光位置にAddハロ、という
    /// 「暗闇の上に光が乗る」近似のまま（Pass を使えば真の穴あきも組めるが、ここは呼ばない）。
    /// 床は暗いまま見えない（真の穴あきが要らない松明集団シーン等向け）。
    /// ハロは全て同じ z+1（Add は加算合成のため奥行き順に依らず重なりは自然に足し合わさる）。
    pub def multiLightItems(cfg: MultiLightConfig): List[Render.PlacedItem] =
        let darkColor = { r = 0.0, g = 0.0, b = 0.0 };
        let cover = RawDraw.boxAt(Vec2.mul(cfg#viewport, 0.5), cfg#viewport, darkColor, cfg#z)
            |> (placed -> { item = Render.blended(DrawCmd.BlendMode.Multiply, placed#item)
                                |> Render.fade(cfg#darkness) | placed });
        let haloes = cfg#lights |> List.map(light -> {
            at = light#at,
            item = Render.sprite(cfg#haloSprite, cfg#z + 1)
                |> tintHalo(light)
                |> Render.scaled(haloScale(light#radius, cfg#haloSourceSize))
                |> Render.blended(DrawCmd.BlendMode.Add)
        });
        cover :: haloes

    // ── 光マップ方式（複数光源＋影つき。Pass に灯りを集め、Multiply で本編に掛ける）──
    //
    // オーバーレイ方式（items）と絵の性格が違う別の道具として併存する:
    //   - オーバーレイ方式 = 穴の外は一様な闇。pass を 1 本も使わない軽さと rim・haloDiameterFactor の
    //     質感を持つが、穴（影の抜け）は 1 枚絵なので複数同時には開けられない
    //   - 光マップ方式 = 環境光のある夜。光源が何個でも、光ごとに向きの違う影が落ちる。
    //     放射は組み込みテクスチャ（Render.lightAt）なので GlowAssets の焼き・転記が要らない

    /// 光マップ方式の設定。lightMapPass（App.withPasses へ）と lightMapOverlay（view の列へ）の
    /// **両方に同じ値を渡す** — 2 か所で別々に組むと passName / z が食い違う。
    /// lights / occluders はオーバーレイ方式（SceneLightConfig）と同じ形をそのまま使う。
    /// ambient = 影の底の色（環境光。真っ黒にしない — 影は「この色へ戻る」）。
    /// shadowStrength = 影の濃さ 0..1（1 で環境光まで完全に戻す）。
    /// extrudeLength = 影を伸ばす長さ（目安は Shadow.infiniteExtrude()）。
    /// passName = レンダーターゲット名。z = 本編に Multiply で貼る zIndex
    /// （これ未満の zIndex の絵に光が掛かる）。
    pub type alias LightMapConfig = {
        lights = List[Light],
        occluders = List[List[Vec2.Vec2]],
        viewport = Vec2.Vec2,
        ambient = Color,
        shadowStrength = Float64,
        extrudeLength = Float64,
        passName = String,
        z = Int32
    }

    /// ambient の既定の目安（#1a1826 の夜の青み。k/255 で割り切れる値なので
    /// GL/CPU の量子化で揺れない）。
    pub def defaultAmbient(): Color =
        { r = c255(26), g = c255(24), b = c255(38) }

    /// shadowStrength の既定の目安（影がはっきり見えつつ、灯りの気配がわずかに残る濃さ）。
    pub def defaultShadowStrength(): Float64 = 0.85

    /// 光マップの Pass を導く純関数（App.withPasses へ渡す）。並びは
    /// 環境光の全面 box → 各光の放射（Render.lightAt の Add）→ 光×遮蔽物ごとの影
    /// （Shadow.shadowQuads の四角形を環境光色の Normal Poly で置く = 灯りを打ち消して
    /// 環境光へ戻す。真っ黒にしないので破綻しない）。
    /// 放射 1 枚は素朴な既定 — 芯＋広がりのような演出は戻り値の items へゲームが
    /// 追記してよい（Pass はただのレコードなので拡張口を別に設けない）。
    /// 割り切り: 影は Normal 合成で領域ごと環境光へ戻すため、**光 A の影が光 B の照らす
    /// 領域を横切ると、B の灯りもその領域では消える**。厳密にするには光 1 個 = pass 1 本が
    /// 要り、pass 数が光源数に比例して増えるため v1 はこの割り切りを仕様にする。
    pub def lightMapPass(cfg: LightMapConfig): Render.Pass =
        let ambientFloor = { at = Vec2.zero(), item = RawDraw.box(cfg#viewport, cfg#ambient, 0) };
        let radiance = cfg#lights |> List.map(light -> Render.lightAt({
            at = light#at, radius = light#radius, color = light#color,
            strength = light#halo, z = radianceZ() }));
        let shadows = cfg#lights |> List.flatMap(light ->
            cfg#occluders
                |> List.flatMap(occluder -> Shadow.shadowQuads(light#at, occluder, cfg#extrudeLength))
                |> List.map(quad -> ambientQuad(quad, cfg#ambient, cfg#shadowStrength)));
        { name = cfg#passName,
          clear = RenderTarget.LoadOp.Clear({ r = 0.0, g = 0.0, b = 0.0 }),
          items = ambientFloor :: List.append(radiance, shadows) }

    /// 光マップを本編へ Multiply で 1 枚貼る PlacedItem（view の列の末尾側に足す）。
    /// 光が掛かるのは cfg#z 未満の zIndex の絵だけ — HUD 等の掛けたくない物は
    /// cfg#z より大きい zIndex に置く。
    pub def lightMapOverlay(cfg: LightMapConfig): Render.PlacedItem =
        Render.blit(cfg#passName, cfg#viewport, cfg#z)
            |> Render.overItem(item -> Render.blended(DrawCmd.BlendMode.Multiply, item))

    /// 光マップの中の z-index の範囲。影（20）は放射（10）より上 — 影が灯りの Add の後に掛からないと
    /// 「灯りを打ち消して環境光へ戻す」順にならないため。
    def radianceZ(): Int32 = 10
    def shadowZ(): Int32 = 20

    /// 影四角形を環境光色・Normal の Poly にする。Shadow.blackQuad（Multiply 黒）と色も
    /// 合成も違う — 光マップの中で黒を掛けると本編がその領域だけ真っ黒に落ちてしまう。
    def ambientQuad(quad: List[Vec2.Vec2], ambient: Color, strength: Float64): Render.PlacedItem =
        { at = Vec2.zero(),
          item = RawDraw.polygon(quad, ambient, shadowZ()) |> Render.fade(strength) }

    /// 8bit 値 k をそのままの色成分（k/255）にする。
    def c255(k: Int32): Float64 =
        Int32.toFloat64(k) / 255.0
}
