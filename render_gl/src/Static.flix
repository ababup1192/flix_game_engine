// RenderStatic — 「1 度だけ GPU に生成して使い回す静的多角形」をエンジン内部でキャッシュする。
// テクスチャを名前で 1 度だけ GPU に上げて使い回すのと同じ隠蔽: ゲームはキャッシュキー
// （フロア id・テーマ・世代番号などを 1 文字列にまとめた物）と中身の作り方を宣言するだけで、
// GL ハンドルも無効化ロジックも持たない。キーが前回と同じなら生成した VBO を使い回し、
// 変わったら古い VBO を解放して作り直す。
// 注意: 実際の三角形化とアップロードは resolve が行い、毎フレームの描画は範囲だけを
//   RenderFrame へ渡す（頂点は運ばない）。

mod RenderStatic {

    /// 毎フレーム RenderFrame へ渡す 1 レンジの描画情報（頂点は運ばない）。
    /// vao は解決済みの実ハンドル、first/count は永続 VBO 内の頂点範囲、
    /// viewOffset/viewScale は camera を uniform で当てる値。
    pub type alias Range = {
        vao = Int32,
        first = Int32,
        count = Int32,
        blend = DrawCmd.BlendMode,
        clip = Option[Rect2.Rect2],
        zIndex = Int32,
        viewOffset = Vec2.Vec2,
        viewScale = Vec2.Vec2,
        halfDesign = Vec2.Vec2
    }

    /// キャッシュの中身: 生成したときのキーと、その VBO ハンドル・レンジ目次。
    pub type alias Entry = {
        key = DrawCmd.StaticKey,
        vao = GpuHandle.StaticVao,
        metas = List[DrawCmd.StaticPolyMeta]
    }

    /// 静的レイヤー依頼を解決して、この 1 フレームで描くレンジ列を返す。
    /// キャッシュ（cell に入った Option[Entry]）のキーが依頼のキーと一致すれば作り直さず、
    /// 一致しなければ古い VBO を free してから polys を評価・三角形化・アップロードし、
    /// キャッシュを差し替える。cell の更新はこの関数が行う（呼び側は cell を渡すだけ）。
    /// 戻り値の Range 列は依頼の viewOffset/viewScale を各レンジに載せた物。
    pub def resolve(cell: Array[Option[Entry], Static], layer: DrawCmd.StaticLayerCmd): List[Range] \ IO =
        let entry = ensureBaked(cell, layer);
        let vaoInt = GpuHandle.staticVaoInt(entry#vao);
        entry#metas |> List.map(m -> {
            vao = vaoInt, first = m#first, count = m#count,
            blend = m#blend, clip = m#clip, zIndex = m#zIndex,
            viewOffset = layer#viewOffset, viewScale = layer#viewScale,
            halfDesign = layer#halfDesign
        })

    /// キャッシュがキー一致ならそのまま、違えば作り直して返す（cell を更新する副作用つき）。
    def ensureBaked(cell: Array[Option[Entry], Static], layer: DrawCmd.StaticLayerCmd): Entry \ IO =
        match Array.get(0, cell) {
            case Some(e) if e#key == layer#key => e
            case old =>
                // 古い世代があれば必ず free（フロア往復で VBO が増え続けないように）。
                Option.forEach(e -> {
                    RenderSprite.freeStaticPolyVBO(GpuHandle.staticVaoInt(e#vao), GpuHandle.staticVboInt(e#vao))
                }, old);
                let fresh = bake(layer#key, layer#polys());
                Array.put(Some(fresh), 0, cell);
                fresh
        }

    /// 多角形列を z 昇順に並べ、blend / 切り抜き clip 矩形ごとにまとめて三角形化し、1 本の VBO へ
    /// 連続配置する。レンジ目次（z / blend / clip ごとの開始頂点・頂点数）も同時に作る。
    /// 同 z 内は入力順を保つ（動的側の stableByZ と同じ安定性）。
    def bake(key: DrawCmd.StaticKey, polys: List[DrawCmd.PolygonRenderCmd]): Entry \ IO =
        // z 昇順・同 z は入力順（安定）に並べ替える。
        let sorted = stableByZ(pc -> pc#zIndex, polys);
        // 各多角形を三角形化して 6 floats/頂点の配列にし、(頂点配列列, レンジ目次) にまとめる。
        // レンジは「連続する同 z・同 blend・同 clip」でまとめる。
        // 展開（単色の耳切り / grad の扇割り＋頂点色）は RenderSprite.polyVertsRev に共通化。
        let init = { vertsRev = (Nil: List[Array[Float32, Static]]), total = 0,
                     metasRev = (Nil: List[DrawCmd.StaticPolyMeta]),
                     cur = (None: Option[{ z = Int32, blend = DrawCmd.BlendMode,
                                           clip = Option[Rect2.Rect2], start = Int32, count = Int32 }]) };
        let folded = List.foldLeft((acc, pc) -> {
            let (n, polyRev) = RenderSprite.polyVertsRev(pc);
            if (n < 3) acc
            else {
                let verts2 = List.append(polyRev, acc#vertsRev);
                let total2 = acc#total + n;
                // レンジをまとめられるか（同 z・同 blend・同 clip）。Rect2 に Eq が無いので clip は
                // 座標 4 つを直接比べる（clipEq）。
                let sameRange = r -> r#z == pc#zIndex and r#blend == pc#blend and clipEq(r#clip, pc#clip);
                let cur2 = match acc#cur {
                    case Some(r) if sameRange(r) =>
                        Some({ count = r#count + n | r })
                    case _ =>
                        Some({ z = pc#zIndex, blend = pc#blend, clip = pc#clip,
                               start = acc#total, count = n })
                };
                // 直前のレンジを確定するのは cur が切り替わったとき。
                let metasRev2 = match acc#cur {
                    case Some(r) if not sameRange(r) =>
                        { first = r#start, count = r#count, blend = r#blend, clip = r#clip, zIndex = r#z } :: acc#metasRev
                    case _ => acc#metasRev
                };
                { vertsRev = verts2, total = total2, metasRev = metasRev2, cur = cur2 }
            }
        }, init, sorted);
        // 最後のレンジを確定する。
        let metasRev = match folded#cur {
            case None => folded#metasRev
            case Some(r) => { first = r#start, count = r#count, blend = r#blend, clip = r#clip, zIndex = r#z } :: folded#metasRev
        };
        let metas = List.reverse(metasRev);
        // 頂点配列（逆順の cons）を末尾から前へ詰め戻して 1 本の連続配列にする（入力順を守る）。
        let data = Array.empty(Static, folded#total * 6);
        discard List.foldLeft((endIdx, v) -> {
            let base = (endIdx - 1) * 6;
            Array.forEachWithIndex((j, x) -> Array.put(x, base + j, data), v);
            endIdx - 1
        }, folded#total, folded#vertsRev);
        let (vao, vbo) = RenderSprite.buildStaticPolyVBO(data, folded#total);
        { key = key, vao = GpuHandle.wrapStaticVao(vao, vbo), metas = metas }

    /// 2 つの切り抜き clip 矩形が同じか（Rect2 に Eq が無いので座標 4 つを直接比べる）。
    /// None どうしは同じ、片方だけ None は違う。
    def clipEq(a: Option[Rect2.Rect2], b: Option[Rect2.Rect2]): Bool =
        match (a, b) {
            case (None, None)         => true
            case (Some(r1), Some(r2)) =>
                r1#position#x == r2#position#x and r1#position#y == r2#position#y and
                r1#size#x == r2#size#x and r1#size#y == r2#size#y
            case _                    => false
        }

    /// zIndex 昇順・同 z 内は入力順のまま並べ替える（RenderFrame.stableByZ と同じ考え方の局所版）。
    def stableByZ(zOf: a -> Int32, items: List[a]): List[a] =
        let buckets = List.foldLeft((m, x) -> {
            let z = zOf(x);
            let bucket = Map.get(z, m) |> Option.getWithDefault(Nil);
            Map.insert(z, x :: bucket, m)
        }, Map.empty(), items);
        Map.foldRight((bucket, acc) ->
            List.foldLeft((rest, x) -> x :: rest, acc, bucket), Nil, buckets)

}
