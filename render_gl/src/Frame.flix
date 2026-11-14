// RenderFrame — 1 フレームぶんの絵（スプライト・タイル・多角形）を、重なり順に並べて一気に描く。
// 描く順番（zIndex）や画面の縦横比合わせ（黒帯）をこの一箇所に任せられるので、上位は絵の材料を渡すだけでよい。
// 利用例: 毎フレーム、集めた描画物を画面に出す / 手前・奥の重なりを正しく見せる。
// 注意: 同じ zIndex 内は渡された入力順を保つ（安定ソート）。タイル層も動的な描画物と
// 同じ z 空間で並ぶ（同 z なら列に先に積むタイル層が奥 — 手前に出すには大きい zIndex を与える）。
// z 空間は 1 本のまま、HUD の範囲（ZBand.hudBase 以上）のような遠く離れた鍵が混ざるフレームは
// 範囲番号で 2 段階に分けて並べ替える（並び順の決まりは変わらない — 速さのための内部の形）。

mod RenderFrame {
    import fge.gl.GlContext
    import fge.gl.GlConst
    import java.nio.FloatBuffer

    /// z 安定ソート列に混ぜる 6 種の描画物。MTile=タイルマップ 1 層（1 draw call）、
    /// MSprite=スプライト/箱、MPoly=動的多角形、MStatic=永続 VBO のレンジ（頂点は運ばず
    /// 範囲だけ）、MSurface=宣言シェーダー面、MScene3d=3D の場面 1 つの番号（Scene3dRenderer.Prepared の番号・中だけ深度で前後を決める）。種類が切り替わる瞬間に
    /// 溜めた run を吐くことで、列順（＝重なり順）を厳密に守る。
    pub enum Merged {
        case MTile(RenderType.TileMapRenderCmd)
        case MSprite(RenderType.Drawable)
        case MPoly(RenderType.PolygonCmd)
        case MStatic(RenderStatic.Range)
        case MSurface(DrawCmd.SurfaceRenderCmd)
        case MScene3d(Int32)
    }

    /// デザイン解像度のアスペクト比を維持しつつ、フレームバッファに収まる最大矩形を計算。
    /// 戻り値: (vpX, vpY, vpW, vpH)
    pub def calcViewport(fbW: Int32, fbH: Int32, designW: Float64, designH: Float64): (Int32, Int32, Int32, Int32) =
        let floatToInt32 = RenderUtil.floatToInt32;
        let designAspect = designW / designH;
        let windowAspect = Int32.toFloat64(fbW) / Int32.toFloat64(fbH);
        if (windowAspect > designAspect) {
            // ピラーボックス (左右黒帯)
            let vpH = fbH;
            let vpW = floatToInt32(Int32.toFloat64(fbH) * designAspect);
            let vpX = (fbW - vpW) / 2;
            (vpX, 0, vpW, vpH)
        } else {
            // レターボックス (上下黒帯)
            let vpW = fbW;
            let vpH = floatToInt32(Int32.toFloat64(fbW) / designAspect);
            let vpY = (fbH - vpH) / 2;
            (0, vpY, vpW, vpH)
        }

    /// 鍵の昇順・同鍵内は入力順のまま、に並べ替える（鍵は Order を持つ任意の型）。
    /// 比較ソートにしないのは、1 比較ごとにキー関数の呼び出しと多相比較が走り、
    /// 物量シーン（数千件）でフレーム時間の大半を占めるため（スレッドダンプ実測）。
    /// 鍵ごとのバケツへ 1 パスで振り分けてキー昇順に繋ぎ直せば、比較は鍵の
    /// 種類数ぶんの Map 操作だけで済み、同鍵内の順序も構造的に崩れない。
    /// 同 z の入れ替わりは実害がある（bg Rect と同 z のテキスト最後の文字が
    /// 上書き消失した事故が過去にある）ため、安定性はこの関数の必須条件。
    /// 範囲内・範囲間ともこの安定性を保つ。
    /// zIndex は小さな整数がひとかたまりに並ぶので、鍵の幅ぶんのスロットを 1 本用意して
    /// 振り分ける。木の Map だと 1 個ごとに挿入と枝の組み替えが走り、数千個の画面では
    /// その組み替えだけがフレーム時間に現れる（スレッドダンプ実測）。
    /// スロットは先頭挿入で溜める（= 逆順）。スロットの大きい側から前置し直すので、
    /// 全体は z 昇順・スロット内は入力順に戻る。
    /// z がスロット 1 本に収まらないほど広いフレーム（HUD の範囲 = ZBand.hudBase 以上が混ざる等）は、
    /// まず範囲番号（z / ZBand.width）でグループ化し、範囲の中で同じスロット方式にそろえる
    /// （範囲内の z の幅は狭いのでスロットに収まる）— HUD が混ざった瞬間に全部が遅い木の
    /// 経路へ落ちるのを防ぐ。範囲の中でも z がまばらなときだけ木で受ける。
    /// 6 種の描画物を、zIndex 昇順・同 z 内は
    /// tiles → sprites → polygons → static → surfaces → scenes の順に並べた 1 本の列にする。
    /// 5 本を 1 本に繋いでから並べ替えないのは、繋ぐだけで列 1 本ぶんの写しが増え、
    /// 鍵と中身の組も 1 個ずつ作ることになるため（数千個の画面ではその作り直しが
    /// フレーム時間に出る）。幅と個数はスロットを作る前に一度だけ数え、
    /// 数える場所は組でなくスロット 3 つに置く（組は 1 個ごとに作り直しになる）。
    pub def mergedByZ(tiles: List[RenderType.TileMapRenderCmd],
                      sprites: List[RenderType.Drawable],
                      polygons: List[RenderType.PolygonCmd],
                       statics: List[RenderStatic.Range],
                      surfaces: List[DrawCmd.SurfaceRenderCmd],
                      scenes: Vector[Int32]): List[Merged] =
        region rc {
            // 0 = 一番小さい z / 1 = 一番大きい z / 2 = 個数
            let tally: Array[Int32, rc] = Array#{2147483647, -2147483648, 0} @ rc;
            let scan = (z: Int32) -> {
                if (z < Array.get(0, tally)) Array.put(z, 0, tally) else ();
                if (z > Array.get(1, tally)) Array.put(z, 1, tally) else ();
                Array.put(Array.get(2, tally) + 1, 2, tally)
            };
            List.forEach(x -> scan(x#zIndex), tiles);
            List.forEach(x -> scan(DrawCmd.zIndexOf(x)), sprites);
            List.forEach(x -> scan(x#zIndex), polygons);
            List.forEach(x -> scan(x#zIndex), statics);
            List.forEach(x -> scan(x#zIndex), surfaces);
            Vector.forEach(scan, scenes);
            let lo = Array.get(0, tally);
            let hi = Array.get(1, tally);
            let count = Array.get(2, tally);
            if (count == 0) Nil
            // 幅は Int64 で見る — HUD の範囲（1e9）とデバッグの範囲（2e9）が同居すると
            // Int32 の引き算は溢れて、負の幅を「スロットに収まる」と誤読するため。
            else if (spanOf(lo, hi) <= Int32.toInt64(seatLimit(count))) {
                let n = hi - lo + 1;
                let seats: Array[List[Merged], rc] = Array.repeat(rc, n, Nil);
                seatChannels(seats, lo, tiles, sprites, polygons, statics, surfaces, scenes);
                emitSeats(seats, n, Nil)
            }
            else rangeMerged(rc, lo, hi, tiles, sprites, polygons, statics, surfaces, scenes)
        }

    /// スロット 1 本に収める判定に使う z の幅（Int64 — Int32 だと範囲をまたぐ幅で溢れる）。
    def spanOf(lo: Int32, hi: Int32): Int64 =
        Int32.toInt64(hi) - Int32.toInt64(lo)

    /// 5 本の描画物リストを、スロットの列へ入力順（tiles → sprites → polygons → static →
    /// surfaces）に先頭挿入で振り分ける。スロット内は逆順に溜まる（emitSeats が戻す）。
    def seatChannels(seats: Array[List[Merged], rc], lo: Int32,
                     tiles: List[RenderType.TileMapRenderCmd],
                     sprites: List[RenderType.Drawable],
                     polygons: List[RenderType.PolygonCmd],
                      statics: List[RenderStatic.Range],
                     surfaces: List[DrawCmd.SurfaceRenderCmd],
                     scenes: Vector[Int32]): Unit \ rc =
        let seat = (z: Int32, m: Merged) -> {
            let i = z - lo;
            Array.put(m :: Array.get(i, seats), i, seats)
        };
        List.forEach(x -> seat(x#zIndex, Merged.MTile(x)), tiles);
        List.forEach(x -> seat(DrawCmd.zIndexOf(x), Merged.MSprite(x)), sprites);
        List.forEach(x -> seat(x#zIndex, Merged.MPoly(x)), polygons);
        List.forEach(x -> seat(x#zIndex, Merged.MStatic(x)), statics);
        List.forEach(x -> seat(x#zIndex, Merged.MSurface(x)), surfaces);
        Vector.forEachWithIndex((i, z) -> seat(z, Merged.MScene3d(i)), scenes)

    /// スロットの大きい側から acc へ前置し直す（スロット内の逆順が入力順へ戻る）。
    /// acc に後続（より大きい範囲の列）を渡せるので、範囲別ソートの連結にもそのまま使える。
    def emitSeats(seats: Array[List[Merged], rc], n: Int32, acc: List[Merged]): List[Merged] \ rc =
        List.range(0, n) |> List.foldLeft((rest, i) ->
            List.foldLeft((r, x) -> x :: r, rest,
                          Array.get(n - 1 - i, seats)), acc)

    /// 範囲別 2 段階ソート: 範囲番号（z / ZBand.width）でグループ化し、範囲の中はスロット方式
    /// （まばらな範囲だけ木）、範囲順に連結する。範囲の数は z が Int32 全域でも 43 以下なので
    /// 範囲ごとの入れ物は小さい。切り捨て割りは単調（z1 < z2 なら範囲も z1 ≤ z2 の順）なので、
    /// 範囲の昇順連結 = 全体の z 昇順が崩れない。
    def rangeMerged(rc: Region[rc], lo: Int32, hi: Int32,
                    tiles: List[RenderType.TileMapRenderCmd],
                    sprites: List[RenderType.Drawable],
                    polygons: List[RenderType.PolygonCmd],
                    statics: List[RenderStatic.Range],
                    surfaces: List[DrawCmd.SurfaceRenderCmd],
                    scenes: Vector[Int32]): List[Merged] \ rc =
        let w = ZBand.width();
        let bLo = lo / w;
        let nb = hi / w - bLo + 1;
        // 範囲ごとの 一番小さい z / 一番大きい z / 個数（スロットを作る前に一度だけ数える）。
        let rangeLoA: Array[Int32, rc] = Array.repeat(rc, nb, 2147483647);
        let rangeHiA: Array[Int32, rc] = Array.repeat(rc, nb, -2147483648);
        let rangeCnt: Array[Int32, rc] = Array.repeat(rc, nb, 0);
        let scanB = (z: Int32) -> {
            let b = z / w - bLo;
            if (z < Array.get(b, rangeLoA)) Array.put(z, b, rangeLoA) else ();
            if (z > Array.get(b, rangeHiA)) Array.put(z, b, rangeHiA) else ();
            Array.put(Array.get(b, rangeCnt) + 1, b, rangeCnt)
        };
        List.forEach(x -> scanB(x#zIndex), tiles);
        List.forEach(x -> scanB(DrawCmd.zIndexOf(x)), sprites);
        List.forEach(x -> scanB(x#zIndex), polygons);
        List.forEach(x -> scanB(x#zIndex), statics);
        List.forEach(x -> scanB(x#zIndex), surfaces);
        Vector.forEach(scanB, scenes);
        // 範囲ごとにスロットを先に用意する。中間リストへ溜めて反転する形にしないのは、
        // 1 個あたり cons が 2 回増えて、物量シーンでフレーム時間に乗るため。
        // スロットが個数に見合わない（z がまばらな）範囲だけリストへ溜めて木で受ける。
        let noSeats: Array[List[Merged], rc] = Array.repeat(rc, 0, Nil);
        let rangeSeats: Array[Array[List[Merged], rc], rc] = Array.repeat(rc, nb, noSeats);
        let treeRev: Array[List[Merged], rc] = Array.repeat(rc, nb, Nil);
        let useTree: Array[Bool, rc] = Array.repeat(rc, nb, false);
        List.forEach(b -> {
            let cnt = Array.get(b, rangeCnt);
            if (cnt == 0) ()
            else if (spanOf(Array.get(b, rangeLoA), Array.get(b, rangeHiA))
                     <= Int32.toInt64(seatLimit(cnt)))
                Array.put(Array.repeat(rc, Array.get(b, rangeHiA) - Array.get(b, rangeLoA) + 1,
                                       (Nil: List[Merged])), b, rangeSeats)
            else Array.put(true, b, useTree)
        }, List.range(0, nb));
        // 入力順（tiles → sprites → polygons → static → surfaces）に先頭挿入で振り分ける
        // （スロット内は逆順に溜まり、emitSeats が入力順へ戻す — 単一の範囲のスロット方式と同じ不変条件）。
        let put = (z: Int32, m: Merged) -> {
            let b = z / w - bLo;
            if (Array.get(b, useTree))
                Array.put(m :: Array.get(b, treeRev), b, treeRev)
            else {
                let seats = Array.get(b, rangeSeats);
                let j = z - Array.get(b, rangeLoA);
                Array.put(m :: Array.get(j, seats), j, seats)
            }
        };
        List.forEach(x -> put(x#zIndex, Merged.MTile(x)), tiles);
        List.forEach(x -> put(DrawCmd.zIndexOf(x), Merged.MSprite(x)), sprites);
        List.forEach(x -> put(x#zIndex, Merged.MPoly(x)), polygons);
        List.forEach(x -> put(x#zIndex, Merged.MStatic(x)), statics);
        List.forEach(x -> put(x#zIndex, Merged.MSurface(x)), surfaces);
        Vector.forEachWithIndex((i, z) -> put(z, Merged.MScene3d(i)), scenes);
        // 範囲の大きい側から前置で連結する（全体 = 範囲の昇順・範囲内 = z 昇順・同 z は入力順）。
        List.range(0, nb) |> List.foldLeft((acc, i) -> {
            let b = nb - 1 - i;
            if (Array.get(b, rangeCnt) == 0) acc
            else if (Array.get(b, useTree))
                // 溜めは逆順なので、並べ替えの前に入力順へ戻す（まばらな範囲だけの経路）。
                List.append(stableByZTree(m -> zOfMerged(scenes, m), List.reverse(Array.get(b, treeRev))), acc)
            else emitSeats(Array.get(b, rangeSeats),
                           Array.get(b, rangeHiA) - Array.get(b, rangeLoA) + 1, acc)
        }, Nil)

    /// 並べ替え鍵 = zIndex（全 run 種で共有の 1 つの z 空間）。sceneZs = 場面の番号ごとの z。
    def zOfMerged(sceneZs: Vector[Int32], item: Merged): Int32 =
        match item {
            case Merged.MTile(tm)   => tm#zIndex
            case Merged.MSprite(d)  => DrawCmd.zIndexOf(d)
            case Merged.MPoly(pc)   => pc#zIndex
            case Merged.MStatic(r)  => r#zIndex
            case Merged.MSurface(s) => s#zIndex
            case Merged.MScene3d(i) => Vector.get(i, sceneZs)
        }

    /// スロット方式にそろえる鍵の幅の上限。描く物の数に比例させるのは、スロットが疎らでも
    /// 「埋める手間 ≒ 描く物の数」に収まる範囲ならスロットのほうが速いため。
    def seatLimit(count: Int32): Int32 = 4096 + 4 * count

    /// 鍵がまばらなときの受け皿（スロット方式と同じ順序を返す）。
    def stableByZTree(zOf: a -> Int32, items: List[a]): List[a] =
        let buckets = List.foldLeft((m, x) -> {
            let z = zOf(x);
            let bucket = Map.get(z, m) |> Option.getWithDefault(Nil);
            Map.insert(z, x :: bucket, m)
        }, Map.empty(), items);
        Map.foldRight((bucket, acc) ->
            List.foldLeft((rest, x) -> x :: rest, acc, bucket), Nil, buckets)

    /// 1 フレーム描画に必要な材料をひとまとめにした名前付き引数。
    /// 同じ Int32（シェーダ・VAO・VBO のハンドル）が何個も並ぶので、位置引数だと
    /// 順番を取り違えても気づけない。名前で渡せば取り違いが起きない。
    /// 利用例: 実行環境（LWJGL 等）のフレームループがこの1件を組んで renderFrameMixed へ渡す。
    pub type alias FrameArgs = {
        spriteShader = Int32,
        tileShader = Int32,
        vao = Int32,
        registry = RenderAsset.TextureRegistry,
        clearColor = Color,
        designW = Float64,
        designH = Float64,
        fbW = Int32,
        fbH = Int32,
        sprites = List[RenderType.Drawable],
        tileMaps = List[RenderType.TileMapRenderCmd],
        polygons = List[RenderType.PolygonCmd],
        // 1 度だけ GPU に生成して使い回す静的多角形のレンジ列（無ければ Nil）。動的 polygons と
        // 同じ z 安定ソート列に混ぜて描くので重なり順は壊れない。camera（viewOffset/viewScale）
        // は各レンジが持ち、halfDesign は design/2 をここで計算して当てる。
        staticRanges = List[RenderStatic.Range],
        // 同 blend / 切り抜き clip 矩形の連続多角形を 1 draw call にまとめるバッチ描画用。
        polyBatchShader = Int32,
        polyBatchVao = Int32,
        polyBatchVbo = Int32,
        polyBatchUniforms = RenderShader.PolyBatchUniforms,
        instShader = Int32,
        instVao = Int32,
        instVbo = Int32,
        // 1 フレームぶんの instance / 頂点を直に書き溜める使い回しの入れ物
        // （バックエンドが起動時に 1 つずつ作って毎フレーム貸す）。
        instBuf = RenderBuf.Buf,
        polyBuf = RenderBuf.Buf,
        spriteUniforms = RenderShader.SpriteUniforms,
        tileUniforms = RenderShader.TileUniforms,
        // instanced シェーダの premultiply スイッチ（Multiply ブレンド用）の uniform location。
        instMultiplyBlend = Int32,
        // 宣言シェーダー面の描画依頼列。sprites/polygons/静的レンジと同じ z 安定ソート列に
        // 第 4 の run 種として混ぜ、各面の zIndex の位置で描く（水を床の上・壁の下に置ける）。
        surfaces = List[DrawCmd.SurfaceRenderCmd],
        // シェーダー面 1 枚を実際に GL へ描くクロージャ（program の uniform location を知る
        // バックエンド側が提供する）。renderFrameMixed は z の合流だけを受け持つ。
        // 返すのは出した draw call の数（mask つきは stencil へ描く分が足される）。
        drawSurface = (GlContext, DrawCmd.SurfaceRenderCmd) -> Int32 \ IO,
        // 先に準備した 3D の場面の並び。番号ごとの z で 2D の並びに混ぜ、同じ z の中では surfaces の後に描く。
        scenes = Scene3dRenderer.Prepared,
        // None = 画面へのフレーム（黒帯 + design 領域の 2 段階の clear）。Some(op) = レンダー
        // ターゲット（FBO）へのフレームで、op（RenderTarget.LoadOp）が前の中身の始末を決める —
        // Keep = 残す（残像用）・Clear = その色の不透明・ClearTransparent = 全画素透明。
        // ターゲットは letterbox を持たないので黒帯 clear はしない。
        targetClear = Option[RenderTarget.LoadOp],
        // レンダーターゲットのテクスチャ名の集合。GL のターゲットは行 0 が下で上下逆に
        // 格納されるため、この名前のスプライトだけ標本時に uv を上下反転する（emitSprite が見る）。
        targetNames = Set[String],
        // テクスチャが registry に無くて描かなかった名前の控え。フレームをまたいで残るものを
        // バックエンドが持って毎フレーム貸す — 毎フレーム作り直すと同じ知らせが 60 回/秒 出る。
        texWarnLog = Ref[Set[String], Static],
        // 2D の draw call の数と切れた理由の数を足し込む先（コマの中の描き先をまたいで溜め、塗りのコアが画面へ塗り終えた時に締める）。
        drawCounts = RenderDrawCounts.Holder
    }

    /// テクスチャが登録されていない描画物を飛ばしたことを、名前ごとに 1 度だけ知らせる。
    /// 文面は headless 経路（engine_tools の SoftRaster.flix）と 1 字も変えない — 同じ壊れ方が
    /// 別の字で出ると、実機と描き出しのどちらで起きたのかを grep で束ねられなくなる。
    /// 見つかったときは Set も文字列も触らない（毎フレーム数千体を通る経路）。
    def warnMissingTexture(warnLog: Ref[Set[String], Static], name: String): Unit \ IO =
        let warned = Ref.get(warnLog);
        if (Set.memberOf(name, warned)) ()
        else {
            Ref.put(Set.insert(name, warned), warnLog);
            Log.warn("texture '${name}' が見つからない — 描かない"
                + "（project.json の textures に同名の宣言があるか確認）")
        }

    /// drawSprite が uniform に詰める model 行列と同じ式を CPU 側で計算して、
    /// instance 属性 (38 floats・シェーダ loc1-10 と同並び) を入れ物の slot 番目へ直に書く
    /// （絵が per-draw 経路と一致することを式の同一性で保証）。
    /// style も per-instance 属性に載せる: 単色矩形は常に style 付きで届く
    /// (RawDraw.box が solidStyle を持たせる) ため、style をバッチ分割条件に
    /// すると矩形が全部 1 枚ずつ描かれて一括化が骨抜きになる（実測で発覚）。
    /// 38 本の書き込みを短い名前でまとめず並べるのは、まとめ役の小さな関数を挟むと
    /// 1 体につき 38 回その呼び出しが走り、書き込み本体より高くつくため（実測）。
    /// 位置と大きさを Vec2 でなくスカラー 4 本で受けるのは、centered の平行移動や
    /// テクスチャ寸法掛けのたびに小さなレコードを 1 個ずつ作らせないため。
    def writeInstAt(data: FloatBuffer, slot: Int32, posX: Float64, posY: Float64,
                    sizeX: Float64, sizeY: Float64,
                    drawable: RenderType.Drawable, useTex: Bool, sdf: Bool): Unit \ IO =
        let f32 = RenderUtil.f32;
        // 毎フレーム数千体が通る書き込みなので、要るフィールドは match で一度に受ける
        // （アクセサだと Vec2 / Color の作り直しが 1 体ごとに 3 個増える）。
        // sx / sy は正準名では Drawable の scale — この関数の寸法は引数 sizeX / sizeY を
        // そのまま使う（scale とテクスチャ寸の掛け算は呼び側が済ませている）。
        let DrawCmd.Drawable.Drawable(_tex, _px, _py, _sx, _sy, rot,
                                      cr, cg, cb, a, _cen,
                                      uox, uoy, usx, usy, _z,
                                      style, _clip, _blend, _mask) = drawable;
        let c = RenderUtil.cosF(rot);
        let s = RenderUtil.sinF(rot);
        let tx = posX + sizeX / 2.0 - c * sizeX / 2.0 + s * sizeY / 2.0;
        let ty = posY + sizeY / 2.0 - s * sizeX / 2.0 - c * sizeY / 2.0;
        let base = slot * 38;
        discard data.put(base + 0, f32(c * sizeX));
        discard data.put(base + 1, f32(s * sizeX));
        discard data.put(base + 2, f32(-1.0 * s * sizeY));
        discard data.put(base + 3, f32(c * sizeY));
        discard data.put(base + 4, f32(tx));
        discard data.put(base + 5, f32(ty));
        discard data.put(base + 6, f32(uox));
        discard data.put(base + 7, f32(uoy));
        discard data.put(base + 8, f32(usx));
        discard data.put(base + 9, f32(usy));
        discard data.put(base + 10, f32(cr));
        discard data.put(base + 11, f32(cg));
        discard data.put(base + 12, f32(cb));
        discard data.put(base + 13, f32(a));
        discard data.put(base + 14, if (useTex) 1.0f32 else 0.0f32);
        discard data.put(base + 15, if (sdf) 1.0f32 else 0.0f32);
        discard data.put(base + 18, f32(sizeX));
        discard data.put(base + 19, f32(sizeY));
        match style {
            case None =>
                discard data.put(base + 16, 0.0f32);
                discard data.put(base + 17, 0.0f32);
                discard data.put(base + 20, 0.0f32);
                discard data.put(base + 21, 0.0f32);
                discard data.put(base + 22, 0.0f32);
                discard data.put(base + 23, 0.0f32);
                discard data.put(base + 24, 0.0f32);
                discard data.put(base + 25, 0.0f32);
                discard data.put(base + 26, 0.0f32);
                discard data.put(base + 27, 0.0f32);
                discard data.put(base + 28, 0.0f32);
                discard data.put(base + 29, 0.0f32);
                discard data.put(base + 30, 0.0f32);
                discard data.put(base + 31, 0.0f32);
                discard data.put(base + 32, 0.0f32);
                discard data.put(base + 33, 0.0f32);
                discard data.put(base + 34, 0.0f32);
                discard data.put(base + 35, 0.0f32);
                discard data.put(base + 36, 0.0f32);
                discard data.put(base + 37, 0.0f32)
            case Some(st) =>
                let DrawCmd.BoxStyle.BoxStyle(rad, bw, br, bg, bb, ba,
                                              sr, sg, sb, sa, sw, sp, sd,
                                              kr, kg, kb, ka, kc) = st;
                // hatch の有効判定は drawSprite の hatchOn と同式(period<=0 は GLSL の mod が未定義なので無効扱い)。
                let hatch = if (sw > 0.0 and sa > 0.0 and sp > 0.0) 1.0f32 else 0.0f32;
                discard data.put(base + 16, 1.0f32);
                discard data.put(base + 17, hatch);
                discard data.put(base + 20, f32(rad));
                discard data.put(base + 21, f32(bw));
                discard data.put(base + 22, f32(br));
                discard data.put(base + 23, f32(bg));
                discard data.put(base + 24, f32(bb));
                discard data.put(base + 25, f32(ba));
                discard data.put(base + 26, f32(sr));
                discard data.put(base + 27, f32(sg));
                discard data.put(base + 28, f32(sb));
                discard data.put(base + 29, f32(sa));
                discard data.put(base + 30, f32(sw));
                discard data.put(base + 31, f32(sp));
                discard data.put(base + 32, Int32.toFloat32(sd));
                discard data.put(base + 33, f32(kc));
                discard data.put(base + 34, f32(kr));
                discard data.put(base + 35, f32(kg));
                discard data.put(base + 36, f32(kb));
                discard data.put(base + 37, f32(ka))
        }

    // ── 詰め込みループの run 状態 ──────────────────────────────
    // run（同テクスチャ・同 clip 矩形・同 blend の連続列）の状態は Int32 配列 1 本に置き、
    // 吐き出しに要る GL ハンドル定数も同じ配列に同居させる。組やレコードの acc を
    // 持ち回らないのは、1 item ごとに組の作り直しと Option+組の等価比較が走り、
    // 物量シーンでフレーム時間に乗るため（スレッドダンプ実測）。局所クロージャに
    // まとめないのも同じ理由 — item 毎に呼ぶには Flix のクロージャは高すぎる（悪化の実測あり）。
    //
    // スロット順（定数）: 0=instShader 1=instVao 2=instVbo 3=instMultiplyBlend
    //              4=polyBatchShader 5=polyBatchVao 6=polyBatchVbo
    //              7=vpX 8=vpY 9=vpW 10=vpH 26=tileShader
    // スプライト run: 11=texId 12=clip有無 13-16=clip矩形 17=blend 18=体数 51=先頭の instance の番号（RenderList の instances の中）
    // 多角形 run:     19=clip有無 20-23=clip矩形 24=blend 25=頂点数
    // draw call の数え: 27=前の draw call の種類（kind*・0 = まだ無い） 28=この描き先でまだ draw call を出していない
    //              29=前の draw call が mask つき 30=このコマで先に draw call が出ている
    //              31-37=前に出したスプライトの鍵（texId・clip有無・clip矩形・blend） 38-43=前に出した多角形の鍵（clip有無・clip矩形・blend）
    //              44-50=この描き先で数えた数（並びは RenderDrawCounts の slot）
    def stateSize(): Int32 = 52

    def runFirstSlot(): Int32 = 51

    def kindSprite(): Int32 = 1
    def kindPoly(): Int32 = 2
    def kindTile(): Int32 = 3
    def kindStatic(): Int32 = 4
    def kindSurface(): Int32 = 5
    def kindScene3d(): Int32 = 6

    def countBase(): Int32 = 44

    /// この描き先の数 slot を n 足す。
    def bump(st: Array[Int32, Static], slot: Int32, n: Int32): Unit \ IO =
        let i = countBase() + slot;
        Array.put(Array.get(i, st) + n, i, st)

    /// draw call を 1 つ出したと数え、前の draw call に続けられなかった理由を 1 つ数える。
    /// kind = 今の draw call の種類・sameKindReason = 前も同じ種類だった時の理由の slot。コマの最初の draw call は理由を数えない。
    def countDraw(st: Array[Int32, Static], kind: Int32, sameKindReason: Int32): Unit \ IO =
        bump(st, RenderDrawCounts.drawCallsSlot(), 1);
        if (Array.get(28, st) == 1) {
            Array.put(0, 28, st);
            if (Array.get(30, st) == 1) bump(st, RenderDrawCounts.targetSlot(), 1) else ()
        } else if (Array.get(27, st) != kind) bump(st, RenderDrawCounts.kindSlot(), 1)
        else bump(st, sameKindReason, 1);
        Array.put(kind, 27, st)

    /// スプライトの draw call が、前に出したスプライトの draw call に続けられなかった理由の slot。
    /// masked = 今の draw call が mask つき。鍵が全部同じで mask も絡まないのは、間に描かない物（別の種類）が挟まった時。
    def spriteBreakOf(st: Array[Int32, Static], texId: Int32, clipFlag: Int32,
                      x0: Int32, y0: Int32, x1: Int32, y1: Int32, blendC: Int32, masked: Bool): Int32 \ IO =
        if (Array.get(31, st) != texId) RenderDrawCounts.textureSlot()
        else if (Array.get(37, st) != blendC) RenderDrawCounts.blendSlot()
        else if (Array.get(32, st) != clipFlag
                 or (clipFlag != 0 and (Array.get(33, st) != x0 or Array.get(34, st) != y0
                                        or Array.get(35, st) != x1 or Array.get(36, st) != y1))) RenderDrawCounts.clipSlot()
        else if (masked or Array.get(29, st) == 1) RenderDrawCounts.maskSlot()
        else RenderDrawCounts.kindSlot()

    /// スプライトの draw call を数え、その鍵を「前に出したスプライトの鍵」に控える。draws = 出した draw call の数（mask つきは 2）。
    def countSpriteDraw(st: Array[Int32, Static], texId: Int32, clipFlag: Int32,
                        x0: Int32, y0: Int32, x1: Int32, y1: Int32, blendC: Int32, masked: Bool, draws: Int32): Unit \ IO =
        countDraw(st, kindSprite(), spriteBreakOf(st, texId, clipFlag, x0, y0, x1, y1, blendC, masked));
        if (draws > 1) {
            bump(st, RenderDrawCounts.drawCallsSlot(), draws - 1);
            bump(st, RenderDrawCounts.maskSlot(), draws - 1)
        } else ();
        Array.put(if (masked) 1 else 0, 29, st);
        Array.put(texId, 31, st);
        Array.put(clipFlag, 32, st);
        Array.put(x0, 33, st);
        Array.put(y0, 34, st);
        Array.put(x1, 35, st);
        Array.put(y1, 36, st);
        Array.put(blendC, 37, st)

    /// 今の多角形 run の draw call を数え、その鍵を「前に出した多角形の鍵」に控える。
    def countPolyDraw(st: Array[Int32, Static]): Unit \ IO =
        let clipFlag = Array.get(19, st);
        let reason =
            if (Array.get(43, st) != Array.get(24, st)) RenderDrawCounts.blendSlot()
            else if (Array.get(38, st) != clipFlag
                     or (clipFlag != 0 and (Array.get(39, st) != Array.get(20, st) or Array.get(40, st) != Array.get(21, st)
                                            or Array.get(41, st) != Array.get(22, st) or Array.get(42, st) != Array.get(23, st)))) RenderDrawCounts.clipSlot()
            else RenderDrawCounts.kindSlot();
        countDraw(st, kindPoly(), reason);
        Array.put(0, 29, st);
        Array.put(clipFlag, 38, st);
        Array.put(Array.get(20, st), 39, st);
        Array.put(Array.get(21, st), 40, st);
        Array.put(Array.get(22, st), 41, st);
        Array.put(Array.get(23, st), 42, st);
        Array.put(Array.get(24, st), 43, st)

    /// 1 つで 1 draw call の種類（タイル層・static の範囲・Shader の面）を数える。draws = 出した draw call の数（0 なら数えない・mask つきの面は 2）。
    def countSingleDraw(st: Array[Int32, Static], kind: Int32, draws: Int32): Unit \ IO =
        if (draws <= 0) ()
        else {
            countDraw(st, kind, RenderDrawCounts.kindSlot());
            if (draws > 1) {
                bump(st, RenderDrawCounts.drawCallsSlot(), draws - 1);
                bump(st, RenderDrawCounts.maskSlot(), draws - 1)
            } else ();
            Array.put(0, 29, st)
        }

    /// この描き先で数えた数を、今のコマの数へ足し込む。
    def addCountsTo(holder: RenderDrawCounts.Holder, st: Array[Int32, Static]): Unit \ IO = addCountsFrom(0, holder, st)

    def addCountsFrom(i: Int32, holder: RenderDrawCounts.Holder, st: Array[Int32, Static]): Unit \ IO =
        if (i >= RenderDrawCounts.slots()) ()
        else {
            Array.put(Array.get(i, holder) + Array.get(countBase() + i, st), i, holder);
            addCountsFrom(i + 1, holder, st)
        }

    /// BlendMode ⇄ Int32（run 状態の入れ物が Int32 配列のため）。
    def blendCode(b: DrawCmd.BlendMode): Int32 =
        match b {
            case DrawCmd.BlendMode.Normal   => 0
            case DrawCmd.BlendMode.Add      => 1
            case DrawCmd.BlendMode.Multiply => 2
        }

    def blendOf(code: Int32): DrawCmd.BlendMode =
        if (code == 1) DrawCmd.BlendMode.Add
        else if (code == 2) DrawCmd.BlendMode.Multiply
        else DrawCmd.BlendMode.Normal

    /// scissor を張り替える。y は GL の左下原点へ反転し、viewport と交差する
    /// （clip が画面外へ食み出しても letterbox の黒帯を侵さない）。
    /// 幅か高さが 0 以下の矩形は glScissor(…, 0, 0) になり、その run は何も描かない。
    /// clipFlag = 0 は「clip 矩形なし」（scissor 無効化）。
    def setScissorAt(gl: GlContext, st: Array[Int32, Static], clipFlag: Int32,
                     x0: Int32, y0: Int32, x1: Int32, y1: Int32): Unit \ IO =
        if (clipFlag == 0) gl.disable(GlConst.SCISSOR_TEST)
        else {
            let vpX = Array.get(7, st);
            let vpY = Array.get(8, st);
            let vpW = Array.get(9, st);
            let vpH = Array.get(10, st);
            let cx0 = Int32.max(0, x0);
            let cx1 = Int32.min(vpW, x1);
            let cy0 = Int32.max(0, y0);
            let cy1 = Int32.min(vpH, y1);
            gl.enable(GlConst.SCISSOR_TEST);
            gl.scissor(vpX + cx0, vpY + vpH - cy1,
                           Int32.max(0, cx1 - cx0), Int32.max(0, cy1 - cy0))
        }

    // ── RenderList: 1 回の renderFrameMixed で描く行の列 ──────────────
    // 1 行 = 物の集まりを 1 回描く（種類はスプライト・字・箱の run だけ。ほかの種類は GL を直に呼ぶ）。GL の物（program・VAO・buffer）を持たず、
    // 絵は backend の表の番号（GL の backend ではテクスチャの番号）で持つ。行は Int32 の配列、1 体ぶんの値は instances の Float32 に置く。
    // rows の頭: 0=行の数 1=次に書く instance の番号。その後ろに 1 行 rowStride() 個:
    //   0=種類（kind*） 1=先頭の instance の番号 2=体数 3=絵の番号（0 = 絵の無い箱） 4=blend 5=clip有無 6-9=clip矩形（viewport の左上原点の px）
    // instances は 1 体 38 個（writeInstAt の並び）。行の値は instances の [先頭 × 38, (先頭 + 体数) × 38)。
    // WhyNot: 行ごとに record や enum を作らない — 絵が 1 個ごとに替わると行は描く物の数だけでき、その割り当てが 1 コマに乗る。
    // WhyNot: 別のモジュールに出さない — 別のモジュールの pub でない関数は呼べず、行を作る関数と流す関数を pub に開くことになる（render_gl の pub を増やさない）。
    type alias RenderList = { instances = FloatBuffer, rows = Array[Array[Int32, Static], Static] }

    def rowStride(): Int32 = 10

    def rowsHead(): Int32 = 2

    def instanceFloats(): Int32 = 38

    def newRenderList(instances: FloatBuffer): RenderList \ IO =
        { instances = instances, rows = Array#{Array.empty(Static, rowsHead() + 16 * rowStride())} @ Static }

    def rowCountOf(list: RenderList): Int32 \ IO = Array.get(0, Array.get(0, list#rows))

    def nextInstanceOf(list: RenderList): Int32 \ IO = Array.get(1, Array.get(0, list#rows))

    /// 行 row の欄 col（並びは RenderList の上のコメント）。
    def rowAt(list: RenderList, row: Int32, col: Int32): Int32 \ IO =
        Array.get(rowsHead() + row * rowStride() + col, Array.get(0, list#rows))

    /// 行を全部捨てる（instances の書く位置も頭へ戻す）。
    def clearRenderList(list: RenderList): Unit \ IO =
        let rows = Array.get(0, list#rows);
        Array.put(0, 0, rows);
        Array.put(0, 1, rows)

    /// 1 行足せる大きさの rows を返す（足りなければ倍に広げて写す）。
    def rowsWithRoom(list: RenderList): Array[Int32, Static] \ IO =
        let rows = Array.get(0, list#rows);
        let need = rowsHead() + (Array.get(0, rows) + 1) * rowStride();
        if (Array.length(rows) >= need) rows
        else {
            let grown = Array.empty(Static, Int32.max(need, 2 * Array.length(rows)));
            Array.copyInto(srcPos = 0, dstPos = 0, len = Array.length(rows), src = rows, grown);
            Array.put(grown, 0, list#rows);
            grown
        }

    /// スプライトの run を 1 行として足す。次の run の instance は、この run の後ろから始まる。
    def appendSpriteRow(list: RenderList, first: Int32, count: Int32, texId: Int32, blendC: Int32,
                        clipFlag: Int32, x0: Int32, y0: Int32, x1: Int32, y1: Int32): Unit \ IO =
        let rows = rowsWithRoom(list);
        let n = Array.get(0, rows);
        let at = rowsHead() + n * rowStride();
        Array.put(kindSprite(), at + 0, rows);
        Array.put(first, at + 1, rows);
        Array.put(count, at + 2, rows);
        Array.put(texId, at + 3, rows);
        Array.put(blendC, at + 4, rows);
        Array.put(clipFlag, at + 5, rows);
        Array.put(x0, at + 6, rows);
        Array.put(y0, at + 7, rows);
        Array.put(x1, at + 8, rows);
        Array.put(y1, at + 9, rows);
        Array.put(n + 1, 0, rows);
        Array.put(first + count, 1, rows)

    /// 溜めているスプライトの run を 1 行にして閉じる（空 run は行にしない）。
    def closeSpriteRun(st: Array[Int32, Static], list: RenderList): Unit \ IO =
        let count = Array.get(18, st);
        if (count == 0) () else {
            appendSpriteRow(list, Array.get(runFirstSlot(), st), count, Array.get(11, st), Array.get(17, st),
                            Array.get(12, st), Array.get(13, st), Array.get(14, st), Array.get(15, st), Array.get(16, st));
            Array.put(0, 18, st)
        }

    // ── RenderList の GL の backend ──────────────────────────────

    /// 行を順に GL へ流し、列を空にする。
    def drawRenderList(gl: GlContext, st: Array[Int32, Static], list: RenderList): Unit \ IO =
        drawRowsFrom(gl, st, list, 0, rowCountOf(list));
        clearRenderList(list)

    def drawRowsFrom(gl: GlContext, st: Array[Int32, Static], list: RenderList, row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            drawRow(gl, st, list, row);
            drawRowsFrom(gl, st, list, row + 1, n)
        }

    /// スプライトの行 1 つを 1 回の instanced draw で描き、draw call を数える。
    // WhyNot: 末尾を呼び出しで終えない — 行が描く物の数だけある画面で drawRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
    @DontInline
    def drawRow(gl: GlContext, st: Array[Int32, Static], list: RenderList, row: Int32): Unit \ IO =
        let first = rowAt(list, row, 1);
        let count = rowAt(list, row, 2);
        let texId = rowAt(list, row, 3);
        let blendC = rowAt(list, row, 4);
        let clipFlag = rowAt(list, row, 5);
        let x0 = rowAt(list, row, 6);
        let y0 = rowAt(list, row, 7);
        let x1 = rowAt(list, row, 8);
        let y1 = rowAt(list, row, 9);
        let instances = list#instances;
        setScissorAt(gl, st, clipFlag, x0, y0, x1, y1);
        discard instances.position(first * instanceFloats());
        RenderSprite.drawSpriteInstancedBuf(gl, Array.get(0, st), Array.get(1, st), Array.get(2, st), texId,
                                            Array.get(3, st), blendOf(blendC), instances, count);
        countSpriteDraw(st, texId, clipFlag, x0, y0, x1, y1, blendC, false, 1);
        ()

    /// 溜めているスプライトの run を閉じ、溜まった行を GL へ流す。GL を直に呼ぶ種類（多角形・タイル・面など）を描く前に呼ぶ。
    def flushSprites(gl: GlContext, st: Array[Int32, Static], list: RenderList): Unit \ IO =
        closeSpriteRun(st, list);
        if (rowCountOf(list) == 0) () else drawRenderList(gl, st, list)

    /// 溜まった多角形 run を 1 回の draw call で吐く（空 run は no-op）。
    def flushPolys(gl: GlContext, st: Array[Int32, Static], polyData: FloatBuffer,
                   uniforms: RenderShader.PolyBatchUniforms): Unit \ IO =
        let count = Array.get(25, st);
        if (count == 0) () else {
            setScissorAt(gl, st, Array.get(19, st), Array.get(20, st), Array.get(21, st),
                         Array.get(22, st), Array.get(23, st));
            RenderSprite.drawPolygonBatchBuf(gl, Array.get(4, st), Array.get(5, st),
                                             Array.get(6, st), uniforms,
                                             blendOf(Array.get(24, st)), polyData, count);
            countPolyDraw(st);
            Array.put(0, 25, st)
        }

    /// 積むときにその場で RenderList の instances へ書く。テクスチャ・clip 矩形・重ね方が変わるところでは
    /// **先に**溜めた run を 1 行にして閉じる — 新しい run の先頭はその行の後ろなので、
    /// 書いてから閉じると新しい 1 体が前の行に混ざる。
    /// clip の一致は clip有無 + 矩形 4 値の Int32 比較で見る（clip 矩形なしどうしは矩形を見ない —
    /// 前の run の古い矩形が残っていても None == None と同じ判定になるように）。
    def pushSpriteKeyed(st: Array[Int32, Static], list: RenderList,
                        texId: Int32, clipFlag: Int32,
                        x0: Int32, y0: Int32, x1: Int32, y1: Int32, blendC: Int32,
                        posX: Float64, posY: Float64, sizeX: Float64, sizeY: Float64,
                        drawable: RenderType.Drawable, useTex: Bool, sdf: Bool): Unit \ IO =
        let count = Array.get(18, st);
        let sameKey = count != 0
            and Array.get(11, st) == texId
            and Array.get(17, st) == blendC
            and Array.get(12, st) == clipFlag
            and (clipFlag == 0 or (Array.get(13, st) == x0 and Array.get(14, st) == y0
                                   and Array.get(15, st) == x1 and Array.get(16, st) == y1));
        if (sameKey) {
            writeInstAt(list#instances, Array.get(runFirstSlot(), st) + count, posX, posY, sizeX, sizeY, drawable, useTex, sdf);
            Array.put(count + 1, 18, st)
        } else {
            closeSpriteRun(st, list);
            let first = nextInstanceOf(list);
            writeInstAt(list#instances, first, posX, posY, sizeX, sizeY, drawable, useTex, sdf);
            Array.put(first, runFirstSlot(), st);
            Array.put(texId, 11, st);
            Array.put(clipFlag, 12, st);
            Array.put(x0, 13, st);
            Array.put(y0, 14, st);
            Array.put(x1, 15, st);
            Array.put(y1, 16, st);
            Array.put(blendC, 17, st);
            Array.put(1, 18, st)
        }

    /// 1 多角形を三角形化して入れ物へ直に書く（clip 矩形か重ね方が変わるところでは先に吐く）。
    /// 頂点数が 3 未満（退化）なら何も積まない（run の鍵も進めない — 空 run のまま）。
    def pushPolyKeyed(gl: GlContext, st: Array[Int32, Static], polyData: FloatBuffer,
                      uniforms: RenderShader.PolyBatchUniforms, clipFlag: Int32,
                      x0: Int32, y0: Int32, x1: Int32, y1: Int32, blendC: Int32,
                      pc: RenderType.PolygonCmd): Unit \ IO =
        let count = Array.get(25, st);
        let sameKey = count != 0
            and Array.get(24, st) == blendC
            and Array.get(19, st) == clipFlag
            and (clipFlag == 0 or (Array.get(20, st) == x0 and Array.get(21, st) == y0
                                   and Array.get(22, st) == x1 and Array.get(23, st) == y1));
        if (sameKey) {
            let n = RenderSprite.writePolyVerts(polyData, count, pc);
            if (n < 3) () else Array.put(count + n, 25, st)
        } else {
            flushPolys(gl, st, polyData, uniforms);
            let n = RenderSprite.writePolyVerts(polyData, 0, pc);
            if (n < 3) () else {
                Array.put(clipFlag, 19, st);
                Array.put(x0, 20, st);
                Array.put(y0, 21, st);
                Array.put(x1, 22, st);
                Array.put(y1, 23, st);
                Array.put(blendC, 24, st);
                Array.put(n, 25, st)
            }
        }

    /// clip 矩形を run 鍵の Int32 群へほどいて push する。Option の組を item ごとに
    /// 作って等価比較する形にしないのは、その作り直しと多相比較が詰め込みループの
    /// 大きな取り分だったため（プロファイル実測）。矩形の量子化は DrawCmd.clipPixels の
    /// 1 本にまとめたまま（GL と SoftRaster が同じ画素集合を見る保証を崩さない）。
    def pushSpriteItem(st: Array[Int32, Static], list: RenderList,
                       scaleX: Float64, scaleY: Float64, texId: Int32,
                       posX: Float64, posY: Float64, sizeX: Float64, sizeY: Float64,
                       drawable: RenderType.Drawable, useTex: Bool, sdf: Bool): Unit \ IO =
        let blendC = blendCode(DrawCmd.blendOf(drawable));
        match DrawCmd.clipOf(drawable) {
            case None    => pushSpriteKeyed(st, list, texId, 0, 0, 0, 0, 0, blendC,
                                            posX, posY, sizeX, sizeY, drawable, useTex, sdf)
            case Some(r) =>
                let (x0, y0, x1, y1) = DrawCmd.clipPixels({ scaleX = scaleX, scaleY = scaleY }, r);
                pushSpriteKeyed(st, list, texId, 1, x0, y0, x1, y1, blendC,
                                posX, posY, sizeX, sizeY, drawable, useTex, sdf)
        }

    /// レンダーターゲット（FBO）のテクスチャは行 0 が下で上下逆に格納されている。
    /// 指定の uv（上原点の部分矩形）を GL の格納向きへ写して標本する —
    /// ゲーム側は普通の画像と同じ uv で書けばよい。ターゲット以外はそのまま返す。
    def targetUvFlipped(targetNames: Set[String],
                        drawable: RenderType.Drawable): RenderType.Drawable =
        let DrawCmd.Drawable.Drawable(tex, _px, _py, _sx, _sy, _rot,
                                      _cr, _cg, _cb, _a, _cen,
                                      uox, uoy, usx, usy, _z,
                                      _style, _clip, _blend, _mask) = drawable;
        if (Set.memberOf(tex, targetNames))
            DrawCmd.withUv({ x = uox, y = 1.0 - uoy },
                           { x = usx, y = 0.0 - usy }, drawable)
        else drawable

    /// 表示矩形の起点（1 軸ぶん）。flipH / flipV は scale の符号で行うので display が負になるが、
    /// 反転で絵が幅ぶん横へ飛ばないよう、覆う範囲は必ず position から正の向きへ伸ばす。
    /// 符号は頂点の展開でそのまま鏡像を作るため、display は負のまま渡す。
    def originAxis(centered: Bool, position: Float64, display: Float64): Float64 =
        if (centered) position - display / 2.0
        else if (display < 0.0) position - display
        else position

    /// スプライト 1 体を run へ積む（テクスチャ解決と centered の平行移動込み）。
    def emitSprite(st: Array[Int32, Static], list: RenderList,
                   scaleX: Float64, scaleY: Float64,
                   registry: RenderAsset.TextureRegistry,
                   targetNames: Set[String],
                   warnLog: Ref[Set[String], Static],
                   drawable: RenderType.Drawable): Unit \ IO =
        let DrawCmd.Drawable.Drawable(tex, px, py, sx, sy, _rot,
                                      _cr, _cg, _cb, _a, cen,
                                      _uox, _uoy, _usx, _usy, _z,
                                      _style, _clip, _blend, _mask) = drawable;
        if (String.isEmpty(tex)) {
            pushSpriteItem(st, list, scaleX, scaleY, 0,
                           px, py, sx, sy, drawable, false, false)
        } else {
            match Map.get(tex, registry) {
                case Some(texInfo) =>
                    let displayW = texInfo#width * sx;
                    let displayH = texInfo#height * sy;
                    let posX = originAxis(cen, px, displayW);
                    let posY = originAxis(cen, py, displayH);
                    // フォントアトラス (font_*) は SDF テキストとして描く。
                    let isFont = String.startsWith({prefix = "font_"}, tex);
                    let d = targetUvFlipped(targetNames, drawable);
                    pushSpriteItem(st, list, scaleX, scaleY,
                                   GpuHandle.textureIdInt(texInfo#id),
                                   posX, posY, displayW, displayH, d, true, isFont)
                // texture 未登録は描かない。描かないだけなので run は途切れさせない。
                case None => warnMissingTexture(warnLog, tex)
            }
        }

    /// mask 付きスプライト 1 体を単発で描く（テクスチャ解決と centered の平行移動は
    /// emitSprite と同じ式）。run の一括化から外れるのは、ステンシルの書き込み・解除を
    /// 1 体の draw の前後に挟む口が一括 draw に無いため — mask 付きは少数枚の前提。
    /// 呼び側（emitMerged）が両 run を吐いてから呼ぶ。
    def emitSpriteMasked(gl: GlContext, st: Array[Int32, Static], instData: FloatBuffer,
                         scaleX: Float64, scaleY: Float64,
                         registry: RenderAsset.TextureRegistry,
                         targetNames: Set[String],
                         warnLog: Ref[Set[String], Static],
                         polyUniforms: RenderShader.PolyBatchUniforms,
                         drawable: RenderType.Drawable): Unit \ IO =
        let DrawCmd.Drawable.Drawable(tex, px, py, sx, sy, _rot,
                                      _cr, _cg, _cb, _a, cen,
                                      _uox, _uoy, _usx, _usy, _z,
                                      _style, _clip, _blend, _mask) = drawable;
        if (String.isEmpty(tex)) {
            drawMaskedOne(gl, st, instData, scaleX, scaleY, polyUniforms, 0,
                          px, py, sx, sy, drawable, false, false)
        } else {
            match Map.get(tex, registry) {
                case Some(texInfo) =>
                    let displayW = texInfo#width * sx;
                    let displayH = texInfo#height * sy;
                    let posX = originAxis(cen, px, displayW);
                    let posY = originAxis(cen, py, displayH);
                    let isFont = String.startsWith({prefix = "font_"}, tex);
                    // uv 反転は emitSprite と同じ（mask は形の変換なので uv には触らない）。
                    let d = targetUvFlipped(targetNames, drawable);
                    drawMaskedOne(gl, st, instData, scaleX, scaleY, polyUniforms,
                                  GpuHandle.textureIdInt(texInfo#id),
                                  posX, posY, displayW, displayH, d, true, isFont)
                case None => warnMissingTexture(warnLog, tex)
            }
        }

    /// mask 付き 1 体の実描画: scissor を張り、instance を slot 0 へ書き、mask を
    /// スクリーン座標へ写してステンシル付きの単発 draw に渡す。
    def drawMaskedOne(gl: GlContext, st: Array[Int32, Static], instData: FloatBuffer,
                      scaleX: Float64, scaleY: Float64,
                      polyUniforms: RenderShader.PolyBatchUniforms, texId: Int32,
                      posX: Float64, posY: Float64, sizeX: Float64, sizeY: Float64,
                      drawable: RenderType.Drawable, useTex: Bool, sdf: Bool): Unit \ IO =
        let DrawCmd.Drawable.Drawable(_tex, _px, _py, _sx, _sy, rot,
                                      _cr, _cg, _cb, _a, _cen,
                                      _uox, _uoy, _usx, _usy, _z,
                                      _style, clip, blend, mask) = drawable;
        let (clipFlag, x0, y0, x1, y1) = match clip {
            case None    => (0, 0, 0, 0, 0)
            case Some(r) =>
                let (cx0, cy0, cx1, cy1) = DrawCmd.clipPixels({ scaleX = scaleX, scaleY = scaleY }, r);
                (1, cx0, cy0, cx1, cy1)
        };
        setScissorAt(gl, st, clipFlag, x0, y0, x1, y1);
        writeInstAt(instData, 0, posX, posY, sizeX, sizeY, drawable, useTex, sdf);
        discard instData.position(0);
        let draws = RenderSprite.drawSpriteMasked(gl, Array.get(0, st), Array.get(1, st), Array.get(2, st), texId,
                                                  Array.get(3, st), blend, instData,
                                                  Array.get(4, st), Array.get(5, st), Array.get(6, st),
                                                  polyUniforms,
                                                  maskToScreen(rot, posX, posY, sizeX, sizeY, mask));
        countSpriteDraw(st, texId, clipFlag, x0, y0, x1, y1, blendCode(blend), true, draws)

    /// mask 頂点（表示クアッドのローカル design px・原点 = 左上・回転前）を、writeInstAt と
    /// 同じ model 変換（回転中心 = クアッド中心）でスクリーン px へ写す。頂点を size の
    /// 符号で掛け直すのは、反転（負の scale）がクアッドと同じ向きに mask にも掛かるため。
    /// クアッドが退化（辺長ほぼ 0）なら空を返す（絵も出ないので抜く形も要らない）。
    def maskToScreen(rot: Float64, posX: Float64, posY: Float64,
                     sizeX: Float64, sizeY: Float64,
                     mask: List[List[Vec2.Vec2]]): List[List[Vec2.Vec2]] =
        let aw = Float64.abs(sizeX);
        let ah = Float64.abs(sizeY);
        if (aw < 0.000001 or ah < 0.000001) Nil
        else {
            let c = RenderUtil.cosF(rot);
            let s = RenderUtil.sinF(rot);
            let tx = posX + sizeX / 2.0 - c * sizeX / 2.0 + s * sizeY / 2.0;
            let ty = posY + sizeY / 2.0 - s * sizeX / 2.0 - c * sizeY / 2.0;
            mask |> List.map(poly -> poly |> List.map(v -> {
                let vx = v#x / aw * sizeX;
                let vy = v#y / ah * sizeY;
                ({ x = c * vx - s * vy + tx, y = s * vx + c * vy + ty }: Vec2.Vec2)
            }))
        }

    /// 多角形 1 個を run へ積む（clip 矩形を Int32 鍵へほどく）。
    def emitPoly(gl: GlContext, st: Array[Int32, Static], polyData: FloatBuffer,
                 uniforms: RenderShader.PolyBatchUniforms,
                 scaleX: Float64, scaleY: Float64, pc: RenderType.PolygonCmd): Unit \ IO =
        match pc#clip {
            case None    => pushPolyKeyed(gl, st, polyData, uniforms, 0, 0, 0, 0, 0,
                                          blendCode(pc#blend), pc)
            case Some(r) =>
                let (x0, y0, x1, y1) = DrawCmd.clipPixels({ scaleX = scaleX, scaleY = scaleY }, r);
                pushPolyKeyed(gl, st, polyData, uniforms, 1, x0, y0, x1, y1, blendCode(pc#blend), pc)
        }

    /// 静的レンジ 1 本を描く: 溜まっている両 run は呼び側で吐き終えている前提。
    /// scissor をレンジの clip に合わせ、永続 VBO の範囲を 1 draw call で塗る
    /// （アップロードも三角形化もしない）。
    def emitStatic(gl: GlContext, st: Array[Int32, Static], scaleX: Float64, scaleY: Float64,
                   uniforms: RenderShader.PolyBatchUniforms, r: RenderStatic.Range): Unit \ IO =
        match r#clip {
            case None    => setScissorAt(gl, st, 0, 0, 0, 0, 0)
            case Some(c) =>
                let (x0, y0, x1, y1) = DrawCmd.clipPixels({ scaleX = scaleX, scaleY = scaleY }, c);
                setScissorAt(gl, st, 1, x0, y0, x1, y1)
        };
        RenderSprite.drawStaticRange(gl, Array.get(4, st), r#vao, uniforms, r#blend,
                                     r#viewOffset, r#viewScale, r#halfDesign, r#first, r#count);
        countSingleDraw(st, kindStatic(), if (r#count < 3) 0 else 1)

    /// 安定ソート済みの列を先頭から 1 本ずつ処理する（末尾再帰）。
    /// スプライト run と多角形 run を並行して溜め、種類が切り替わる瞬間に
    /// もう一方を吐き出すことで、列順（＝重なり順）を厳密に守る。
    /// 同一時点で両 run が非空になることはない（切替時に必ず flush する）。
    ///
    /// 【順序の不変条件・変更禁止】列順は一切入れ替えない。まとめてよいのは
    /// 「先頭から連続する同状態の部分列」だけで、バッチ内の instance 順 = 列順。
    /// run をまたいでテクスチャごとに再グループ化するのは禁止: アルファブレンドは
    /// 描画順に依存するので、同 zIndex の bg 矩形とテキスト最後の文字が入れ替わって
    /// 文字が消える実バグが過去に起きた。
    def emitMerged(gl: GlContext, st: Array[Int32, Static], list: RenderList, polyData: FloatBuffer,
                   scaleX: Float64, scaleY: Float64,
                   registry: RenderAsset.TextureRegistry,
                   targetNames: Set[String],
                   warnLog: Ref[Set[String], Static],
                   tileUniforms: RenderShader.TileUniforms,
                   polyBatchUniforms: RenderShader.PolyBatchUniforms,
                   drawSurface: (GlContext, DrawCmd.SurfaceRenderCmd) -> Int32 \ IO,
                   drawScene: (Scene3dRenderer.Viewport, Int32) -> Unit \ IO,
                   items: List[Merged]): Unit \ IO =
        match items {
            case Nil => ()
            case item :: rest =>
                emitOne(gl, st, list, polyData, scaleX, scaleY, registry, targetNames,
                        warnLog, tileUniforms, polyBatchUniforms, drawSurface, drawScene, item);
                emitMerged(gl, st, list, polyData, scaleX, scaleY, registry, targetNames,
                           warnLog, tileUniforms, polyBatchUniforms, drawSurface, drawScene, rest)
        }

    /// 列の 1 個ぶんを描く（スプライトは run へ積むか RenderList の行にする・ほかの種類は溜めた行と run を流してから単発で描く）。
    // WhyNot: emitMerged のループの中へ書き下さない・末尾を呼び出しで終えない — ループの中の呼び出しが末尾呼び出しの続き（Thunk）を返すと、
    //   JVM はループを途中から JIT（OSR）できず、1 コマに 1 回しか呼ばれないループがインタプリタのまま回る（docs/performance.md の 13 節）。
    @DontInline
    def emitOne(gl: GlContext, st: Array[Int32, Static], list: RenderList, polyData: FloatBuffer,
                scaleX: Float64, scaleY: Float64,
                registry: RenderAsset.TextureRegistry,
                targetNames: Set[String],
                warnLog: Ref[Set[String], Static],
                tileUniforms: RenderShader.TileUniforms,
                polyBatchUniforms: RenderShader.PolyBatchUniforms,
                drawSurface: (GlContext, DrawCmd.SurfaceRenderCmd) -> Int32 \ IO,
                drawScene: (Scene3dRenderer.Viewport, Int32) -> Unit \ IO,
                item: Merged): Unit \ IO =
        match item {
            case Merged.MTile(tm) =>
                // タイル層が来たら両 run を吐いてから 1 draw call で描く（列順を守る）。
                // 層は画面全体に敷くので scissor は viewport 全体へ戻し、blend は
                // TileMapRenderCmd が blend を持たない（常に Normal）ため明示的に戻す
                // （前 run の Add/Multiply を持ち越さない）。
                flushSprites(gl, st, list);
                flushPolys(gl, st, polyData, polyBatchUniforms);
                setScissorAt(gl, st, 0, 0, 0, 0, 0);
                RenderSprite.applyBlend(gl, DrawCmd.BlendMode.Normal);
                match Map.get(tm#textureName, registry) {
                    case Some(texInfo) =>
                        RenderSprite.drawTileMapInstanced(gl, Array.get(26, st),
                                             GpuHandle.textureIdInt(texInfo#id),
                                             GpuHandle.tileVaoInt(tm#tileVaoId),
                                             tileUniforms,
                                             tm#position, tm#tileSize, tm#tileScale,
                                             tm#color, tm#tileCount);
                        countSingleDraw(st, kindTile(), 1)
                    // texture 未登録は描かない（穴も開けない）。
                    case None => warnMissingTexture(warnLog, tm#textureName)
                }
            case Merged.MSprite(drawable) =>
                // スプライトが来たら溜まっている多角形 run を先に吐く（列順を守る）。
                flushPolys(gl, st, polyData, polyBatchUniforms);
                if (List.isEmpty(DrawCmd.maskOf(drawable)))
                    emitSprite(st, list, scaleX, scaleY, registry, targetNames,
                               warnLog, drawable)
                else {
                    // mask 付きはステンシルへの描き込みが draw の前後に要るため、
                    // 一括 run に混ぜられない — 自分の run も吐いてから単発で描く。
                    flushSprites(gl, st, list);
                    emitSpriteMasked(gl, st, list#instances, scaleX, scaleY, registry, targetNames,
                                     warnLog, polyBatchUniforms, drawable)
                }
            case Merged.MPoly(pc) =>
                // 多角形が来たら溜まっているスプライト run を先に吐く（列順を守る）。
                flushSprites(gl, st, list);
                emitPoly(gl, st, polyData, polyBatchUniforms, scaleX, scaleY, pc)
            case Merged.MStatic(r) =>
                // 静的レンジが来たら両 run を吐いてから 1 draw call で描く（列順を守る）。
                flushSprites(gl, st, list);
                flushPolys(gl, st, polyData, polyBatchUniforms);
                emitStatic(gl, st, scaleX, scaleY, polyBatchUniforms, r)
            case Merged.MSurface(s) =>
                // シェーダー面が来たら両 run を吐いてから 1 枚描く（列順＝重なり順を守る）。
                // 面は矩形全体を塗るので scissor は viewport 全体に戻す
                // （前 run の clip 矩形を持ち越さない）。
                flushSprites(gl, st, list);
                flushPolys(gl, st, polyData, polyBatchUniforms);
                setScissorAt(gl, st, 0, 0, 0, 0, 0);
                countSingleDraw(st, kindSurface(), drawSurface(gl, s))
            case Merged.MScene3d(i) =>
                // 場面も両 run を吐いてから描く（深度で前後を決めるのは場面の中だけ）。
                flushSprites(gl, st, list);
                flushPolys(gl, st, polyData, polyBatchUniforms);
                drawScene({ x = Array.get(7, st), y = Array.get(8, st), width = Array.get(9, st),
                            height = Array.get(10, st), scaleX = scaleX, scaleY = scaleY }, i);
                // WhyNot: 場面を 2D の draw call に数えない — 中の draw call は 3D の数（Scene3dCounts）に入る。次の 2D の draw call は kind で切れる。
                Array.put(kindScene3d(), 27, st)
        };
        // WhyNot: この () を消さない — match の枝の呼び出しが末尾になり、emitMerged のループが JIT から外れる。
        ()

    /// 多角形を三角形へほどいたときの頂点数の上限（1 個 n 頂点なら 3(n-2) 以下）。
    /// 入れ物をこの数で先に広げておけば、溜めている途中で取り直す
    /// （＝書きかけを捨てる）ことが起きない。
    def polyVertCap(polygons: List[RenderType.PolygonCmd]): Int32 =
        3 * List.foldLeft((acc, pc) -> acc + List.length(pc#vertices), 0, polygons)

    /// 1 フレーム描画: タイル層・sprites・polygons・静的レンジ・シェーダー面を
    /// 1 本の安定ソート列に混ぜ、共有の zIndex どおりの重なり順で描く。
    /// 黒帯部分は scissor で clear する。
    pub def renderFrameMixed(gl: GlContext, args: FrameArgs): Unit \ IO =
        let tileShader   = args#tileShader;
        let registry     = args#registry;
        let clearColor   = args#clearColor;
        let designW      = args#designW;
        let designH      = args#designH;
        let fbW          = args#fbW;
        let fbH          = args#fbH;
        let sprites      = args#sprites;
        let tileMaps     = args#tileMaps;
        let polygons     = args#polygons;
        let staticRanges = args#staticRanges;
        let polyBatchShader = args#polyBatchShader;
        let polyBatchVao = args#polyBatchVao;
        let polyBatchVbo = args#polyBatchVbo;
        let polyBatchUniforms = args#polyBatchUniforms;
        let instShader   = args#instShader;
        let instVao      = args#instVao;
        let instVbo      = args#instVbo;
        let instBuf      = args#instBuf;
        let polyBuf      = args#polyBuf;
        let tileUniforms = args#tileUniforms;
        let instMultiplyBlend = args#instMultiplyBlend;
        let surfaces     = args#surfaces;
        let drawSurface  = args#drawSurface;
        if (fbW > 0 and fbH > 0) {
            // レンダーターゲットは design 全面をテクセル全面へ写す（縦横の倍率が少し違ってよい — uv で読む限りずれない）。
            let (vpX, vpY, vpW, vpH) = match args#targetClear {
                case None    => calcViewport(fbW, fbH, designW, designH)
                case Some(_) => (0, 0, fbW, fbH)
            };
            match args#targetClear {
                case None =>
                    // 画面: 黒帯を含む全面を黒 → design 領域だけ clearColor の 2 段階の clear。
                    gl.viewport(0, 0, fbW, fbH);
                    gl.clearColor(0.0f32, 0.0f32, 0.0f32, 1.0f32);
                    gl.clear(GlConst.COLOR_BUFFER_BIT);
                    gl.viewport(vpX, vpY, vpW, vpH);
                    gl.enable(GlConst.SCISSOR_TEST);
                    gl.scissor(vpX, vpY, vpW, vpH);
                    gl.clearColor(RenderUtil.f32(clearColor#r), RenderUtil.f32(clearColor#g),
                                      RenderUtil.f32(clearColor#b), 1.0f32);
                    gl.clear(GlConst.COLOR_BUFFER_BIT);
                    gl.disable(GlConst.SCISSOR_TEST)
                case Some(op) =>
                    // レンダーターゲット: 全面に写すので黒帯は無い。前の中身の始末は
                    // op の 3 択（RenderTarget.LoadOp の doc を参照）。
                    gl.viewport(vpX, vpY, vpW, vpH);
                    match op {
                        case RenderTarget.LoadOp.Clear(c) =>
                            gl.clearColor(RenderUtil.f32(c#r), RenderUtil.f32(c#g), RenderUtil.f32(c#b), 1.0f32);
                            gl.clear(GlConst.COLOR_BUFFER_BIT)
                        case RenderTarget.LoadOp.ClearTransparent =>
                            gl.clearColor(0.0f32, 0.0f32, 0.0f32, 0.0f32);
                            gl.clear(GlConst.COLOR_BUFFER_BIT)
                        case RenderTarget.LoadOp.Keep => ()
                    }
            };
            // タイル層・sprites・polygons・静的レンジ・シェーダー面を 1 本の安定ソート列に
            // マージして描く。sprite だけ z 順にし polygon を最後へまとめて描くと、ワールド
            // 配置のポリゴン（武器グリフ等）が手前のポップアップを貫通してしまう。全種を
            // 同じ列で並べることで、重なり順が並べ替え鍵の指定どおりになる。静的レンジは
            // 「頂点は既に GPU にある永続 VBO の範囲」を軽い値で表す run 種で、同鍵の
            // 動的アイテムとの前後も入力順で保たれる（洞窟の壁 z=2 が粒 z=2 を正しく隠す等）。
            // 同一鍵内は入力順（tiles → sprites → polygons → static → surfaces）を保つ
            // （stableByZ が構造的に保証）。シェーダー面は zIndex の位置で両 run を吐いてから
            // 1 枚描くので、水を床(z=0)の上・壁(z=2)の下に置ける（clear 直後の一括描画だと
            // zIndex を無視して最下になり、不透明な背景に覆われて消える）。
            // 同 z 内は入力順 = tiles → sprites → polygons → static → surfaces なので、
            // 「同 z ならタイル層が奥」が安定ソートの規約としてそのまま立つ
            // （タイル層を手前に出すには大きい zIndex）。
            let sortedMerged = mergedByZ(tileMaps, sprites, polygons, staticRanges, surfaces, args#scenes#zIndexes);
            // clip 矩形 → framebuffer 座標の整数 scissor 矩形 (x0, y0, x1, y1)（top-left 原点）。
            // record に Eq が無いので、run の分断キーはこの int 組で比較する（fb 画素への
            // 量子化を兼ね、1px 未満の差で run を無駄に割らない）。
            let scaleX = Int32.toFloat64(vpW) / designW;
            let scaleY = Int32.toFloat64(vpH) / designH;
            // 連続する「同じテクスチャ・同じ scissor・同じ blend」のスプライトを 1 回の
            // instanced draw にまとめる（run 収集 → flush）。1 要素 1 draw call だと呼び出しの
            // 固定費が積み上がり、数千体で描画時間のほとんどを占めてしまうため。
            // 書き溜める先は 1 フレーム 1 本の使い回し。RenderList の行は GL を直に呼ぶ種類の手前まで溜まるので、
            // スプライトの数ぶん取る（行を流すたびに先頭へ戻る）。
            RenderBuf.ensure(gl, instBuf, Int32.max(1, List.length(sprites)) * 38);
            RenderBuf.ensure(gl, polyBuf, Int32.max(3, polyVertCap(polygons)) * 6);
            let instData = RenderBuf.buffer(instBuf);
            let polyData = RenderBuf.buffer(polyBuf);
            // run 状態と GL ハンドル定数を Int32 配列 1 本へ詰める（スロット順は stateSize 上のコメント）。
            // 1 フレーム 1 回の小さな割り当てで、以降の 1 item ごとの組・クロージャの
            // 作り直しが消える。
            let st: Array[Int32, Static] = Array.empty(Static, stateSize());
            Array.put(instShader, 0, st);
            Array.put(instVao, 1, st);
            Array.put(instVbo, 2, st);
            Array.put(instMultiplyBlend, 3, st);
            Array.put(polyBatchShader, 4, st);
            Array.put(polyBatchVao, 5, st);
            Array.put(polyBatchVbo, 6, st);
            Array.put(vpX, 7, st);
            Array.put(vpY, 8, st);
            Array.put(vpW, 9, st);
            Array.put(vpH, 10, st);
            Array.put(tileShader, 26, st);
            Array.put(1, 28, st);
            Array.put(if (Array.get(RenderDrawCounts.drawCallsSlot(), args#drawCounts) > 0) 1 else 0, 30, st);
            let list = newRenderList(instData);
            emitMerged(gl, st, list, polyData, scaleX, scaleY, registry, args#targetNames,
                       args#texWarnLog, tileUniforms, polyBatchUniforms, drawSurface, args#scenes#draw, sortedMerged);
            // どちらか片方だけが非空（切替時に相手を吐いているため）。空 flush は no-op。
            flushSprites(gl, st, list);
            flushPolys(gl, st, polyData, polyBatchUniforms);
            addCountsTo(args#drawCounts, st);
            // フレーム末尾で必ず scissor を解除する — 有効なまま持ち越すと、次フレームの
            // 全画面 clear や F8 注釈のスクリーンショット再描画が小矩形に切られる。
            gl.disable(GlConst.SCISSOR_TEST);
            // blend も Normal に戻す — Add/Multiply のまま持ち越すと、次フレーム冒頭の
            // タイルマップや F8 注釈の再描画が違う重ね方で合成される。
            RenderSprite.applyBlend(gl, DrawCmd.BlendMode.Normal)
        } else ()

}
