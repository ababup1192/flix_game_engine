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
    use RenderFrame.Internal.GlRows
    use RenderFrame.Internal.GlRows.{drawRenderList, setScissorAt}
    use RenderFrame.Internal.RenderList.{PassSpec, RenderList, appendMaskRow, appendPolyRow, appendSpriteRow, appendStaticRow, appendTileRow, instanceFloats,
                                         kindPoly, kindScene3d, kindSprite, kindSurface, nextInstanceOf, nextMaskRef, nextVertexOf, rowCountOf}

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
        // None = 画面へのフレーム・Some(op) = レンダーターゲット（FBO）へのフレームで、op が前の中身の始末（RenderTarget.LoadOp の doc）。
        // 読むのは GlRows.passOfArgs だけ（描き先の始末と viewport は GlRows.renderPass が受ける PassSpec が決める）。
        // WhyNot: 欄を消さない — PassSpec と二重だが、FrameArgs は RenderFrame の pub の形なので、FrameArgs を Internal へ移す時に消す。
        targetClear = Option[RenderTarget.LoadOp],
        // レンダーターゲットのテクスチャ名の集合。上下逆に格納する backend（GlRows.targetUpsideDown が真）だけが引き、
        // この名前のスプライトの uv を標本時に上下反転する（emitSprite が見る）。
        // WhyNot: 欄を消さない — 描き先の表が backend ごとにあり front-end が引ける共有の表が無い。FrameArgs を Internal へ移す時に消す。
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

    /// 1 体ぶんの model 行列（回転×スケール＋平行移動）を CPU 側で計算して、
    /// instance 属性 (instanceFloats() 個・シェーダ loc1-10 と同並び) を入れ物の slot 番目へ直に書く。
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
        let base = slot * instanceFloats();
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
                // hatch の有効判定は SoftRaster と同式(period<=0 は GLSL の mod が未定義なので無効扱い)。
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

    // ── 詰め込みループの run 状態（front-end の状態）──────────────────────────────
    // run（同テクスチャ・同 clip 矩形・同 blend の連続列）の状態と draw call の数えは Int32 配列 1 本（st）に置く。
    // backend の物（GL は program・VAO・buffer の番号と viewport）はここに置かず、backend が別の配列で持つ（GL は GlRows の gs）。
    // 組やレコードの acc を持ち回らないのは、1 item ごとに組の作り直しと Option+組の等価比較が走り、
    // 物量シーンでフレーム時間に乗るため（スレッドダンプ実測）。局所クロージャに
    // まとめないのも同じ理由 — item 毎に呼ぶには Flix のクロージャは高すぎる（悪化の実測あり）。
    //
    // スプライト run: 0=texId 1=clip有無 2-5=clip矩形 6=blend 7=体数 39=先頭の instance の番号（RenderList の instances の中）
    // 多角形 run:     8=clip有無 9-12=clip矩形 13=blend 14=頂点数 40=先頭の頂点の番号（RenderList の vertices の中）
    // draw call の数え: 15=前の draw call の種類（kind*・0 = まだ無い） 16=この描き先でまだ draw call を出していない
    //              17=前の draw call が mask つき 18=このコマで先に draw call が出ている
    //              19-25=前に出したスプライトの鍵（texId・clip有無・clip矩形・blend） 26-31=前に出した多角形の鍵（clip有無・clip矩形・blend）
    //              32-38=この描き先で数えた数（並びは RenderDrawCounts の slot）
    // mask:       41=この pass で前の mask に使った stencil の値（0 = まだ無いか、stencil を 0 に戻す前提が崩れた）
    //              42=この pass に stencil を使う行を積んだ（1 = 積んだ）
    def stateSize(): Int32 = 43

    def maskRefSlot(): Int32 = 41

    def stencilUsedSlot(): Int32 = 42

    /// この pass の行に stencil を使う mask があるか（WebGPU が stencil つきの pass を開くかを決める）。
    def usesStencil(st: Array[Int32, Static]): Bool \ IO = Array.get(stencilUsedSlot(), st) == 1

    def runFirstSlot(): Int32 = 39

    def polyFirstSlot(): Int32 = 40

    /// 描き先 1 つぶんの run の状態。drawCounts = このコマの数（もう draw call が出ていれば、次の draw call を描き先の切れ目と数える）。
    def newRunState(drawCounts: RenderDrawCounts.Holder): Array[Int32, Static] \ IO =
        let st: Array[Int32, Static] = Array.empty(Static, stateSize());
        Array.put(1, 16, st);
        Array.put(if (Array.get(RenderDrawCounts.drawCallsSlot(), drawCounts) > 0) 1 else 0, 18, st);
        st

    def countBase(): Int32 = 32

    /// この描き先の数 slot を n 足す。
    def bump(st: Array[Int32, Static], slot: Int32, n: Int32): Unit \ IO =
        let i = countBase() + slot;
        Array.put(Array.get(i, st) + n, i, st)

    /// draw call を 1 つ出したと数え、前の draw call に続けられなかった理由を 1 つ数える。
    /// kind = 今の draw call の種類・sameKindReason = 前も同じ種類だった時の理由の slot。コマの最初の draw call は理由を数えない。
    def countDraw(st: Array[Int32, Static], kind: Int32, sameKindReason: Int32): Unit \ IO =
        bump(st, RenderDrawCounts.drawCallsSlot(), 1);
        if (Array.get(16, st) == 1) {
            Array.put(0, 16, st);
            if (Array.get(18, st) == 1) bump(st, RenderDrawCounts.targetSlot(), 1) else ()
        } else if (Array.get(15, st) != kind) bump(st, RenderDrawCounts.kindSlot(), 1)
        else bump(st, sameKindReason, 1);
        Array.put(kind, 15, st)

    /// スプライトの draw call が、前に出したスプライトの draw call に続けられなかった理由の slot。
    /// masked = 今の draw call が mask つき。鍵が全部同じで mask も絡まないのは、間に描かない物（別の種類）が挟まった時。
    def spriteBreakOf(st: Array[Int32, Static], texId: Int32, clipFlag: Int32,
                      x0: Int32, y0: Int32, x1: Int32, y1: Int32, blendC: Int32, masked: Bool): Int32 \ IO =
        if (Array.get(19, st) != texId) RenderDrawCounts.textureSlot()
        else if (Array.get(25, st) != blendC) RenderDrawCounts.blendSlot()
        else if (Array.get(20, st) != clipFlag
                 or (clipFlag != 0 and (Array.get(21, st) != x0 or Array.get(22, st) != y0
                                        or Array.get(23, st) != x1 or Array.get(24, st) != y1))) RenderDrawCounts.clipSlot()
        else if (masked or Array.get(17, st) == 1) RenderDrawCounts.maskSlot()
        else RenderDrawCounts.kindSlot()

    /// スプライトの draw call を数え、その鍵を「前に出したスプライトの鍵」に控える。draws = 出した draw call の数（mask つきは 2）。
    def countSpriteDraw(st: Array[Int32, Static], texId: Int32, clipFlag: Int32,
                        x0: Int32, y0: Int32, x1: Int32, y1: Int32, blendC: Int32, masked: Bool, draws: Int32): Unit \ IO =
        countDraw(st, kindSprite(), spriteBreakOf(st, texId, clipFlag, x0, y0, x1, y1, blendC, masked));
        if (draws > 1) {
            bump(st, RenderDrawCounts.drawCallsSlot(), draws - 1);
            bump(st, RenderDrawCounts.maskSlot(), draws - 1)
        } else ();
        Array.put(if (masked) 1 else 0, 17, st);
        Array.put(texId, 19, st);
        Array.put(clipFlag, 20, st);
        Array.put(x0, 21, st);
        Array.put(y0, 22, st);
        Array.put(x1, 23, st);
        Array.put(y1, 24, st);
        Array.put(blendC, 25, st)

    /// 多角形の行の draw call を数え、その鍵（clip有無・clip矩形・blend）を「前に出した多角形の鍵」に控える。
    def countPolyDraw(st: Array[Int32, Static], clipFlag: Int32, x0: Int32, y0: Int32, x1: Int32, y1: Int32, blendC: Int32): Unit \ IO =
        let reason =
            if (Array.get(31, st) != blendC) RenderDrawCounts.blendSlot()
            else if (Array.get(26, st) != clipFlag
                     or (clipFlag != 0 and (Array.get(27, st) != x0 or Array.get(28, st) != y0
                                            or Array.get(29, st) != x1 or Array.get(30, st) != y1))) RenderDrawCounts.clipSlot()
            else RenderDrawCounts.kindSlot();
        countDraw(st, kindPoly(), reason);
        Array.put(0, 17, st);
        Array.put(clipFlag, 26, st);
        Array.put(x0, 27, st);
        Array.put(y0, 28, st);
        Array.put(x1, 29, st);
        Array.put(y1, 30, st);
        Array.put(blendC, 31, st)

    /// 1 つで 1 draw call の種類（タイル層・static の範囲・Shader の面）を数える。draws = 出した draw call の数（0 なら数えない・mask つきの面は 2）。
    def countSingleDraw(st: Array[Int32, Static], kind: Int32, draws: Int32): Unit \ IO =
        if (draws <= 0) ()
        else {
            countDraw(st, kind, RenderDrawCounts.kindSlot());
            if (draws > 1) {
                bump(st, RenderDrawCounts.drawCallsSlot(), draws - 1);
                bump(st, RenderDrawCounts.maskSlot(), draws - 1)
            } else ();
            Array.put(0, 17, st)
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

    /// 溜めているスプライトの run を 1 行にして閉じる（空 run は行にしない）。
    def closeSpriteRun(st: Array[Int32, Static], list: RenderList): Unit \ IO =
        let count = Array.get(7, st);
        if (count == 0) () else {
            appendSpriteRow(list, Array.get(runFirstSlot(), st), count, Array.get(0, st), Array.get(6, st),
                            Array.get(1, st), Array.get(2, st), Array.get(3, st), Array.get(4, st), Array.get(5, st));
            Array.put(0, 7, st)
        }

    /// 溜めている多角形の run を 1 行にして閉じる（空 run は行にしない）。
    def closePolyRun(st: Array[Int32, Static], list: RenderList): Unit \ IO =
        let count = Array.get(14, st);
        if (count == 0) () else {
            appendPolyRow(list, Array.get(polyFirstSlot(), st), count, Array.get(13, st),
                          Array.get(8, st), Array.get(9, st), Array.get(10, st), Array.get(11, st), Array.get(12, st));
            Array.put(0, 14, st)
        }

    /// 溜めているスプライトと多角形の run を行にして閉じる（同時に両方が非空になることはない）。
    def closeRuns(st: Array[Int32, Static], list: RenderList): Unit \ IO =
        closeSpriteRun(st, list);
        closePolyRun(st, list)

    /// run を閉じ、溜まった行を GL へ流す。GL を直に呼ぶ種類（面・mask つきスプライト・3D の場面）を描く前と、pass の終わりに呼ぶ。
    def flushRows(gl: GlContext, gs: Array[Int32, Static], st: Array[Int32, Static], list: RenderList): Unit \ IO =
        closeRuns(st, list);
        if (rowCountOf(list) == 0) () else drawRenderList(gl, gs, st, list)

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
        let count = Array.get(7, st);
        let sameKey = count != 0
            and Array.get(0, st) == texId
            and Array.get(6, st) == blendC
            and Array.get(1, st) == clipFlag
            and (clipFlag == 0 or (Array.get(2, st) == x0 and Array.get(3, st) == y0
                                   and Array.get(4, st) == x1 and Array.get(5, st) == y1));
        if (sameKey) {
            writeInstAt(list#instances, Array.get(runFirstSlot(), st) + count, posX, posY, sizeX, sizeY, drawable, useTex, sdf);
            Array.put(count + 1, 7, st)
        } else {
            closeSpriteRun(st, list);
            let first = nextInstanceOf(list);
            writeInstAt(list#instances, first, posX, posY, sizeX, sizeY, drawable, useTex, sdf);
            Array.put(first, runFirstSlot(), st);
            Array.put(texId, 0, st);
            Array.put(clipFlag, 1, st);
            Array.put(x0, 2, st);
            Array.put(y0, 3, st);
            Array.put(x1, 4, st);
            Array.put(y1, 5, st);
            Array.put(blendC, 6, st);
            Array.put(1, 7, st)
        }

    /// 1 多角形を三角形化して RenderList の vertices へ直に書く（clip 矩形か重ね方が変わるところでは先に run を行にして閉じる）。
    /// 頂点数が 3 未満（退化）なら何も積まない（run の鍵も進めない — 空 run のまま）。
    def pushPolyKeyed(st: Array[Int32, Static], list: RenderList, clipFlag: Int32,
                      x0: Int32, y0: Int32, x1: Int32, y1: Int32, blendC: Int32,
                      pc: RenderType.PolygonCmd): Unit \ IO =
        let count = Array.get(14, st);
        let sameKey = count != 0
            and Array.get(13, st) == blendC
            and Array.get(8, st) == clipFlag
            and (clipFlag == 0 or (Array.get(9, st) == x0 and Array.get(10, st) == y0
                                   and Array.get(11, st) == x1 and Array.get(12, st) == y1));
        if (sameKey) {
            let n = RenderSprite.writePolyVerts(list#vertices, Array.get(polyFirstSlot(), st) + count, pc);
            if (n < 3) () else Array.put(count + n, 14, st)
        } else {
            closePolyRun(st, list);
            let first = nextVertexOf(list);
            let n = RenderSprite.writePolyVerts(list#vertices, first, pc);
            if (n < 3) () else {
                Array.put(first, polyFirstSlot(), st);
                Array.put(clipFlag, 8, st);
                Array.put(x0, 9, st);
                Array.put(y0, 10, st);
                Array.put(x1, 11, st);
                Array.put(y1, 12, st);
                Array.put(blendC, 13, st);
                Array.put(n, 14, st)
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

    /// 上下逆に格納された描き先（GL の FBO は行 0 が下）の名前 upsideDownTargets の絵なら、
    /// 指定の uv（上原点の部分矩形）を格納の向きへ写して標本する —
    /// ゲーム側は普通の画像と同じ uv で書けばよい。ほかはそのまま返す。
    def targetUvFlipped(upsideDownTargets: Set[String],
                        drawable: RenderType.Drawable): RenderType.Drawable =
        let DrawCmd.Drawable.Drawable(tex, _px, _py, _sx, _sy, _rot,
                                      _cr, _cg, _cb, _a, _cen,
                                      uox, uoy, usx, usy, _z,
                                      _style, _clip, _blend, _mask) = drawable;
        if (Set.memberOf(tex, upsideDownTargets))
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
    /// upsideDownTargets = 上下逆に格納された描き先の名前（upsideDownTargetsOf で backend に聞いた物）。
    def emitSprite(st: Array[Int32, Static], list: RenderList,
                   scaleX: Float64, scaleY: Float64,
                   registry: RenderAsset.TextureRegistry,
                   upsideDownTargets: Set[String],
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
                    let d = targetUvFlipped(upsideDownTargets, drawable);
                    pushSpriteItem(st, list, scaleX, scaleY,
                                   GpuHandle.textureIdInt(texInfo#id),
                                   posX, posY, displayW, displayH, d, true, isFont)
                // texture 未登録は描かない。描かないだけなので run は途切れさせない。
                case None => warnMissingTexture(warnLog, tex)
            }
        }

    /// mask つきスプライト 1 体を行にする（テクスチャ解決と centered の平行移動は emitSprite と同じ式）。
    /// run に混ぜないのは、stencil へ mask を書く draw と、それで比べる draw を 1 体ごとに挟むため。
    def emitSpriteMasked(st: Array[Int32, Static], list: RenderList,
                         scaleX: Float64, scaleY: Float64,
                         registry: RenderAsset.TextureRegistry,
                         upsideDownTargets: Set[String],
                         warnLog: Ref[Set[String], Static],
                         drawable: RenderType.Drawable): Unit \ IO =
        let DrawCmd.Drawable.Drawable(tex, px, py, sx, sy, _rot,
                                      _cr, _cg, _cb, _a, cen,
                                      _uox, _uoy, _usx, _usy, _z,
                                      _style, _clip, _blend, _mask) = drawable;
        if (String.isEmpty(tex)) {
            pushMaskedItem(st, list, scaleX, scaleY, 0, px, py, sx, sy, drawable, false, false)
        } else {
            match Map.get(tex, registry) {
                case Some(texInfo) =>
                    let displayW = texInfo#width * sx;
                    let displayH = texInfo#height * sy;
                    let posX = originAxis(cen, px, displayW);
                    let posY = originAxis(cen, py, displayH);
                    let isFont = String.startsWith({prefix = "font_"}, tex);
                    // uv 反転は emitSprite と同じ（mask は形の変換なので uv には触らない）。
                    let d = targetUvFlipped(upsideDownTargets, drawable);
                    pushMaskedItem(st, list, scaleX, scaleY, GpuHandle.textureIdInt(texInfo#id),
                                   posX, posY, displayW, displayH, d, true, isFont)
                case None => warnMissingTexture(warnLog, tex)
            }
        }

    /// mask つき 1 体を書いて行にする: 溜めている run を閉じ（列順を守る）、instance を 1 体書き、mask を画面の座標へ写して三角形の頂点を vertices へ書き、
    /// stencil の値（RenderList.nextMaskRef）を進めて行を足す。mask が 3 頂点未満なら値を進めず 0 にする（backend は stencil を使わずに描く）。
    def pushMaskedItem(st: Array[Int32, Static], list: RenderList,
                       scaleX: Float64, scaleY: Float64, texId: Int32,
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
        closeRuns(st, list);
        let instanceAt = nextInstanceOf(list);
        writeInstAt(list#instances, instanceAt, posX, posY, sizeX, sizeY, drawable, useTex, sdf);
        let maskFirst = nextVertexOf(list);
        let written = RenderSprite.writeMaskVerts(list#vertices, maskFirst, maskToScreen(rot, posX, posY, sizeX, sizeY, mask));
        let maskCount = if (written < 3) 0 else written;
        let ref = if (maskCount == 0) 0 else nextMaskRef(Array.get(maskRefSlot(), st));
        if (ref > 0) {
            Array.put(ref, maskRefSlot(), st);
            Array.put(1, stencilUsedSlot(), st)
        } else ();
        appendMaskRow(list, instanceAt, maskFirst, maskCount, texId, blendCode(blend), clipFlag, x0, y0, x1, y1, ref)

    /// sprites の (体数, mask を三角形へほどいた時の頂点数の上限) を 1 回の周回で数える（1 個 n 頂点の多角形は 3(n-2) 以下）。
    /// polyVertCap と同じく、入れ物を先に広げておく数。
    def spriteCaps(sprites: List[RenderType.Drawable]): (Int32, Int32) = spriteCapsFrom(sprites, 0, 0)

    // WhyNot: 組を溜める値にした foldLeft にしない — 1 体ごとに組を 1 つ作る。
    def spriteCapsFrom(sprites: List[RenderType.Drawable], count: Int32, verts: Int32): (Int32, Int32) = match sprites {
        case Nil       => (count, verts)
        case d :: rest => spriteCapsFrom(rest, count + 1, verts + maskVertsOf(DrawCmd.maskOf(d)))
    }

    def maskVertsOf(mask: List[List[Vec2.Vec2]]): Int32 = 3 * List.foldLeft((acc, poly) -> acc + List.length(poly), 0, mask)

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

    /// 多角形 1 個を run へ積む（clip 矩形を Int32 鍵へほどく）。溜まっているスプライトの run は呼び側で閉じ終えている前提。
    def emitPoly(st: Array[Int32, Static], list: RenderList,
                 scaleX: Float64, scaleY: Float64, pc: RenderType.PolygonCmd): Unit \ IO =
        match pc#clip {
            case None    => pushPolyKeyed(st, list, 0, 0, 0, 0, 0, blendCode(pc#blend), pc)
            case Some(r) =>
                let (x0, y0, x1, y1) = DrawCmd.clipPixels({ scaleX = scaleX, scaleY = scaleY }, r);
                pushPolyKeyed(st, list, 1, x0, y0, x1, y1, blendCode(pc#blend), pc)
        }

    /// タイルの層 1 つを行にする（両 run を閉じてから — 列順を守る）。texture 未登録は描かない（穴も開けない）。
    def emitTile(st: Array[Int32, Static], list: RenderList, registry: RenderAsset.TextureRegistry,
                 warnLog: Ref[Set[String], Static], tm: RenderType.TileMapRenderCmd): Unit \ IO =
        closeRuns(st, list);
        match Map.get(tm#textureName, registry) {
            case Some(texInfo) =>
                let f32 = RenderUtil.f32;
                let pos = tm#position;
                let scale = tm#tileScale;
                let color = tm#color;
                appendTileRow(list, GpuHandle.textureIdInt(texInfo#id), GpuHandle.tileVaoInt(tm#tileVaoId), tm#tileCount,
                              { posX = f32(pos#x), posY = f32(pos#y), tileSize = f32(tm#tileSize), scaleX = f32(scale#x), scaleY = f32(scale#y),
                                r = f32(color#r), g = f32(color#g), b = f32(color#b) })
            case None => warnMissingTexture(warnLog, tm#textureName)
        }

    /// static layer の範囲 1 本を行にする（両 run を閉じてから — 列順を守る。頂点は既に backend の buffer にある）。
    def emitStatic(st: Array[Int32, Static], list: RenderList, scaleX: Float64, scaleY: Float64, r: RenderStatic.Range): Unit \ IO =
        closeRuns(st, list);
        let f32 = RenderUtil.f32;
        let view = { offsetX = f32(r#viewOffset#x), offsetY = f32(r#viewOffset#y), scaleX = f32(r#viewScale#x), scaleY = f32(r#viewScale#y),
                     halfX = f32(r#halfDesign#x), halfY = f32(r#halfDesign#y) };
        match r#clip {
            case None    => appendStaticRow(list, r#buffer, r#first, r#count, blendCode(r#blend), 0, 0, 0, 0, 0, view)
            case Some(c) =>
                let (x0, y0, x1, y1) = DrawCmd.clipPixels({ scaleX = scaleX, scaleY = scaleY }, c);
                appendStaticRow(list, r#buffer, r#first, r#count, blendCode(r#blend), 1, x0, y0, x1, y1, view)
        }

    /// 並べた 1 個が行になる種類（スプライト・多角形・タイルの層・static layer）なら行へ積んで true。
    /// GL を直に呼ぶ種類（面・3D の場面）は何もせず false（呼び側が溜めた行を流してから描く）。
    // WhyNot: 末尾を呼び出しで終えない — 呼ぶ側のループ（emitOne・WebGpuRows.emitItem）が JIT から外れる（docs/performance.md の 13 節）。
    @DontInline
    def emitRowItem(st: Array[Int32, Static], list: RenderList, scaleX: Float64, scaleY: Float64,
                    registry: RenderAsset.TextureRegistry, upsideDownTargets: Set[String],
                    warnLog: Ref[Set[String], Static], item: Merged): Bool \ IO =
        let done = match item {
            case Merged.MSprite(drawable) =>
                if (List.isEmpty(DrawCmd.maskOf(drawable))) {
                    // スプライトが来たら溜まっている多角形 run を先に閉じる（列順を守る）。
                    closePolyRun(st, list);
                    emitSprite(st, list, scaleX, scaleY, registry, upsideDownTargets, warnLog, drawable)
                } else emitSpriteMasked(st, list, scaleX, scaleY, registry, upsideDownTargets, warnLog, drawable);
                true
            case Merged.MPoly(pc) =>
                closeSpriteRun(st, list);
                emitPoly(st, list, scaleX, scaleY, pc);
                true
            case Merged.MTile(tm) =>
                emitTile(st, list, registry, warnLog, tm);
                true
            case Merged.MStatic(r) =>
                emitStatic(st, list, scaleX, scaleY, r);
                true
            case Merged.MSurface(_) => false
            case Merged.MScene3d(_) => false
        };
        done

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
    def emitMerged(gl: GlContext, gs: Array[Int32, Static], st: Array[Int32, Static], list: RenderList,
                   scaleX: Float64, scaleY: Float64,
                   registry: RenderAsset.TextureRegistry,
                   upsideDownTargets: Set[String],
                   warnLog: Ref[Set[String], Static],
                   drawSurface: (GlContext, DrawCmd.SurfaceRenderCmd) -> Int32 \ IO,
                   drawScene: (Scene3dRenderer.Viewport, Int32) -> Unit \ IO,
                   items: List[Merged]): Unit \ IO =
        match items {
            case Nil => ()
            case item :: rest =>
                emitOne(gl, gs, st, list, scaleX, scaleY, registry, upsideDownTargets,
                        warnLog, drawSurface, drawScene, item);
                emitMerged(gl, gs, st, list, scaleX, scaleY, registry, upsideDownTargets,
                           warnLog, drawSurface, drawScene, rest)
        }

    /// 列の 1 個ぶんを描く（行になる種類は run へ積むか RenderList の行にする・GL を直に呼ぶ種類は溜めた行を流してから単発で描く）。
    // WhyNot: emitMerged のループの中へ書き下さない・末尾を呼び出しで終えない — ループの中の呼び出しが末尾呼び出しの続き（Thunk）を返すと、
    //   JVM はループを途中から JIT（OSR）できず、1 コマに 1 回しか呼ばれないループがインタプリタのまま回る（docs/performance.md の 13 節）。
    @DontInline
    def emitOne(gl: GlContext, gs: Array[Int32, Static], st: Array[Int32, Static], list: RenderList,
                scaleX: Float64, scaleY: Float64,
                registry: RenderAsset.TextureRegistry,
                upsideDownTargets: Set[String],
                warnLog: Ref[Set[String], Static],
                drawSurface: (GlContext, DrawCmd.SurfaceRenderCmd) -> Int32 \ IO,
                drawScene: (Scene3dRenderer.Viewport, Int32) -> Unit \ IO,
                item: Merged): Unit \ IO =
        if (emitRowItem(st, list, scaleX, scaleY, registry, upsideDownTargets, warnLog, item)) ()
        else {
            flushRows(gl, gs, st, list);
            match item {
                case Merged.MSurface(s) =>
                    // WhyNot: 前の行の clip 矩形を残さない — 面は矩形全体を塗るので、残すと切れる。
                    setScissorAt(gl, gs, 0, 0, 0, 0, 0);
                    countSingleDraw(st, kindSurface(), drawSurface(gl, s));
                    // mask つきの面は stencil を自分で 0 にして 1 を書く（mask が 3 頂点未満なら触らない）ので、次の mask は stencil を 0 に戻してから描く。
                    if (List.isEmpty(s#mask)) () else Array.put(0, maskRefSlot(), st)
                case Merged.MScene3d(i) =>
                    drawScene({ x = Array.get(7, gs), y = Array.get(8, gs), width = Array.get(9, gs),
                                height = Array.get(10, gs), scaleX = scaleX, scaleY = scaleY }, i);
                    // WhyNot: 場面を 2D の draw call に数えない — 中の draw call は 3D の数（Scene3dCounts）に入る。次の 2D の draw call は kind で切れる。
                    Array.put(kindScene3d(), 15, st)
                case Merged.MSprite(_) => ()
                case Merged.MTile(_)   => ()
                case Merged.MPoly(_)   => ()
                case Merged.MStatic(_) => ()
            }
        };
        // WhyNot: この () を消さない — match の枝の呼び出しが末尾になり、emitMerged のループが JIT から外れる。
        ()

    /// 多角形を三角形へほどいたときの頂点数の上限（1 個 n 頂点なら 3(n-2) 以下）。
    /// 入れ物をこの数で先に広げておけば、溜めている途中で取り直す
    /// （＝書きかけを捨てる）ことが起きない。
    def polyVertCap(polygons: List[RenderType.PolygonCmd]): Int32 =
        3 * List.foldLeft((acc, pc) -> acc + List.length(pc#vertices), 0, polygons)

    /// 1 フレーム描画: タイル層・sprites・polygons・静的レンジ・シェーダー面を
    /// 1 本の安定ソート列に混ぜ、共有の zIndex どおりの重なり順で描く。黒帯部分は scissor で clear する。
    /// 描き先は args#targetClear で決める（None = 画面）。Pass の描き先の番号と形式は問わない（GL は bind 済みの framebuffer へ描き、どちらも読まない）。
    pub def renderFrameMixed(gl: GlContext, args: FrameArgs): Unit \ IO =
        GlRows.renderPass(gl, args, GlRows.passOfArgs(args))

    /// 上下逆に格納された描き先の名前。backend が上下逆に格納しない（upsideDown が偽）なら空で、描き先の表を引かない。
    def upsideDownTargetsOf(upsideDown: Bool, targetNames: Unit -> Set[String] \ ef): Set[String] \ ef =
        if (upsideDown) targetNames() else Set.empty()

    /// 1 つの pass の中身を、z の列にして GL の backend へ流す（clear と後始末は呼ぶ側）。
    /// gs = GL の backend の状態（GlRows の並び）・list = backend が貸した入れ物の空の列。
    def emitFrameMixed(gl: GlContext, gs: Array[Int32, Static], list: RenderList, args: FrameArgs,
                       pass: PassSpec, upsideDownTargets: Set[String]): Unit \ IO =
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
        let sortedMerged = mergedByZ(args#tileMaps, args#sprites, args#polygons, args#staticRanges, args#surfaces, args#scenes#zIndexes);
        // clip 矩形 → framebuffer 座標の整数 scissor 矩形 (x0, y0, x1, y1)（top-left 原点）。
        // record に Eq が無いので、run の分断キーはこの int 組で比較する（fb 画素への
        // 量子化を兼ね、1px 未満の差で run を無駄に割らない）。
        let (_, _, vpW, vpH) = pass#viewport;
        let scaleX = Int32.toFloat64(vpW) / args#designW;
        let scaleY = Int32.toFloat64(vpH) / args#designH;
        // 連続する「同じテクスチャ・同じ scissor・同じ blend」のスプライトを 1 回の
        // instanced draw にまとめる（run 収集 → flush）。1 要素 1 draw call だと呼び出しの
        // 固定費が積み上がり、数千体で描画時間のほとんどを占めてしまうため。
        let st = newRunState(args#drawCounts);
        emitMerged(gl, gs, st, list, scaleX, scaleY, args#registry, upsideDownTargets,
                   args#texWarnLog, args#drawSurface, args#scenes#draw, sortedMerged);
        flushRows(gl, gs, st, list);
        addCountsTo(args#drawCounts, st)

}
