// ViewScene — 背景（空・海）と、道の外の景色（ヤシの木）と、画面全体の速度線の層。
// 「真夏の海岸ハイウェイ」の舞台側: 空は青く、海は光る。ここは走りの規則に一切絡まない —
// World を読むだけで、時間（雲・きらめき・速度線）は t と番号から毎回計算する
// （どこにも状態を持たないので、巻き戻しても描き出しでも同じ絵になる）。
mod ViewScene {

    // ── z 層（空 0..2 / 遠景の岬 3 / 海 4..5 / 丘の向こうの平野 6 / 浜 7 / 速度線 85） ──
    def zSky(): Int32 = 0
    def zSun(): Int32 = 1
    def zCloud(): Int32 = 2
    def zRidge(): Int32 = 3
    def zSea(): Int32 = 4
    def zHorizon(): Int32 = 5
    def zPlain(): Int32 = 6
    def zBeach(): Int32 = 7
    def zSpeed(): Int32 = 85

    // ── 空（グラデ + 太陽 + 流れる雲） ──

    /// 空一式。地平線より上をコバルト → 淡い水色のグラデで塗る（面の階調はこの 1 枚が受け持つ）。
    pub def sky(cam: Proj.Cam, w: World.World): List[Render.PlacedItem] =
        let grad = { at = { x = 0.0, y = 0.0 },
                     item = Render.vgrad({ x = World.designW(), y = Proj.horizonYAt(cam) },
                         { top = ThemeDoc.rec(w#theme)#skyTop, bottom = ThemeDoc.rec(w#theme)#skyLow }, zSky()) };
        grad :: (sun(cam, w) ::: clouds(cam, w))

    /// 曲がった向きに景色が流れる量（px）。右へ回れば景色は左へ流れるので符号を返す。
    /// 空は一番遠いので、道の折れと違って縮みも遠近も掛からない — 画面ごと横へずらす。
    def skyShift(w: World.World): Float64 =
        0.0 - World.headingAt(World.playerDistOf(w), w#course) * RulesDoc.rec(w#rules)#skyParallax

    /// 景色が横へ回りきって画面から消えないよう、画面幅 + 余白で巻き戻す幅。
    def skySpan(): Float64 = World.designW() + 80.0

    /// 巻き戻しの余白（画面の左右にはみ出せる幅）。
    def skyMargin(): Float64 = 40.0

    /// 太陽の位置。海の照り返し（horizonShine）も同じ x を見る。
    /// 回りきったら反対の縁から戻す — 曲がり続けても空が空っぽにならない。
    def sunAt(cam: Proj.Cam, w: World.World): Vec2.Vec2 =
        { x = Num.wrapTo(skySpan(), 196.0 + skyMargin() + skyShift(w)) - skyMargin(),
          y = Float64.min(Proj.horizonYAt(cam) - 14.0, 26.0) }

    /// 太陽。白い光球 + 芯の丸。Add ブレンドで空のグラデに重ねる。
    /// 一番遠い物なので、曲がったときに一番よく動く目印になる。
    def sun(cam: Proj.Cam, w: World.World): List[Render.PlacedItem] =
        let at = sunAt(cam, w);
        Render.glowAt(at, 18.0, ThemeDoc.rec(w#theme)#text,
                { alpha = 0.5, blend = DrawCmd.BlendMode.Add }, zSun())
            ::: (RawDraw.circleAt(at, 7.0, ThemeDoc.rec(w#theme)#text, zSun()) :: Nil)

    /// 雲 4 つ。楕円 3 枚組を右から左へ 3px/s で流す（走らなくても空だけは動く = 時間の下限）。
    /// 曲がったぶんも一緒に流すが、太陽より少しだけ鈍く動かす（雲のほうが手前にある）。
    /// 高い雲ほど小さくして、空にも奥行きの気配を出す。
    def clouds(cam: Proj.Cam, w: World.World): List[Render.PlacedItem] =
        Fx.derive(4, w#t, (_i, rand, t) -> {
            let span = World.designW() + 60.0;
            let x = Num.wrapTo(span, rand(0) * span - t * 3.0 + skyShift(w) * 0.8) - 30.0;
            let y = Float64.min(Proj.horizonYAt(cam) - 8.0, 18.0 + rand(1) * 34.0);
            let s = 4.0 + (y - 18.0) / 34.0 * 5.0 + rand(2) * 2.0;
            let c = ThemeDoc.rec(w#theme)#text;
            RawDraw.ellipseAt({ x = x, y = y }, { x = s * 2.2, y = s }, c, zCloud())
                :: RawDraw.ellipseAt({ x = x - s * 1.6, y = y + s * 0.35 },
                       { x = s * 1.4, y = s * 0.7 }, c, zCloud())
                :: RawDraw.ellipseAt({ x = x + s * 1.7, y = y + s * 0.3 },
                       { x = s * 1.5, y = s * 0.75 }, c, zCloud())
                :: Nil
        }) |> List.flatten

    // ── 海（面 + 水平線の輝き + きらめき + 浜） ──

    /// 海の面の上端 = ほんとうの水平線（ここより上は空）。下端は道の消失点で、
    /// そこが波打ちぎわになる — つまりこの面は「上ほど遠い」。
    /// 空の高さの 1/3 を海に渡す。ここを 16px まで削ると、海岸ハイウェイなのに海が
    /// 水平線ぎわの細い線にしか読めない（雲の下端 52px より下には出さない）。
    def seaTopY(cam: Proj.Cam): Float64 = Proj.horizonYAt(cam) - 32.0

    /// 海一式。上から順に「空との境（水平線の輝き）→ 海の面 → 波打ちぎわ → 浜」。
    /// 板を 3 枚並べたように見せないため、境目はどれも 1px の線ではなく幅を持たせる。
    /// 海そのものは横に一様なので流さない（流しても違いが出ず、波が滑るだけ）。
    pub def sea(cam: Proj.Cam, w: World.World): List[Render.PlacedItem] =
        seaFace(cam, w#theme) ::: headlands(cam, w) ::: horizonShine(cam, w)
            ::: glints(cam, w) ::: shore(cam, w#theme)

    /// 海の面。上（水平線ぎわ = 一番遠い）は空気に溶けて淡く、下（手前）ほど濃い青。
    /// 上端を空の色へ近づけておくと、空との境が線で切れずに繋がる。
    /// 淡→濃を 1 枚の直線グラデで渡すと、幅を厚くしたぶん中ほどが水色一色の板に見えるので、
    /// 水平線ぎわだけ短く霞ませて、残り 3/4 は海そのものの青を保たせる。
    def seaFace(cam: Proj.Cam, theme: ThemeDoc.Doc): List[Render.PlacedItem] =
        let top = seaTopY(cam);
        let bot = Proj.horizonYAt(cam);
        let up = Color.mix(ThemeDoc.rec(theme)#sea, ThemeDoc.hazeTo(theme), 0.50);
        let mid = Color.mix(ThemeDoc.rec(theme)#sea, ThemeDoc.hazeTo(theme), 0.12);
        let low = seaNear(theme);
        ramp({ y = top,                           color = up }
          :: { y = top + (bot - top) * 0.26,      color = mid }
          :: { y = bot,                           color = low }
          :: Nil, zSea())

    /// 波打ちぎわ側（一番手前）の海の色。浜のグラデの上端も同じ色から始めるので、
    /// ここを 1 か所にしておかないと海と浜の境に線が出る。
    /// 暗く沈めないのは、海が空と路面より前に出ないようにするため。
    def seaNear(theme: ThemeDoc.Doc): Color =
        Color.cool(Color.darken(ThemeDoc.rec(theme)#sea, 0.06), 0.10)

    /// 水平線ぎわの輝き。空と海の境に沿って白い光を溜め、太陽の真下だけ手前へ長く伸ばす
    /// （海面に落ちた陽の道）。線 1 本で切るより、光の帯のほうが遠さが出る。
    def horizonShine(cam: Proj.Cam, w: World.World): List[Render.PlacedItem] =
        let theme = w#theme;
        let c = ThemeDoc.seaGlint(theme);
        let top = seaTopY(cam);
        let wide = World.designW();
        let glowStrip = { at = { x = 0.0, y = 0.0 },
                          item = Render.gradPolygon(
                                 { pos = { x = 0.0, y = top },        color = c, alpha = 0.55 }
                              :: { pos = { x = wide, y = top },       color = c, alpha = 0.55 }
                              :: { pos = { x = wide, y = top + 7.0 }, color = c, alpha = 0.0 }
                              :: { pos = { x = 0.0, y = top + 7.0 },  color = c, alpha = 0.0 }
                              :: Nil, zHorizon())
                              |> Render.blended(DrawCmd.BlendMode.Add) };
        let sx = sunAt(cam, w)#x;
        // 陽が水面に落ちた照り返し。丸い光だまりにすると空に太陽が 2 つあるように読めるので、
        // 水平線より下（海の上）だけに、横へ長い面として置く。
        let pool = shineStripe(c, { cx = sx, halfW = 78.0, y0 = top + 0.5,
                                    y1 = top + 7.0, alpha = 0.40 })
            ::: shineStripe(c, { cx = sx, halfW = 30.0, y0 = top + 1.0,
                                 y1 = top + 26.0, alpha = 0.30 });
        glowStrip :: pool

    // ── 遠景の岬（水平線の向こうの陸） ──

    /// 岬の連なり 3 枚。奥ほど高く・霞んで・ゆっくり流れる。水平線に land が乗るだけで
    /// 「向こう岸のある湾」になり、空と海の境が 1 本の直線でなくなる。
    /// 曲がると一緒に流れる（skyShift）ので、貼った紙ではなく遠くの景色として読める。
    def headlands(cam: Proj.Cam, w: World.World): List[Render.PlacedItem] =
        let base = seaTopY(cam) + 1.0;
        ridgeSpecs() |> List.flatMap(r -> ridge(w, base, r))

    /// 岬 1 枚の性格。height = 水平線からの高さ（px）、haze = 空気に溶かす割合、
    /// drift = 曲がったときに流れる速さ（遠いほど遅い）。
    def ridgeSpecs(): List[{ seed = Float64, height = Float64, haze = Float64, drift = Float64 }] =
           { seed = 0.0, height = 27.0, haze = 0.80, drift = 0.30 }
        :: { seed = 3.1, height = 18.0, haze = 0.62, drift = 0.50 }
        :: { seed = 6.7, height = 11.0, haze = 0.44, drift = 0.75 }
        :: Nil

    /// 稜線の高さ（0 = 水平線・1 = 一番高い所）。周期の違う 2 本の波を重ねるのは、
    /// 1 本だと山の頂が等間隔に並んで波形のグラフに見えるため。
    def ridgeProfile(x: Float64, seed: Float64): Float64 =
        Num.clamp01(0.45 + 0.34 * Vec2.cos(x * 0.043 + seed)
                         + 0.21 * Vec2.cos(x * 0.017 + seed * 1.7))

    /// 岬 1 枚。稜線を短い台形に割って積む。頂は日を受けて明るく、裾は空気に沈む。
    def ridge(w: World.World, base: Float64,
              r: { seed = Float64, height = Float64, haze = Float64, drift = Float64 }
             ): List[Render.PlacedItem] =
        let n = 20;
        let wide = World.designW();
        let shift = skyShift(w) * r#drift;
        let land = Color.cool(Color.darken(ThemeDoc.rec(w#theme)#grass, 0.30), 0.22);
        let low = Color.mix(land, ThemeDoc.hazeTo(w#theme), Num.clamp01(r#haze));
        let high = Color.mix(land, ThemeDoc.hazeTo(w#theme), Num.clamp01(r#haze - 0.18));
        List.range(0, n) |> List.map(i -> {
            let x0 = wide * Int32.toFloat64(i) / Int32.toFloat64(n) - 1.0;
            let x1 = wide * Int32.toFloat64(i + 1) / Int32.toFloat64(n) + 1.0;
            { at = { x = 0.0, y = 0.0 },
              item = Render.gradPolygon(
                     { pos = { x = x0, y = base - r#height * ridgeProfile(x0 - shift, r#seed) },
                       color = high, alpha = 1.0 }
                  :: { pos = { x = x1, y = base - r#height * ridgeProfile(x1 - shift, r#seed) },
                       color = high, alpha = 1.0 }
                  :: { pos = { x = x1, y = base + 3.0 }, color = low, alpha = 1.0 }
                  :: { pos = { x = x0, y = base + 3.0 }, color = low, alpha = 1.0 }
                  :: Nil, zRidge()) }
        })

    /// 水面の照り返しの面 1 枚。中心 cx が一番明るく、左右の端と下端で消える。
    /// 4 頂点の面 1 枚では中心を山にできないので、左右に割って 2 枚で描く。
    def shineStripe(c: Color, s: { cx = Float64, halfW = Float64, y0 = Float64,
                                   y1 = Float64, alpha = Float64 }): List[Render.PlacedItem] =
        let half = side -> {
            let xe = s#cx + side * s#halfW;
            { at = { x = 0.0, y = 0.0 },
              item = Render.gradPolygon(
                     { pos = { x = xe, y = s#y0 },   color = c, alpha = 0.0 }
                  :: { pos = { x = s#cx, y = s#y0 }, color = c, alpha = s#alpha }
                  :: { pos = { x = s#cx, y = s#y1 }, color = c, alpha = 0.0 }
                  :: { pos = { x = xe, y = s#y1 },   color = c, alpha = 0.0 }
                  :: Nil, zHorizon())
                  |> Render.blended(DrawCmd.BlendMode.Add) }
        };
        half(-1.0) :: half(1.0) :: Nil

    /// 上から下へ色を継いでいく横長の面の連なり（境目に線が出ない縦グラデの階段）。
    /// 隣り合う面が同じ色を共有するので、枚数を増やしても継ぎ目が見えない。
    def ramp(stops: List[{ y = Float64, color = Color }], z: Int32): List[Render.PlacedItem] =
        let wide = World.designW();
        List.zip(stops, List.drop(1, stops)) |> List.map(pair -> {
            let (a, b) = pair;
            { at = { x = 0.0, y = 0.0 },
              item = Render.gradPolygon(
                     { pos = { x = 0.0, y = a#y },  color = a#color, alpha = 1.0 }
                  :: { pos = { x = wide, y = a#y }, color = a#color, alpha = 1.0 }
                  :: { pos = { x = wide, y = b#y }, color = b#color, alpha = 1.0 }
                  :: { pos = { x = 0.0, y = b#y },  color = b#color, alpha = 1.0 }
                  :: Nil, z) }
        })

    /// 波打ちぎわと浜。海と地面をじかに突き合わせず、海 → 白い波がしら → 濡れた砂 →
    /// 乾いた砂 → 霞んだ草へ色を継ぐ。遠景なので全部いちど霞ませてから置く（手前の草と
    /// 同じ強さで色が乗ると、地平線の手前だけ絵が近づいて見える）。
    def shore(cam: Proj.Cam, theme: ThemeDoc.Doc): List[Render.PlacedItem] =
        let y0 = Proj.horizonYAt(cam);
        let far = amount -> c -> Color.mix(c, ThemeDoc.hazeTo(theme), amount);
        ramp({ y = y0 - 1.2, color = far(0.0)(seaNear(theme)) }
          :: { y = y0 - 0.2, color = far(0.20)(ThemeDoc.rec(theme)#finish) }
          :: { y = y0 + 1.4, color = far(0.56)(Color.cool(Color.darken(ThemeDoc.rec(theme)#sand, 0.30), 0.10)) }
          :: { y = y0 + 3.2, color = far(0.50)(Color.warm(ThemeDoc.rec(theme)#sand, 0.08)) }
          :: { y = y0 + 5.6, color = far(0.88)(ThemeDoc.grassLight(theme)) }
          :: Nil, zBeach())

    /// きらめきと波がしら。白い短い横線が各自の周期で明滅する（Add で海に光を足す）。
    /// 手前（下）ほど長く太くするのは、遠い波ほど 1px に潰れて数だけ増えるのが自然な見え方で、
    /// 全部同じ長さで撒くと海面ではなく砂嵐に読めるため。
    def glints(cam: Proj.Cam, w: World.World): List[Render.PlacedItem] =
        let top = seaTopY(cam);
        let span = Proj.horizonYAt(cam) - top;
        Fx.derive(30, w#t, (_i, rand, _t) -> {
            let x = rand(0) * World.designW();
            // 遠い側に多く集める（rand を 2 乗して上へ詰める）。
            let d = rand(1) * rand(1);
            let y = top + 1.0 + d * (span - 2.0);
            let len = (2.5 + rand(2) * 5.0) * (0.6 + 1.1 * d);
            let thick = if (d > 0.55) 2.0 else 1.0;
            let blink = 0.5 + 0.5 * Sway.wave(w#t, rand(3) * 7.0, 0.35 + rand(4) * 0.5);
            RawDraw.lineSeg({ x = x, y = y }, { x = x + len, y = y }, thick,
                    ThemeDoc.seaGlint(w#theme), zHorizon())
                |> Render.overItem(item -> item
                    |> Render.fade(
                           (0.15 + 0.4 * blink) * (0.55 + 0.45 * d))
                    |> Render.blended(DrawCmd.BlendMode.Add))
        })

    // ── 丘の向こうの平野 ──

    /// 登り坂の途中では一番奥のセグメントでも地平線に届かず、そのあいだが生成時の下地色のまま
    /// 平らに残る（貼った紙の縁のような横一線に読める）。そこを草の色で埋める。
    /// 一番奥のセグメントとまったく同じ色から始めて浜の裾へ溶かすので、境目で色が飛ばない。
    pub def plain(cam: Proj.Cam, w: World.World): List[Render.PlacedItem] =
        let top = Proj.horizonYAt(cam) + 4.0;
        // 坂があるとセグメントの並び（奥→手前）と画面の高さの並びは一致しない。丘の頂の手前では
        // 一番奥のセグメントがむしろ画面の下に来るので、一番高く来たセグメントの辺を境目として拾う。
        let crest = Proj.segments(w) |> List.foldLeft((acc, b) -> {
            let uFar = b#u0 + b#du;
            let y = Proj.yAt(cam, uFar);
            if (y < acc#y) { y = y, rowF = Int32.toFloat64(b#n) + b#du, u = uFar } else acc
        }, { y = World.designH() * 2.0, rowF = 0.0, u = 0.0 });
        if (crest#y <= top + 1.0) Nil
        else {
            let near = ViewRoad.grassAt(w, crest#rowF, crest#u);
            let far = Color.mix(near, ThemeDoc.hazeTo(w#theme), 0.40);
            ramp({ y = top, color = far }
              :: { y = top + (crest#y - top) * 0.5, color = Color.mix(near, far, 0.62) }
              :: { y = crest#y + 1.0, color = near }
              :: Nil, zPlain())
        }

    // ── ヤシの木（道の外の立ち物） ──

    /// ヤシの木。セグメントのループと同じ通し行 n を見て、Hash01 で「この行に生えるか・左右どちらか・
    /// 道からどれだけ離れるか」を決める — 乱数を保存せず行番号から毎回同じ答えを引くので、
    /// 周回して同じ行に戻ると同じ場所に同じ木が立っている。
    pub def palms(cam: Proj.Cam, w: World.World): List[Render.PlacedItem] =
        Proj.segments(w) |> List.flatMap(b ->
            if (Hash01.at(b#n, 11) >= 0.30 or b#u0 > 20.0) Nil
            else {
                // 木の足元はセグメントの真ん中（u0+0.5）なので、道の左右端も同じ所で引く。
                // 行の端をそのまま使うと、セグメントが繋がったぶんだけ木が道へめり込む。
                let e = ViewRoad.edgeAtT(ViewRoad.stripOf(w, b#n), 0.5);
                let leftSide = Hash01.at(b#n, 12) < 0.5;
                let off = clearance() + 16.0 * Hash01.at(b#n, 13);
                let wx = if (leftSide) e#xl - off else e#xr + off;
                let uc = b#u0 + 0.5;
                palmAt(cam, w, plantInk(w, uc),
                       { wx = wx, uc = uc, leftSide = leftSide })
            })

    /// この距離で霞ませた「草木の意味色」をひとまとめに引いておく関数。
    /// 色票の引き当ては名前で表を辿るので、1 枚 1 枚で引き直すとセグメント 1 本のあいだに
    /// 何百回も走る（葉と幹の 5 色はセグメントの中でどれも同じ値になる）。
    def plantInk(w: World.World, uc: Float64): String -> Color =
        let leaf = ViewRoad.hazedKey(w, uc, "leaf");
        let leafLight = ViewRoad.hazedKey(w, uc, "leafLight");
        let leafDark = ViewRoad.hazedKey(w, uc, "leafDark");
        let trunk = ViewRoad.hazedKey(w, uc, "trunk");
        let trunkDark = ViewRoad.hazedKey(w, uc, "trunkDark");
        key ->
            if (key == "leaf") leaf
            else if (key == "leafLight") leafLight
            else if (key == "leafDark") leafDark
            else if (key == "trunk") trunk
            else if (key == "trunkDark") trunkDark
            else ViewRoad.hazedKey(w, uc, key)

    /// 木の幹を道の端からどれだけ離すか（世界 px）。縁石 6px + 葉の張り出し（幹から
    /// 格子の端まで 15px × 木の倍率 1.5 ≒ 23px）+ 余白。これを削ると葉が路面へかぶさる。
    def clearance(): Float64 = 32.0

    /// ヤシ 1 本 = 幹の根元の楕円影 + ドット絵（21x18）。
    /// 側で flipX を変えるのは、葉の張り出しを道側へ向けるため（左右対称の並木は作り物くさい）。
    /// 幹は格子の中心から 4.5px ずれた所にあるので、影ではなく絵をずらして幹を wx に立たせる。
    def palmAt(cam: Proj.Cam, w: World.World, ink: String -> Color,
               p: { wx = Float64, uc = Float64, leftSide = Bool }): List[Render.PlacedItem] =
        palmDraw(w, ink, { at = { x = Proj.screenX(cam, p#wx, p#uc), y = Proj.yAt(cam, p#uc) },
                           uc = p#uc, f = Proj.scaleOf(p#uc) * 1.5,
                           flipX = not p#leftSide, turn = 0.0 })

    /// ヤシ 1 本を画面座標へ置く（道ぎわの並木も、草原の遠景も同じ入口を通す）。
    /// 幹は格子の中心から 4.5px ずれた所にあるので、影ではなく絵をずらして幹を at に立たせる。
    /// turn の傾きは絵の中心を軸に回るが、群れで使う角度（±6 度）では根元のずれは
    /// 1px に満たないので、幹が地面から浮かない。
    def palmDraw(w: World.World, ink: String -> Color,
                 p: { at = Vec2.Vec2, uc = Float64, f = Float64, flipX = Bool,
                      turn = Float64 }): List[Render.PlacedItem] =
        let trunkDx = if (p#flipX) -4.5 * p#f else 4.5 * p#f;
        if (p#f < palmCull()) Nil
        else shadowUnder(p#at, 7.0 * p#f, 2.2 * p#f, p#uc)
            :: (if (p#f < palmDetail()) palmFar(ink, p, trunkDx)
                // 1 本 = 矩形 75 枚の box 列だったのをアトラス 1 クアッドへ。葉と幹の色は
                // アトラス生成時に入れてあるので、距離の霞だけ tint で近似する。
                else ViewCar.pxQuadScaledCentered({
                    doc = w#sprites, baked = w#atlas, texture = World.atlasName(),
                    sprite = "palm", frame = "base",
                    at = { x = p#at#x + trunkDx, y = p#at#y - 9.0 * p#f },
                    flipX = p#flipX, scale = p#f, turn = p#turn,
                    tint = hazeTint(w, p#uc), z = z(p#uc) }))

    /// 距離の霞をクアッドの tint で近似する。box 列は色そのものを hazeTo へ混ぜる
    /// （Color.mix）が、tint は掛け算なので白側へは近づけられない — クアッドで描く近さ
    /// （霞 4% 未満）では差が画素に出ないため、近似で足りる。
    def hazeTint(w: World.World, uc: Float64): Color =
        Color.mix(Color.rgb(1.0, 1.0, 1.0), ThemeDoc.hazeTo(w#theme), Proj.hazeAt(uc))

    /// ドット絵の格子をそのまま積む一番小さい倍率。ヤシの格子は 21x18 で矩形 75 枚に
    /// ほどけるので、これを下回ると 1 枚が 0.5px を切って抜け始め、75 枚積んでも
    /// ほどけた点の集まりにしかならない（読み取りと積み上げが丸ごと捨てられる）。
    /// 数を減らしたくてここを上げてはいけない。格子 6px まで縮んでもドット絵は葉と幹の
    /// 色を保っていて、同じ大きさを影絵（palmFar）で描くと草地に刺さった黒い棒に見える。
    def palmDetail(): Float64 = 0.30

    /// 木を 1 本も積まなくなる倍率。ここまで小さいと格子の 21px が 3px を切り、
    /// ドット絵で積んでも草の上の淡い点にしかならない。
    def palmCull(): Float64 = 0.13

    /// 遠くのヤシ 1 本。葉の塊 1 枚と幹 1 枚の影絵にする。ドット絵が点にほどけ始めてから
    /// 消えるまでのあいだを繋ぐ役なので、輪郭を強く描かない（濃く描くと、ドット絵なら
    /// 溶けているはずの遠くの木だけが、はっきりした形として草地に浮く）。
    /// 2 枚とも多角形にそろえるのは、足元の影と同じ種類ならセグメント 1 本ぶんがまとめて描かれ、
    /// 矩形（ドット絵）と混ぜたときのような描き分けの切れ目が出ないため。
    def palmFar(ink: String -> Color,
                p: { at = Vec2.Vec2, uc = Float64, f = Float64, flipX = Bool,
                     turn = Float64 }, trunkDx: Float64): List[Render.PlacedItem] =
        let f = p#f;
        let cx = p#at#x + trunkDx;
        // 幹は格子の中心から 3.5px 内側（葉の塊の真ん中の下）に立つ。
        let tx = if (p#flipX) cx + 3.5 * f else cx - 3.5 * f;
        // 太さに下限を置かない。ドット絵の矩形は遠ざかると 1px を切って消えていくので、
        // ここで最低 1px を保証すると、消えていたはずの幹だけが茶色い点として残る。
        let half = 0.9 * f;
        let trunk = { at = { x = 0.0, y = 0.0 },
                      item = RawDraw.polygon(
                             { x = tx - half, y = p#at#y }
                          :: { x = tx + half, y = p#at#y }
                          :: { x = tx + half * 0.9, y = p#at#y - 10.0 * f }
                          :: { x = tx - half * 0.9, y = p#at#y - 10.0 * f }
                          :: Nil, ink("trunk"), z(p#uc)) };
        // 葉は 12 頂点の星形 1 枚。丸い面 1 枚では日傘に見えるので、外へ張る葉と
        // 葉のあいだの空きを長短の頂点で作る。頂点をこれ以上増やしても、この大きさでは
        // 隣り合う頂点の間が 1px に満たない。
        let leaves = { at = { x = 0.0, y = 0.0 },
                       item = RawDraw.polygon(
                           List.range(0, 12) |> List.map(i -> {
                               let a = 2.0 * Vec2.pi() * (Int32.toFloat64(i) + 0.5) / 12.0;
                               let reach = if (Int32.modulo(i, 2) == 0) 1.0 else 0.42;
                               ({ x = cx + 9.4 * f * reach * Vec2.cos(a),
                                  y = p#at#y - 12.8 * f + 3.6 * f * reach * Vec2.sin(a) }: Vec2.Vec2)
                           }), Color.mix(ink("leaf"), ink("leafDark"), 0.35), z(p#uc)) };
        trunk :: leaves :: Nil

    // ── 草原の遠景（道から遠く離れた所の立ち物） ──

    /// 升目の間隔（世界 px）。道の中心からこの間隔で立ち物の候補が並ぶ。
    def lattice(): Float64 = 260.0

    /// 升目を探す横幅の余白（px）。画面の左右にこれだけはみ出した所まで見る。
    def outMargin(): Float64 = 50.0

    /// セグメント 1 本が受け持つ升目の数の上限。奥のセグメントほど広い世界の幅を受け持つので、
    /// 同じ間隔のままだと画面の上では奥ほど升目が詰まっていく（手前 3 升 → 一番奥 34 升）。
    /// 40 は今の間隔（lattice 260）での一番奥の数そのもの。下げれば間引けるが、
    /// 減るのは地平線ぎわの 2px の粒だけで、組み立てる数は 1 割も減らずに草地が寂しくなる。
    /// 効くのは間隔を詰めた作り替えのとき — 詰めてもセグメント 1 本ぶんの手間が青天井にならない。
    def cellsMax(): Int32 = 40

    /// 立ち物 1 つが置き場所から左右へ張り出す幅（画面 px）。ヤシの群れが一番広く、
    /// 塊の散らばり 20.7 + 幹のずれ 5.9 + 傾いた格子の半幅 16.0 = 42.6 倍。
    /// 多めに取るのは、足りないと画面の縁で葉の先が 1px ぶん急に現れるため
    /// （狭めても外れるのは端の 1 個ぶんで、削れる量はほとんど変わらない）。
    def propReach(f: Float64): Float64 = 48.0 * f

    /// 画面の外に立つか。手前のセグメントほど升目 1 つが受け持つ世界の幅は広く（1 升 200px 超）、
    /// 升目の切り上げだけで端を決めると、画面の外の升目を 1〜2 個ぶん余計に組み立てる。
    /// ヤシの群れ 1 つは矩形 200 枚を超えるので、外の 1 個が一番高くつく。
    def offScreen(x: Float64, f: Float64): Bool =
        let reach = propReach(f);
        x + reach < 0.0 or x - reach > World.designW()

    /// 立ち物を 1 つでも組み立てる一番小さい倍率。低木の幅は 19.5 倍・ヤシの影絵は 18.8 倍
    /// なので、ここを下回ると画面のどの向きにも 1px に届かない。
    /// ここより上でも、ヤシは点にほどけるので別に高い床（palmCull）を持つ。
    def propCull(): Float64 = 0.05

    /// 升目 1 つが取りうる一番大きい倍率（outfieldAt の 1.4 + 0.9 * r の上限）。
    /// セグメントまるごと切るかの判定に使う — 一番大きい物さえ 1px に届かないなら升目の輪を回さない。
    def propScaleTop(): Float64 = 2.3

    /// 道から離れた升目に立つ物（ヤシの群れ・低木・道路標識）。
    /// 急カーブで道が画面の外へ抜けると、道ぎわのヤシも一緒に消えて画面の半分が
    /// 無地の草になる。草原の側にも物を置けば、道が無くても奥行きが語れる。
    ///
    /// 画面に入る升番号は投影の式を解いて求める。screenX は off について 1 次
    /// （screenX(off) = screenX(0) + off × 縮み）なので、端の画面 x から off の範囲が直に出る —
    /// 遠くの升まで総当たりしなくて済む。
    pub def outfield(cam: Proj.Cam, w: World.World): List[Render.PlacedItem] =
        Proj.segments(w) |> List.flatMap(b -> {
            let uc = b#u0 + 0.5;
            // 縮みは辺（edgeOf）より先に引く。辺は足し上げの表を 2 度たどるので、
            // 何も見えないセグメントでそれを引くと、捨てるためだけに一番高い計算をすることになる。
            let k = Proj.scaleOf(uc);
            if (uc < 0.5 or uc > 18.0 or k * propScaleTop() < propCull()) Nil
            else {
                // セグメントの辺は 1 回だけ引いて、そのセグメントの升目すべてで使い回す。
                let edge = Proj.edgeOf(cam, uc);
                let x0 = Proj.edgeX(edge, 0.0);
                let ink = plantInk(w, uc);
                // 画面の縁の余白（outMargin）は strip の reach でなく span へまとめる。
                // reach は world px 単位で、screen px の余白を渡すと k で割る並びが
                // 升番号の計算と食い違い、縁のセルの有無が丸めで変わり得る。
                Scatter.strip(
                    { lo = (0.0 - outMargin() - x0) / k,
                      hi = (World.designW() + outMargin() - x0) / k },
                    { cell = lattice(), salt = 0, lane = b#n,
                      reach = 0.0, cellsMax = cellsMax() },
                    (m, r) -> outfieldAt(w, edge, ink, b#n, uc, m, r))
            }
        })

    /// 升目 1 つ。升の乱数 r は Scatter.strip が配る（鍵 = 行 × 升の通し番号）ので、
    /// 乱数を保存せず周回して戻ると同じ景色になる。通し番号 seed をここでも組み直すのは、
    /// 群れ（grove）が 1 本ごとの乱数の鍵に seed を混ぜるため。
    /// 道の近く（120px 以内）は空ける — そこは道ぎわのヤシ（palms）の担当範囲。
    def outfieldAt(w: World.World, edge: Proj.Edge, ink: String -> Color,
                   n: Int32, uc: Float64, m: Int32,
                   r: Int32 -> Float64): List[Render.PlacedItem] =
        let seed = n * 37 + m;
        // 大きさと画面 x は、形や色より先に決める。組み立ててから捨てると、捨てる物のぶんだけ
        // 場所・色・形を作る手間がまるごと無駄になる（重いのは描くことでなく作ること）。
        let f = edge#k * (1.4 + 0.9 * r(3));
        let off = (Int32.toFloat64(m) + 0.12 + 0.76 * r(1)) * lattice();
        let x = Proj.edgeX(edge, off);
        if (f < propCull() or r(2) >= 0.52 or Float64.abs(off) < 130.0 or offScreen(x, f)) Nil
        else {
            let groundY = edge#y;
            let at = { x = x, y = groundY };
            let pick = r(4);
            // 標識は近い所だけ。遠くでは 2〜3px の赤白の点になり、景色でなく汚れに読める。
            if (pick < 0.52) grove(w, ink, at, uc, f, seed)
            else if (pick < 0.90 or uc > 7.0) bushAt(ink, at, uc, f, r(6))
            else signAt(w, at, uc, f)
        }

    /// ヤシの群れ。1 本ずつ撒くと、遠くでは点が散っただけに見える。2〜4 本をまとめて
    /// 立てると 1 つの塊として読めて、遠さのわりに形が残る。
    /// 塊の中では 1 本ごとに前後・大きさ・向き・傾きを散らす。ここを揃えると、
    /// 同じ絵が横に並んだ「貼り付けた並木」として読める。
    def grove(w: World.World, ink: String -> Color,
              at: Vec2.Vec2, uc: Float64, f: Float64, seed: Int32): List[Render.PlacedItem] =
        let n = 2 + Num.floorInt(Hash01.at(seed, 7) * 3.0);
        List.range(0, n) |> List.flatMap(i -> {
            let g = j -> Hash01.at(seed * 13 + i * 101, j);
            let spread = 9.0 * f;
            // 手前（画面の下）に立つ木ほど大きく見せる — 前後のずれと大きさが噛み合わないと
            // 塊が 1 枚の板に見える。
            let depth = g(2);
            palmDraw(w, ink, { at = { x = at#x + (g(1) - 0.5) * 4.6 * spread,
                                 y = at#y + (depth - 0.5) * 1.6 * spread },
                          uc = uc,
                          f = f * (0.66 + 0.52 * g(3) + 0.24 * (depth - 0.5)),
                          flipX = g(4) < 0.5,
                          turn = (g(5) - 0.5) * 0.036 })
        })

    /// 低木の茂み。楕円 3 枚を積んで、日向側だけ暖色へ近づける（塊が 1 色にならない）。
    def bushAt(ink: String -> Color, at: Vec2.Vec2, uc: Float64, f: Float64,
               tone: Float64): List[Render.PlacedItem] =
        let dark = ink("leafDark");
        let light = Color.warm(ink("leaf"), 0.10 + 0.2 * tone);
        let s = 6.5 * f;
        // 縁の分割数は大きさなり（遠くの茂みは 3px ほどで、既定の 32 分割は要らない）。
        let blob = (dx, dy, rx, ry, c) -> {
            let radii = ({ x = rx * s, y = ry * s }: Vec2.Vec2);
            RawDraw.ellipseSegsAt({ x = at#x + dx * s, y = at#y + dy * s },
                    radii, RawDraw.ellipseSegsFor(radii), c, z(uc))
        };
        shadowUnder(at, 1.5 * s, 0.5 * s, uc)
            :: blob(0.0 - 0.5, 0.0 - 0.5, 1.0, 0.7, dark)
            :: blob(0.6, 0.0 - 0.35, 0.85, 0.6, dark)
            :: blob(0.0, 0.0 - 1.0, 0.8, 0.55, light)
            :: Nil

    /// 道路標識。柱 2 本 + 板 1 枚。遠くでも「人の手が入った土地」だと読める形にする。
    def signAt(w: World.World, at: Vec2.Vec2, uc: Float64,
               f: Float64): List[Render.PlacedItem] =
        let s = 6.0 * f;
        let post = Color.mix(Color.darken(ThemeDoc.rec(w#theme)#road, 0.35), ThemeDoc.hazeTo(w#theme),
                             Proj.hazeAt(uc));
        let face = Color.mix(ThemeDoc.rec(w#theme)#finish, ThemeDoc.hazeTo(w#theme), Proj.hazeAt(uc));
        let mark = Color.mix(ThemeDoc.rec(w#theme)#kerb, ThemeDoc.hazeTo(w#theme), Proj.hazeAt(uc));
        let leg = dx ->
            RawDraw.boxAt({ x = at#x + dx * s, y = at#y - s * 0.9 },
                    { x = Float64.max(1.0, 0.22 * s), y = 1.8 * s }, post, z(uc));
        shadowUnder(at, 1.2 * s, 0.4 * s, uc)
            :: leg(-0.7) :: leg(0.7)
            :: RawDraw.boxAt({ x = at#x, y = at#y - s * 2.4 },
                    { x = 2.4 * s, y = 1.4 * s }, face, z(uc))
            :: RawDraw.boxAt({ x = at#x, y = at#y - s * 2.4 },
                    { x = 2.4 * s, y = Float64.max(1.0, 0.4 * s) }, mark, z(uc))
            :: Nil

    /// 立ち物の接地影（足元の楕円）。遠いほど薄い。形と濃さの式は ViewRoad.shadowUnder が正 —
    /// ここは何百と撒く立ち物向けに、分割数を大きさなりへ落とすだけ。
    def shadowUnder(at: Vec2.Vec2, rx: Float64, ry: Float64, uc: Float64): Render.PlacedItem =
        let radii = ({ x = rx, y = ry }: Vec2.Vec2);
        ViewRoad.shadowUnder({ at = at, radii = radii, segs = RawDraw.ellipseSegsFor(radii),
                               alpha = ViewRoad.shadowAlpha(uc), z = z(uc) })

    def z(uc: Float64): Int32 = Proj.zOf(uc)

    // ── 速度線（画面全体を流れる縦の光の筋） ──

    /// 速さを線で語る。走行中 14 本、ニトロ中は 26 本 + 濃く、走っていない場面は薄く残す
    /// （完全に止めない — タイトルでも「速いゲームだ」と伝える）。
    /// 線を置くのは路面の上と画面の左右の縁だけ、y も地平線より下だけ。空・海・草に散らすと
    /// 「速い」ではなく「画面に傷が入っている」と読まれる。
    pub def speedLines(cam: Proj.Cam, w: World.World): List[Render.PlacedItem] =
        let racing = World.isRacing(w);
        let nitroOn = racing and w#nitroLeft > 0.0;
        let count = if (nitroOn) 26 else 14;
        let strength = if (not racing) 0.4 else if (nitroOn) 1.6 else 1.0;
        let top0 = Proj.horizonYAt(cam);
        let span = World.designH() - top0 + 80.0;
        let lane = roadScreenSpan(cam, w);
        let vanish = World.designW() / 2.0;
        Fx.derive(count, w#t, (_i, rand, t) -> {
            let sp = 240.0 + rand(1) * 320.0;
            let y0 = Float64.max(top0, top0 + Num.wrapTo(span, rand(2) * span + t * sp) - 40.0);
            // 地平線で 0・画面の下端で 1。線の太さ・濃さ・置ける横幅を全部これで細める
            // （手前ほど景色が速く流れるので、線も手前ほど強い）。
            let near = Num.clamp01((y0 - top0) / (World.designH() - top0));
            let onEdge = rand(5) < 0.3;
            let x = if (onEdge) {
                    let m = 3.0 + rand(6) * 11.0;
                    if (rand(7) < 0.5) m else World.designW() - m
                } else {
                    let l = vanish + (lane#l - vanish) * near;
                    l + rand(0) * (lane#r - lane#l) * near
                };
            let len = (14.0 + rand(3) * 22.0) * (0.25 + 0.75 * near);
            RawDraw.lineSeg({ x = x, y = y0 }, { x = x, y = y0 + len }, 1.0,
                    ThemeDoc.rec(w#theme)#text, zSpeed())
                |> Render.overItem(item -> item
                    |> Render.fade(
                           Num.clamp01(strength * near * (0.10 + rand(4) * 0.10)))
                    |> Render.blended(DrawCmd.BlendMode.Add))
        })

    /// 自機の足元あたりの路面が画面のどこからどこまでか。速度線をここに閉じ込める。
    def roadScreenSpan(cam: Proj.Cam, w: World.World): { l = Float64, r = Float64 } =
        let u = Proj.playerU();
        let e = World.roadEdgeAt(World.playerRowOf(w#distance), w#course);
        { l = Proj.screenX(cam, e#xl, u), r = Proj.screenX(cam, e#xr, u) }
}
