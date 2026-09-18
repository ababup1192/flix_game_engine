// ViewRoad — 地面のセグメント・路面・縁石・白線・スタートライン・アイテム/障害物・タイヤ痕の層。
// コースの 1 行 = 画面のセグメント 1 本。セグメントごとに Proj で台形へ投影して積む。
// 急カーブでは手前のセグメントをさらに割って積む（1 枚の台形だと 1 行の中の折れが直線に見える）。
// 遠くのセグメントほど霞み（hazeTo）に溶かすので、平らな多角形の連なりに奥行きが出る —
// 距離感は色でも語る（縮みだけに頼ると遠くがうるさいまま残る）。
mod ViewRoad {

    // ── z 層（地面 6 / 草の筋 7 / 路面 8 / 縁石・白線・スタートライン 9 / タイヤ痕 10） ──
    def zGround(): Int32 = 6
    def zFurrow(): Int32 = 7
    def zRoad(): Int32 = 8
    def zTrim(): Int32 = 9
    def zSkid(): Int32 = 10

    /// 道まわり全部。セグメントを手前から地平線まで積む + タイヤ痕。
    pub def draw(cam: Proj.Cam, w: World.World): List[Render.PlacedItem] =
        (Proj.segments(w) |> List.flatMap(b -> segment(cam, w, b))) ::: skids(cam, w)

    /// セグメント 1 本 = 全幅の地面 + 路面の台形・縁石・白線・スタートライン + 立ち物。
    /// 道が画面の外まで曲がっていったセグメントは地面だけにする — 草の縦筋も道の端から引くので、
    /// 道ごと画面の外なら筋も見えない（見えない物を積むと遠くのセグメントほど無駄が増える）。
    def segment(cam: Proj.Cam, w: World.World, b: Proj.Segment): List[Render.PlacedItem] =
        let e = stripOf(w, b#n);
        // セグメントの手前辺と奥辺は 1 回だけ引いて全部の層で使い回す（地面・轍・縁石は
        // どれも同じ 2 本の辺の上に点を並べるだけなので、層ごとに引き直す意味がない）。
        let ed = edgesOf(cam, b);
        if (not onScreen(ed, e)) groundStrip(w, ed, b)
        else
            groundStrip(w, ed, b)
                ::: (partsOf(b, e) |> List.flatMap(p -> {
                        let pd = edgesOf(cam, p#seg);
                        furrows(w, pd, p#seg, p#strip)
                            ::: roadFace(cam, w, pd, p#seg, p#strip)
                            ::: kerbs(w, pd, p#seg, p#strip)
                    }))
                ::: laneLine(cam, w, b, e)
                ::: startLine(cam, w, b, e)
                ::: rails(cam, w, b, e)
                ::: props(cam, w, b)

    /// セグメントを細かく割って積む一番奥の u。ここより手前だけ割る。
    def splitFar(): Float64 = 4.0

    /// 手前のセグメントを何枚に割るか。急カーブでは 1 行の中でも道が大きく折れるので、
    /// 1 枚の台形で結ぶと斜辺が定規で引いた直線に見える（道が折れ線になる）。
    def splitInto(): Int32 = 3

    /// セグメントを割った切れ端の並び（奥から手前へ）。roadFace / kerbs / furrows はどれも辺を
    /// edgeAtT から引くので、切れ端の辺を渡すだけで全部の層が一緒に割れる。
    /// 並びが奥からなのはセグメントの並び（Proj.segments）と同じ理由 — 坂では切れ端どうしも重なる。
    def partsOf(b: Proj.Segment, e: Strip): List[{ seg = Proj.Segment, strip = Strip }] =
        let n = if (b#u0 < splitFar()) splitInto() else 1;
        let step = b#du / Int32.toFloat64(n);
        List.range(0, n) |> List.map(k -> {
            let i = n - 1 - k;
            let t0 = Int32.toFloat64(i) / Int32.toFloat64(n);
            let t1 = Int32.toFloat64(i + 1) / Int32.toFloat64(n);
            let a = edgeAtT(e, t0);
            let c = edgeAtT(e, t1);
            { seg = ({ n = b#n, u0 = b#u0 + step * Int32.toFloat64(i), du = step, head = i == 0 }: Proj.Segment),
              strip = { xl0 = a#xl, xr0 = a#xr, xl1 = c#xl, xr1 = c#xr } }
        })

    /// セグメント 1 本ぶんの手前辺と奥辺。
    pub type alias Edges = { near = Proj.Edge, far = Proj.Edge }

    /// セグメントの手前辺（u0）と奥辺（u0+du）を引く。
    def edgesOf(cam: Proj.Cam, b: Proj.Segment): Edges =
        { near = Proj.edgeOf(cam, b#u0), far = Proj.edgeOf(cam, b#u0 + b#du) }

    /// そのセグメントの道が画面に掛かっているか。手前辺と奥辺の左右 4 点で見る。
    def onScreen(ed: Edges, e: Strip): Bool =
        let xs = Proj.edgeX(ed#near, e#xl0) :: Proj.edgeX(ed#near, e#xr0)
              :: Proj.edgeX(ed#far, e#xl1) :: Proj.edgeX(ed#far, e#xr1) :: Nil;
        let margin = 60.0;
        List.exists(x -> x > 0.0 - margin, xs) and List.exists(x -> x < World.designW() + margin, xs)

    /// セグメント n の 4 隅（道の中心からの横ずれ px）。手前辺は行 n・奥辺は行 n+1 の左右端を使う —
    /// こうするとセグメント n の奥辺とセグメント n+1 の手前辺が同じ 2 点になり、道が 1 枚の面に繋がる。
    pub def stripOf(w: World.World, n: Int32): Strip =
        let a = World.roadEdgeAt(n, w#course);
        let c = World.roadEdgeAt(n + 1, w#course);
        { xl0 = a#xl, xr0 = a#xr, xl1 = c#xl, xr1 = c#xr }

    /// セグメント 1 本の左右端。0 が手前辺、1 が奥辺。
    pub type alias Strip = { xl0 = Float64, xr0 = Float64, xl1 = Float64, xr1 = Float64 }

    /// セグメントの中を比率 tt（0 = 手前辺, 1 = 奥辺）で進んだ位置の左右端。
    /// セグメントの途中に置く物（白線・スタートライン・ヤシ）も、この 1 本の式から辺を引く。
    pub def edgeAtT(e: Strip, tt: Float64): { xl = Float64, xr = Float64 } =
        { xl = e#xl0 + (e#xl1 - e#xl0) * tt, xr = e#xr0 + (e#xr1 - e#xr0) * tt }

    /// 遠くほど霞ませる割合（式は Proj.hazeAt が正）。
    def fadeOf(u0: Float64): Float64 =
        Proj.hazeAt(u0)

    /// 立ち物の意味色を、その距離ぶんだけ霞ませて引く。路面と同じ関数を通すので、
    /// 木やコーンだけが遠くで色濃く浮くことがない。
    pub def hazedKey(w: World.World, u: Float64, key: String): Color =
        Color.mix(PaletteDoc.resolve(w#palette, key), ThemeDoc.hazeTo(w#theme), Proj.hazeAt(u))

    /// 落ち影の濃さ。霞のぶんだけ薄くする（遠くの影だけ黒く残ると点が散って見える）。
    pub def shadowAlpha(u: Float64): Float64 =
        0.28 * (1.0 - Proj.hazeAt(u))

    /// 接地影の楕円 1 枚。立ち物・車の足元はぜんぶここから敷く（形と濃さの式を散らさない）。
    /// segs は縁の分割数 — 主役の車は既定の 32、遠くに何百と撒く立ち物は大きさなりに減らす。
    pub def shadowUnder(s: { at = Vec2.Vec2, radii = Vec2.Vec2, segs = Int32,
                             alpha = Float64, z = Int32 }): Render.PlacedItem =
        RawDraw.ellipseSegsAt(s#at, s#radii, s#segs,
                { r = 0.0, g = 0.0, b = 0.0 }, s#z)
            |> Render.overItem(Render.fade(s#alpha))

    /// 通し行の偶奇。OutRun 式の 1 行おきの縞は全部この判定に揃える
    /// （地面・路面・縁石が同じ行で同時に切り替わり、セグメントの境目が 1 本の線になる）。
    def even(n: Int32): Bool =
        Int32.modulo(n, 2) == 0

    // ── 地面のセグメント（全幅） ──

    /// 距離 u の霞みを色に掛ける。
    def hazed(w: World.World, u: Float64, c: Color): Color =
        Color.mix(c, ThemeDoc.hazeTo(w#theme), fadeOf(u))

    /// 草の明暗を「通し行の実数」から連続で引く（0 = 影側, 1 = 日向側）。
    /// 波の周期を画面に入る行数（34 本）より長く取り、振れ幅も 0.5 まで詰める —
    /// 1〜2 行の周期で振ると、手前のセグメントは 1 本が 40px を超えるので明暗が横縞の階段として読める。
    /// 周期の違う 2 本を重ねるのは、1 本だけだと明暗の切り替わる高さが等間隔に並んで
    /// やはり縞に見えるため。位相は縦の筋（furrowOffAt の周期 ≒ 7 行）と揃えない。
    def grassShadeAt(rowF: Float64): Float64 =
        let tau = 2.0 * Vec2.pi();
        0.5 + 0.30 * Vec2.cos(tau * rowF / 23.0)
            + 0.14 * Vec2.cos(tau * rowF / 9.5 + 1.7)

    /// 通し行の実数 rowF での草の色（霞み前）。
    def grassBaseAt(theme: ThemeDoc.Doc, rowF: Float64): Color =
        Color.mix(ThemeDoc.grassDark(theme), ThemeDoc.grassLight(theme), grassShadeAt(rowF))

    /// 通し行 rowF・距離 u での草の色（霞み込み）。地面のセグメントと、その先の平野
    /// （ViewScene.plain）が同じ 1 本の式から色を引くための共通の関数 — 別々に組むと、
    /// セグメントの切れる高さで色が急に変わる。
    pub def grassAt(w: World.World, rowF: Float64, u: Float64): Color =
        hazed(w, u, grassBaseAt(w#theme, rowF))

    /// セグメントの全幅を草色で敷く。手前辺と奥辺で別の色を渡した 1 枚の面にするので、
    /// 明暗の波も霞みもセグメントをまたいで滑らかに繋がる。路面はこの上に重なるので、
    /// 道から外れた所は草のまま残る（fail-open の土台 — 路面の無い行でも画面に穴が開かない）。
    def groundStrip(w: World.World, ed: Edges, b: Proj.Segment): List[Render.PlacedItem] =
        let u1 = b#u0 + b#du;
        let yTop = ed#far#y;
        let yBot = ed#near#y + 0.6;
        let far = hazed(w, u1, grassBaseAt(w#theme, Int32.toFloat64(b#n) + b#du));
        let near = hazed(w, b#u0, grassBaseAt(w#theme, Int32.toFloat64(b#n)));
        let wide = World.designW();
        { at = { x = 0.0, y = 0.0 },
          item = Render.gradPolygon(
                 { pos = { x = 0.0, y = yTop },   color = far,  alpha = 1.0 }
              :: { pos = { x = wide, y = yTop },  color = far,  alpha = 1.0 }
              :: { pos = { x = wide, y = yBot },  color = near, alpha = 1.0 }
              :: { pos = { x = 0.0, y = yBot },   color = near, alpha = 1.0 }
              :: Nil, zGround()) } :: Nil

    // ── 草地の縦の筋（乾いた路肩・轍） ──

    /// 筋の並び。off = 道の端から外へ離す基準の px（実際の位置は furrowOffAt が揺らす）、
    /// wid = 幅の px、mix = 砂色をどれだけ混ぜるか。off は縁石の幅 6px より外に置く。
    def furrowLanes(): List[{ off = Float64, wid = Float64, mix = Float64 }] =
           { off = 9.0,   wid = 10.0, mix = 0.55 }
        :: { off = 26.0,  wid = 3.0,  mix = 0.34 }
        :: { off = 37.0,  wid = 1.6,  mix = 0.20 }
        :: { off = 58.0,  wid = 5.0,  mix = 0.28 }
        :: { off = 88.0,  wid = 2.6,  mix = 0.18 }
        :: { off = 124.0, wid = 7.0,  mix = 0.24 }
        :: Nil

    /// 筋 i が通し行 rowF の所で道からどれだけ離れているか。行の実数で揺らすので、
    /// 隣り合うセグメントは境目で必ず同じ位置になり、線が折れずに 1 本のうねりとして繋がる
    /// （定規で引いた直線のままだと、光の筋のように見えて草地に読めない）。
    def furrowOffAt(lane: { off = Float64, wid = Float64, mix = Float64 },
                    i: Int32, rowF: Float64): Float64 =
        lane#off + 2.5 * Vec2.sin(rowF * 0.9 + Int32.toFloat64(i) * 2.1)

    /// 筋を描く一番奥の u。これより遠いセグメントは霞みで筋が消えるので、部品を積まない。
    def furrowFar(): Float64 = 14.0

    /// 草地の縦の筋。道の左右端から一定距離だけ外へ離した細い台形を、セグメントの手前辺と奥辺で
    /// 結ぶ。道と同じ折れ込みで曲がるので、カーブで景色が回って見える
    /// （横のセグメントだけだと、曲がっているのに景色は真っ直ぐ迫るように読めてしまう）。
    def furrows(w: World.World, ed: Edges, b: Proj.Segment,
                e: Strip): List[Render.PlacedItem] =
        if (b#u0 > furrowFar()) Nil
        else {
            let u0 = b#u0;
            let u1 = b#u0 + b#du;
            let y0 = ed#near#y + 0.6;
            let y1 = ed#far#y;
            let rowNear = Int32.toFloat64(b#n);
            let rowFar = rowNear + b#du;
            let nearGrass = grassBaseAt(w#theme, rowNear);
            let farGrass = grassBaseAt(w#theme, rowFar);
            furrowLanes() |> List.zipWithIndex |> List.flatMap(entry -> {
                let (i, lane) = entry;
                let o0 = furrowOffAt(lane, i, rowNear);
                let o1 = furrowOffAt(lane, i, rowFar);
                let near = hazed(w, u0, Color.mix(nearGrass, ThemeDoc.rec(w#theme)#sand, lane#mix));
                let far = hazed(w, u1, Color.mix(farGrass, ThemeDoc.rec(w#theme)#sand, lane#mix));
                let quad = g ->
                    { at = { x = 0.0, y = 0.0 },
                      item = Render.gradPolygon(
                             { pos = { x = Proj.edgeX(ed#near, g#nearA), y = y0 }, color = near, alpha = 1.0 }
                          :: { pos = { x = Proj.edgeX(ed#near, g#nearB), y = y0 }, color = near, alpha = 1.0 }
                          :: { pos = { x = Proj.edgeX(ed#far, g#farB),   y = y1 }, color = far,  alpha = 1.0 }
                          :: { pos = { x = Proj.edgeX(ed#far, g#farA),   y = y1 }, color = far,  alpha = 1.0 }
                          :: Nil, zFurrow()) };
                quad({ nearA = e#xl0 - o0 - lane#wid, nearB = e#xl0 - o0,
                       farA  = e#xl1 - o1 - lane#wid, farB  = e#xl1 - o1 })
                    :: quad({ nearA = e#xr0 + o0, nearB = e#xr0 + o0 + lane#wid,
                              farA  = e#xr1 + o1, farB  = e#xr1 + o1 + lane#wid })
                    :: Nil
            })
        }

    // ── 路面（台形）と縁石と白線 ──

    /// 路面の台形 1 枚 + アスファルトの質感（轍・中央の色抜け・端の汚れ・継ぎ目）。
    /// 下地は行の偶奇の縞、手前辺と奥辺で霞みを変えた連続階調にする。
    def roadFace(cam: Proj.Cam, w: World.World, ed: Edges, b: Proj.Segment,
                 e: Strip): List[Render.PlacedItem] =
        let segColor = if (even(b#n)) ThemeDoc.rec(w#theme)#road else ThemeDoc.roadLight(w#theme);
        let u1 = b#u0 + b#du;
        let base = gradQuad(ed, e,
            { t0 = 0.0, t1 = 1.0,
              near = hazed(w, b#u0, segColor), far = hazed(w, u1, segColor) });
        base :: (wearLanes(w, ed, b, e, segColor) ::: seam(cam, w, ed, b, e, segColor))

    /// 路面を縦に切るストリップ。t は道幅の比率（0 = 左端, 1 = 右端）、tint は下地からの寄せ幅
    /// （負 = 暗い汚れ・轍、正 = 日に灼けて色が抜けた所）。数はわざと少なくして、
    /// 縞の下地が読める程度の弱い階調に留める。
    def wearLaneSpecs(): List[{ t0 = Float64, t1 = Float64, tint = Float64 }] =
           { t0 = 0.00, t1 = 0.10, tint = -0.16 }
        :: { t0 = 0.19, t1 = 0.33, tint = -0.09 }
        :: { t0 = 0.44, t1 = 0.56, tint =  0.09 }
        :: { t0 = 0.67, t1 = 0.81, tint = -0.09 }
        :: { t0 = 0.90, t1 = 1.00, tint = -0.16 }
        :: Nil

    /// 質感を積む一番奥の u。これより遠いとセグメントが 1px を切って轍が縞のノイズに見えるので、
    /// 下地の階調だけに任せる。
    def wearFar(): Float64 = 17.0

    /// 轍・中央の色抜け・端の汚れ。道幅の比率で切るので、カーブでも道と一緒に折れて曲がる。
    def wearLanes(w: World.World, ed: Edges, b: Proj.Segment,
                  e: Strip, segColor: Color): List[Render.PlacedItem] =
        if (b#u0 > wearFar()) Nil
        else {
            let u1 = b#u0 + b#du;
            wearLaneSpecs() |> List.map(s -> {
                let c = if (s#tint < 0.0) Color.darken(segColor, -s#tint)
                        else Color.mix(segColor, ThemeDoc.rec(w#theme)#lane, s#tint);
                gradQuad(ed, e,
                    { t0 = s#t0, t1 = s#t1,
                      near = hazed(w, b#u0, c), far = hazed(w, u1, c) })
            })
        }

    /// 継ぎ目を何行おきに入れるか。縁石と同じく奥では周期を粗くする — 1 行おきのままだと
    /// 遠くで継ぎ目どうしが同じ画素に潰れ、路面全体が均一に暗い板になる。
    def seamPeriodAt(u: Float64): Int32 =
        if (u < 8.0) 2
        else if (u < 14.0) 4
        else 8

    /// 舗装の継ぎ目。セグメントの手前端に横 1 本の暗い筋を渡す。
    def seam(cam: Proj.Cam, w: World.World, ed: Edges, b: Proj.Segment,
             e: Strip, segColor: Color): List[Render.PlacedItem] =
        if (not b#head or b#u0 > wearFar() or Int32.modulo(b#n, seamPeriodAt(b#u0)) != 0) Nil
        else {
            let u1 = b#u0 + 0.16;
            let g = edgeAtT(e, 0.16);
            let sub = { xl0 = e#xl0, xr0 = e#xr0, xl1 = g#xl, xr1 = g#xr };
            let c = Color.darken(segColor, 0.22);
            let sd = { near = ed#near, far = Proj.edgeOf(cam, u1) };
            gradQuad(sd, sub,
                { t0 = 0.0, t1 = 1.0,
                  near = hazed(w, b#u0, c), far = hazed(w, u1, c) }) :: Nil
        }

    /// セグメントの一部（道幅の比率 t0..t1、行の u0..u1）を、手前色 near・奥色 far の連続階調で塗る。
    def gradQuad(ed: Edges, e: Strip,
                 q: { t0 = Float64, t1 = Float64,
                      near = Color, far = Color }): Render.PlacedItem =
        let lerp = (a, bb, t) -> a + (bb - a) * t;
        let y0 = ed#near#y;
        let y1 = ed#far#y;
        let xn = t -> Proj.edgeX(ed#near, lerp(e#xl0, e#xr0, t));
        let xf = t -> Proj.edgeX(ed#far, lerp(e#xl1, e#xr1, t));
        { at = { x = 0.0, y = 0.0 },
          item = Render.gradPolygon(
                 { pos = { x = xn(q#t0), y = y0 }, color = q#near, alpha = 1.0 }
              :: { pos = { x = xn(q#t1), y = y0 }, color = q#near, alpha = 1.0 }
              :: { pos = { x = xf(q#t1), y = y1 }, color = q#far,  alpha = 1.0 }
              :: { pos = { x = xf(q#t0), y = y1 }, color = q#far,  alpha = 1.0 }
              :: Nil, zRoad()) }

    /// 縁石の縞を何行で 1 色にするか。奥はセグメントが細くなり、1 行おきのままだと赤と白が同じ
    /// 画素に潰れて「1 本の赤い線」になるので、遠いほど粗くして交互を残す。
    def kerbPeriodAt(u: Float64): Int32 =
        if (u < 8.0) 1
        else if (u < 14.0) 2
        else if (u < 20.0) 4
        else 8

    /// 縁石。路面の左右のすぐ外に幅 6px（×縮み）のストリップを貼る。赤と白が交互に並ぶので、
    /// 道の縁がカーブでどう曲がるかが一番よく見える場所になる。
    def kerbs(w: World.World, ed: Edges, b: Proj.Segment,
              e: Strip): List[Render.PlacedItem] =
        let base = if (even(b#n / kerbPeriodAt(b#u0))) ThemeDoc.rec(w#theme)#kerb else ThemeDoc.rec(w#theme)#finish;
        let color = Color.mix(base, ThemeDoc.hazeTo(w#theme), fadeOf(b#u0));
        let k0 = 6.0 * ed#near#k;
        let k1 = 6.0 * ed#far#k;
        let y0 = ed#near#y;
        let y1 = ed#far#y;
        let l0 = Proj.edgeX(ed#near, e#xl0);
        let l1 = Proj.edgeX(ed#far, e#xl1);
        let r0 = Proj.edgeX(ed#near, e#xr0);
        let r1 = Proj.edgeX(ed#far, e#xr1);
        let poly = vs -> { at = { x = 0.0, y = 0.0 }, item = RawDraw.polygon(vs, color, zTrim()) };
        poly({ x = l0 - k0, y = y0 } :: { x = l0, y = y0 }
             :: { x = l1, y = y1 } :: { x = l1 - k1, y = y1 } :: Nil)
            :: poly({ x = r0, y = y0 } :: { x = r0 + k0, y = y0 }
                    :: { x = r1 + k1, y = y1 } :: { x = r1, y = y1 } :: Nil)
            :: Nil

    /// 中央の白線。偶数行だけセグメントの 0.2..0.8 区間に引く = 破線。実線にしないのは、
    /// 流れる切れ目が前進の速さをそのまま伝えるから（速度計より雄弁）。
    def laneLine(cam: Proj.Cam, w: World.World, b: Proj.Segment,
                 e: Strip): List[Render.PlacedItem] =
        if (not even(b#n)) Nil
        else {
            let mid = tt -> { let g = edgeAtT(e, tt); (g#xl + g#xr) / 2.0 };
            let ua = b#u0 + 0.2;
            let ub = b#u0 + 0.8;
            let ha = 1.25 * Proj.scaleOf(ua);
            let hb = 1.25 * Proj.scaleOf(ub);
            let xa = Proj.screenX(cam, mid(0.2), ua);
            let xb = Proj.screenX(cam, mid(0.8), ub);
            let color = Color.mix(ThemeDoc.rec(w#theme)#lane, ThemeDoc.hazeTo(w#theme), fadeOf(b#u0));
            { at = { x = 0.0, y = 0.0 },
              item = RawDraw.polygon(
                     { x = xa - ha, y = Proj.yAt(cam, ua) }
                  :: { x = xa + ha, y = Proj.yAt(cam, ua) }
                  :: { x = xb + hb, y = Proj.yAt(cam, ub) }
                  :: { x = xb - hb, y = Proj.yAt(cam, ub) }
                  :: Nil, color, zTrim()) } :: Nil
        }

    /// スタート/ゴールライン。コース 1 周の先頭行に白帯 + 市松。台形でなく箱で近似する
    /// （checker は Item 修飾なので箱に掛けるのが素直 — 幅 0.4 行の帯なら歪みは見えない）。
    /// タイトルでは出さない。まだ走り出していないのに足元にゴール板があると、
    /// 「もう 1 周終わった所」と読めてしまう。
    def startLine(cam: Proj.Cam, w: World.World, b: Proj.Segment,
                  e: Strip): List[Render.PlacedItem] =
        if (w#phase == World.Phase.Title) Nil
        else if (Int32.modulo(b#n, CourseDoc.rowCount(w#course)) != 0) Nil
        else {
            let ua = b#u0 + 0.25;
            let k = Proj.scaleOf(ua);
            let g = edgeAtT(e, 0.25);
            let yTop = Proj.yAt(cam, b#u0 + 0.45);
            let yBot = Proj.yAt(cam, b#u0 + 0.05);
            let cx = (Proj.screenX(cam, g#xl, ua) + Proj.screenX(cam, g#xr, ua)) / 2.0;
            let banner = RawDraw.boxAt({ x = cx, y = (yTop + yBot) / 2.0 },
                    { x = (g#xr - g#xl) * k, y = yBot - yTop }, ThemeDoc.rec(w#theme)#finish, zTrim())
                |> Render.overItem(Render.checker(
                       { color = Color.darken(ThemeDoc.rec(w#theme)#road, 0.35), alpha = 1.0,
                         cell = Float64.max(2.0, 4.0 * k) }));
            banner :: Nil
        }

    // ── ガードレール（コーナーの外側の壁） ──

    /// 壁の高さ（世界 px）。縁石の 6px より高くして、路面の縁とは別の物に見せる。
    def railH(): Float64 = 12.0

    /// ガードレール。セグメントの左右どちらに立つかは区間の rail（World.railSideAt）が決める。
    /// セグメントの手前辺と奥辺を結ぶ 2 枚の面（明るい上側 + 影の下側）で 1 本の板にし、
    /// セグメントの頭には支柱を立てる。壁は道と同じ折れで曲がるので、コーナーの外周がなぞれる。
    def rails(cam: Proj.Cam, w: World.World, b: Proj.Segment, e: Strip): List[Render.PlacedItem] =
        let side = World.railSideAt(b#n, w);
        if (side == 0.0 or b#u0 > 20.0) Nil
        else {
            let u0 = b#u0;
            let u1 = b#u0 + b#du;
            let k0 = Proj.scaleOf(u0);
            let k1 = Proj.scaleOf(u1);
            let x0 = Proj.screenX(cam, if (side < 0.0) e#xl0 else e#xr0, u0);
            let x1 = Proj.screenX(cam, if (side < 0.0) e#xl1 else e#xr1, u1);
            let g0 = Proj.yAt(cam, u0);
            let g1 = Proj.yAt(cam, u1);
            let beam = spec -> {
                let c = Color.mix(spec#color, ThemeDoc.hazeTo(w#theme), fadeOf(u0));
                { at = { x = 0.0, y = 0.0 },
                  item = RawDraw.polygon(
                         { x = x0, y = g0 - railH() * k0 * spec#top }
                      :: { x = x1, y = g1 - railH() * k1 * spec#top }
                      :: { x = x1, y = g1 - railH() * k1 * spec#bot }
                      :: { x = x0, y = g0 - railH() * k0 * spec#bot }
                      :: Nil, c, zTrim() + 1) }
            };
            let posts = if (not b#head or u0 > 14.0) Nil
                else RawDraw.boxAt({ x = x0, y = g0 - railH() * k0 * 0.35 },
                        { x = Float64.max(1.0, 2.2 * k0), y = railH() * k0 * 0.7 },
                        Color.mix(Color.darken(ThemeDoc.rec(w#theme)#road, 0.55), ThemeDoc.hazeTo(w#theme),
                                  fadeOf(u0)), zTrim() + 1) :: Nil;
            beam({ top = 1.0, bot = 0.58, color = Color.lighten(ThemeDoc.rec(w#theme)#finish, 0.06) })
                :: beam({ top = 0.58, bot = 0.30, color = Color.darken(ThemeDoc.rec(w#theme)#road, 0.45) })
                :: posts
        }

    // ── アイテム・障害物（路面の上の立ち物） ──

    /// このセグメントの立ち物。置き場所をセグメントの真ん中（u0+0.5）に投影して置く。
    /// 当たりの範囲（World.blockersAt）から絵を引くので、見えている物と当たる物がずれない。
    def props(cam: Proj.Cam, w: World.World, b: Proj.Segment): List[Render.PlacedItem] =
        itemsOf(cam, w, b) ::: blockersOf(cam, w, b)

    /// アイテム箱。取った行（taken は通し行番号の集合）は描かない — 消えることが取得の合図。
    /// ふわふわ浮かせ + 金の光で「取って良い物」だと遠目にも判るようにする。
    def itemsOf(cam: Proj.Cam, w: World.World, b: Proj.Segment): List[Render.PlacedItem] =
        if (Set.memberOf(b#n, w#taken)) Nil
        else World.itemOffsAt(b#n, w) |> List.flatMap(propOff -> {
            let uc = b#u0 + 0.5;
            let f = Proj.scaleOf(uc) * 1.6;
            let x = Proj.screenX(cam, propOff, uc);
            let groundY = Proj.yAt(cam, uc);
            let z = Proj.zOf(uc);
            let bob = Sway.wave(w#t, Int32.toFloat64(b#n) * 0.7, 0.9) * 2.0;
            let center = { x = x, y = groundY - 5.0 * f - 2.0 + bob };
            let shadow = shadowUnder({ at = { x = x, y = groundY },
                    radii = { x = 4.0 * f, y = 1.4 * f }, segs = 32,
                    alpha = shadowAlpha(uc), z = z });
            let glow = Render.glowAt(center, 7.0 * f, PaletteDoc.resolve(w#palette, "itemGold"),
                    { alpha = 0.3, blend = DrawCmd.BlendMode.Add }, z);
            shadow :: (glow ::: ViewCar.pxScaled(key -> hazedKey(w, uc, key),
                { doc = w#sprites, sprite = "item", at = center,
                  flipX = false, f = f, turn = 0.0, z = z }))
        })

    /// 障害物 3 種。どれも「当たりの範囲」1 つが絵 1 つに対応する。
    def blockersOf(cam: Proj.Cam, w: World.World, b: Proj.Segment): List[Render.PlacedItem] =
        let uc = b#u0 + 0.5;
        // 通り過ぎたセグメント（uc < 0.15）は描かない。真横〜背後のセグメントは画面いっぱいの板になるだけで、
        // 何が起きているかを伝えない。
        if (uc < 0.15 or uc > 20.0) Nil
        else World.blockersAt(b#n, w) |> List.flatMap(bl ->
            match bl#kind {
                case PropsDoc.Kind.Cone => coneAt(cam, w, uc, (bl#lo + bl#hi) / 2.0)
                case PropsDoc.Kind.Gate => pipeAt(cam, w, b#n, uc, bl)
                case PropsDoc.Kind.Bar  => barAt(cam, w, b#n, uc, bl)
                case PropsDoc.Kind.Item => Nil
            })

    /// コーン。地面に据え置き（浮かせない — 当たると痛い物は地に足が着いて見えるべき）。
    def coneAt(cam: Proj.Cam, w: World.World, uc: Float64,
               propOff: Float64): List[Render.PlacedItem] =
        let f = Proj.scaleOf(uc) * 1.6;
        let x = Proj.screenX(cam, propOff, uc);
        let groundY = Proj.yAt(cam, uc);
        let z = Proj.zOf(uc);
        let shadow = shadowUnder({ at = { x = x, y = groundY },
                radii = { x = 4.0 * f, y = 1.4 * f }, segs = 32,
                alpha = shadowAlpha(uc), z = z });
        shadow :: ViewCar.pxScaled(key -> hazedKey(w, uc, key),
            { doc = w#sprites, sprite = "cone", at = { x = x, y = groundY - 4.0 * f },
              flipX = false, f = f, turn = 0.0, z = z })

    /// 横たわった管の直径・立った土管の高さと半径（世界 px）。土管は自機のドット絵
    /// （27px）と同じくらいの背丈にする — 見上げるほど高いと門でなくトンネルに読める。
    def tubeDia(): Float64 = 9.0
    def postH(): Float64 = 36.0
    def postR(): Float64 = 7.0

    /// 縁（口のまわり）が軸より太る割合。ここが真っ直ぐだと管ではなく丸い棒に見える。
    def postLip(): Float64 = 1.35

    /// 土管の地肌（素焼きの土の色）。路面の灰とも縁石の白とも違う暖色にしておかないと、
    /// 立った土管と横たわった管が 1 枚の白い板に溶ける。
    def clayOf(theme: ThemeDoc.Doc): Color =
        Color.warm(Color.darken(ThemeDoc.rec(theme)#sand, 0.10), 0.06)

    /// 円筒の丸み（0 = 影の側, 1 = 日の当たる側）。単色の面 1 枚では、どれだけ高さを
    /// 取っても路面に貼ったシールに見えるので、丸みは必ずこの階調で出す。
    def roundStops(base: Color): List[{ t = Float64, color = Color }] =
           { t = 0.00, color = Color.cool(Color.darken(base, 0.44), 0.14) }
        :: { t = 0.24, color = Color.cool(Color.darken(base, 0.24), 0.08) }
        :: { t = 0.62, color = base }
        :: { t = 0.88, color = Color.warm(Color.lighten(base, 0.12), 0.05) }
        :: { t = 1.00, color = Color.warm(Color.lighten(base, 0.04), 0.03) }
        :: Nil

    /// 円筒の面を階調で塗る。stops の t を、横たわった管なら高さに・立った土管なら
    /// 左右の位置に読み替えるので、2 つの向きを 1 つの階調表で描ける。
    /// axis が true = t が高さ（下から上へ）、false = t が横（左から右へ）。
    def roundFace(q: { xl = Float64, xr = Float64, yBot = Float64, yTop = Float64,
                       axis = Bool, z = Int32 },
                  stops: List[{ t = Float64, color = Color }]): List[Render.PlacedItem] =
        let yOfT = t -> q#yBot + (q#yTop - q#yBot) * t;
        let xOfT = t -> q#xl + (q#xr - q#xl) * t;
        List.zip(stops, List.drop(1, stops)) |> List.map(pair -> {
            let (a, b) = pair;
            let vs = if (q#axis)
                    { pos = { x = q#xl, y = yOfT(b#t) }, color = b#color, alpha = 1.0 }
                 :: { pos = { x = q#xr, y = yOfT(b#t) }, color = b#color, alpha = 1.0 }
                 :: { pos = { x = q#xr, y = yOfT(a#t) }, color = a#color, alpha = 1.0 }
                 :: { pos = { x = q#xl, y = yOfT(a#t) }, color = a#color, alpha = 1.0 }
                 :: Nil
                else
                    { pos = { x = xOfT(a#t), y = q#yTop }, color = a#color, alpha = 1.0 }
                 :: { pos = { x = xOfT(b#t), y = q#yTop }, color = b#color, alpha = 1.0 }
                 :: { pos = { x = xOfT(b#t), y = q#yBot }, color = b#color, alpha = 1.0 }
                 :: { pos = { x = xOfT(a#t), y = q#yBot }, color = a#color, alpha = 1.0 }
                 :: Nil;
            { at = { x = 0.0, y = 0.0 }, item = Render.gradPolygon(vs, q#z) }
        })

    /// 土管ゲート 1 本ぶん = 隙間ぎわに立つ太い土管 + 残りを塞ぐ横たわった管。
    /// 当たりの範囲（World.blockersAt）は草の上まで続いているが、絵は道幅の中で止める —
    /// 道の外まで伸ばすと「隙間を通す門」ではなく地面に敷いた板に読める。
    def pipeAt(cam: Proj.Cam, w: World.World, n: Int32, uc: Float64,
               bl: World.Blocker): List[Render.PlacedItem] =
        let e = edgeAtT(stripOf(w, n), 0.5);
        let lo = Float64.max(bl#lo, e#xl - 4.0);
        let hi = Float64.min(bl#hi, e#xr + 4.0);
        if (hi - lo < 1.0) Nil
        else {
            // 隙間はゲートの内側 = 当たりの範囲が道の外へ食み出していない方の端。
            let gapAtHi = bl#lo < e#xl;
            let mouth = if (gapAtHi) hi else lo;
            let inward = if (gapAtHi) 0.0 - 1.0 else 1.0;
            let cx = mouth + inward * postR() * postLip();
            tubeOf(cam, w, { uc = uc, lo = lo, hi = hi })
                ::: postOf(cam, w, { uc = uc, cx = Num.clamp(lo, hi, cx) })
        }

    /// 横たわった管。上下の階調で丸みを出し、奥へ続く天面と路面への落ち影を別に置く
    /// （天面が無いと、丸めても厚みの無い面に見える）。
    def tubeOf(cam: Proj.Cam, w: World.World,
               s: { uc = Float64, lo = Float64, hi = Float64 }): List[Render.PlacedItem] =
        let back = s#uc + 0.18;
        let kf = Proj.scaleOf(s#uc);
        let kb = Proj.scaleOf(back);
        let gf = Proj.yAt(cam, s#uc);
        let gb = Proj.yAt(cam, back);
        let z = Proj.zOf(s#uc);
        let tint = c -> Color.mix(c, ThemeDoc.hazeTo(w#theme), Proj.hazeAt(s#uc));
        let xl = Proj.screenX(cam, s#lo, s#uc);
        let xr = Proj.screenX(cam, s#hi, s#uc);
        let bl2 = Proj.screenX(cam, s#lo, back);
        let br2 = Proj.screenX(cam, s#hi, back);
        let topY = gf - tubeDia() * kf;
        let backTopY = gb - tubeDia() * kb;
        let crown = tint(Color.warm(Color.lighten(clayOf(w#theme), 0.12), 0.05));
        let shadow = { at = { x = 0.0, y = 0.0 },
                       item = RawDraw.polygon(
                              { x = bl2, y = gb } :: { x = br2, y = gb }
                           :: { x = xr, y = gf }  :: { x = xl, y = gf }
                           :: Nil, { r = 0.0, g = 0.0, b = 0.0 }, z)
                           |> Render.fade(shadowAlpha(s#uc)) };
        let top = { at = { x = 0.0, y = 0.0 },
                    item = RawDraw.polygon(
                           { x = bl2, y = backTopY } :: { x = br2, y = backTopY }
                        :: { x = xr, y = topY } :: { x = xl, y = topY }
                        :: Nil, crown, z) };
        shadow :: top
            :: roundFace({ xl = xl, xr = xr, yBot = gf, yTop = topY, axis = true, z = z },
                         roundStops(clayOf(w#theme)) |> List.map(st ->
                             { t = st#t, color = tint(st#color) }))

    /// 立った土管。軸 → 太った縁 → 口の楕円の順に積む。口を開けるのは、
    /// てっぺんが塞がっていると柱にしか見えないため。
    def postOf(cam: Proj.Cam, w: World.World,
               s: { uc = Float64, cx = Float64 }): List[Render.PlacedItem] =
        let kf = Proj.scaleOf(s#uc);
        let gf = Proj.yAt(cam, s#uc);
        let z = Proj.zOf(s#uc);
        let tint = c -> Color.mix(c, ThemeDoc.hazeTo(w#theme), Proj.hazeAt(s#uc));
        let x = Proj.screenX(cam, s#cx, s#uc);
        let rs = postR() * kf;
        let rl = postR() * postLip() * kf;
        let topY = gf - postH() * kf;
        let lipY = gf - postH() * kf * 0.80;
        let stopsOf = base -> roundStops(base) |> List.map(st ->
            { t = st#t, color = tint(st#color) });
        let cap = RawDraw.ellipseAt({ x = x, y = topY }, { x = rl, y = rl * 0.40 },
                                   tint(Color.lighten(ThemeDoc.rec(w#theme)#kerb, 0.14)), z);
        let hole = RawDraw.ellipseAt({ x = x, y = topY },
                                    { x = rl * 0.62, y = rl * 0.40 * 0.62 },
                                    tint(Color.darken(ThemeDoc.rec(w#theme)#road, 0.52)), z);
        shadowUnder({ at = { x = x, y = gf }, radii = { x = rl * 1.15, y = rl * 0.42 },
                      segs = 32, alpha = shadowAlpha(s#uc), z = z })
            :: (roundFace({ xl = x - rs, xr = x + rs, yBot = gf, yTop = lipY,
                            axis = false, z = z }, stopsOf(clayOf(w#theme)))
                ::: roundFace({ xl = x - rl, xr = x + rl, yBot = lipY, yTop = topY,
                                axis = false, z = z }, stopsOf(ThemeDoc.rec(w#theme)#kerb))
                ::: (cap :: hole :: Nil))

    /// 振り子バー。振れ幅の跡 → 真下の落ち影 → 浮いた横棒（斜め縞）→ 両端の握りの順に積む。
    /// 跡を敷くのは、静止した 1 枚では動く物だと読めないため — 振れる範囲の中を往復すると判れば、
    /// どちら側へ逃げるかを差し掛かる前に決められる。落ち影と横棒を離すのは、
    /// くっつけると路面に描いた白線に見えるため。
    def barAt(cam: Proj.Cam, w: World.World, n: Int32, uc: Float64,
              bl: World.Blocker): List[Render.PlacedItem] =
        let k = Proj.scaleOf(uc);
        let groundY = Proj.yAt(cam, uc);
        let z = Proj.zOf(uc);
        let tint = c -> Color.mix(c, ThemeDoc.hazeTo(w#theme), Proj.hazeAt(uc));
        let l = Proj.screenX(cam, bl#lo, uc);
        let r = Proj.screenX(cam, bl#hi, uc);
        let cx = (l + r) / 2.0;
        let wide = Float64.abs(r - l);
        let lift = 13.0 * k;
        let reach = Float64.max(0.0, World.halfWidthAt(n, w#course) - PropsDoc.rec(w#props)#barHalfWidth)
                    + PropsDoc.rec(w#props)#barHalfWidth;
        let sl = Proj.screenX(cam, 0.0 - reach, uc);
        let sr = Proj.screenX(cam, reach, uc);
        let sweep = RawDraw.boxAt({ x = (sl + sr) / 2.0, y = groundY - lift },
                { x = Float64.abs(sr - sl), y = Float64.max(1.0, 5.0 * k) },
                tint(ThemeDoc.rec(w#theme)#kerb), z)
            |> Render.overItem(Render.fade(0.16));
        let shadow = shadowUnder({ at = { x = cx, y = groundY },
                radii = { x = wide / 2.0, y = Float64.max(1.0, 2.2 * k) },
                segs = 32, alpha = shadowAlpha(uc), z = z });
        let under = RawDraw.boxAt({ x = cx, y = groundY - lift + 2.6 * k },
                { x = wide, y = Float64.max(1.0, 2.2 * k) },
                tint(Color.darken(ThemeDoc.rec(w#theme)#road, 0.42)), z);
        let body = RawDraw.boxAt({ x = cx, y = groundY - lift },
                { x = wide, y = Float64.max(2.0, 5.4 * k) }, tint(ThemeDoc.rec(w#theme)#finish), z)
            |> Render.overItem(Render.striped({ color = tint(ThemeDoc.rec(w#theme)#kerb), alpha = 1.0,
                    width = Float64.max(1.5, 4.0 * k), period = Float64.max(3.0, 8.5 * k),
                    dir = 0 }));
        let grip = xx -> RawDraw.circleAt({ x = xx, y = groundY - lift },
                Float64.max(1.5, 3.8 * k), tint(Color.darken(ThemeDoc.rec(w#theme)#kerb, 0.18)), z);
        sweep :: shadow :: under :: body :: grip(l) :: grip(r) :: Nil

    // ── タイヤ痕（ドリフトの置き土産） ──

    /// タイヤ痕。世界座標のまま持たれている点を毎フレーム投影し、左右後輪の 2 点に
    /// 暗い小箱を置く。turn で回した位置に置くので、滑った角度がそのまま路面に残る。
    def skids(cam: Proj.Cam, w: World.World): List[Render.PlacedItem] =
        let color = Color.darken(ThemeDoc.rec(w#theme)#road, 0.55);
        w#skids |> List.flatMap(s -> {
            let u = Proj.uOf(w, s#dist);
            if (u < -1.2 or u > 14.0) Nil
            else {
                let p = Proj.projectPoint(cam, w, { x = s#off, y = s#dist });
                Render.rotated(s#turn, { x = -5.0, y = 0.0 } :: { x = 5.0, y = 0.0 } :: Nil)
                    |> List.map(o ->
                        RawDraw.boxAt({ x = p#x + o#x * p#k, y = p#y + o#y * p#k },
                                { x = 2.5 * p#k, y = 2.5 * p#k }, color, zSkid())
                            |> Render.overItem(Render.fade(0.5)))
            }
        })
}
