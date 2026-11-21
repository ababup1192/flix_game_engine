// RenderPaint.Internal.TextureTable — 絵の CPU の側の表（名前 → TextureInfo の登録簿と、ensureTexture が上げた名前 → key）を、
// GL（RenderPaint）と WebGPU（WebGpuPaint）が同じ関数で育てる。GPU へ上げる所は backend ごとの関数の record（Uploads）で受ける。
// 決まり: Uploads は list を作る def（RenderFrame.emitSprite など 1 体ごとに通る物）へ渡さない。上げるのは list を作る前。
// WhyNot: 上げる所を effect にしない — 列を作る def の型にその effect が乗ると、ブラウザでは 1 体ごとに続きの入れ物の代金を払う。
pub mod RenderPaint.Internal.TextureTable {
    import java.nio.ByteBuffer

    /// backend が絵を GPU へ上げる関数の組。
    /// createArgb(幅, 高さ, ARGB の int の列（行優先・上の行から）) = 新しい絵を作って上げる（NEAREST・REPEAT）・
    /// createImage(幅, 高さ, 解いた画像, alpha) = 解いた画像（alpha が真なら 1 画素 4 バイトの RGBA、偽なら 3 バイトの RGB・上の行から）を
    /// 新しい絵にする（NEAREST・REPEAT。alpha が偽の絵は不透明として読む）・
    /// writeArgb(絵, 幅, 高さ, ARGB) = 同じ大きさの絵の画素を差し替える・drop(絵) = 絵を捨てる。
    pub type alias Uploads = {
        createArgb = (Int32, Int32, Vector[Int32]) -> RenderAsset.TextureInfo \ IO,
        createImage = (Int32, Int32, ByteBuffer, Bool) -> RenderAsset.TextureInfo \ IO,
        writeArgb = (RenderAsset.TextureInfo, Int32, Int32, Vector[Int32]) -> Unit \ IO,
        drop = RenderAsset.TextureInfo -> Unit \ IO
    }

    /// CPU の側の表。registryRef = 名前 → 絵（実行中に増える）・textureKeyRef = ensureTexture が上げた名前 → 最後の key。
    pub type alias Tables = {
        registryRef = Ref[RenderAsset.TextureRegistry, Static],
        textureKeyRef = Ref[Map[String, String], Static]
    }

    /// 1 枚を名前で置く（同じ名前は置き換える）。
    pub def putTexture(tables: Tables, name: String, info: RenderAsset.TextureInfo): Unit \ IO =
        Ref.put(Map.insert(name, info, Ref.get(tables#registryRef)), tables#registryRef)

    /// 名前を registry から外す（GPU の絵は捨てない。捨てるのは呼ぶ側）。
    pub def removeTexture(tables: Tables, name: String): Unit \ IO =
        Ref.put(Map.remove(name, Ref.get(tables#registryRef)), tables#registryRef)

    /// RGB（1 画素 3 バイト）の頭 count 画素を、alpha を 255 にした RGBA（4 バイト）の新しい入れ物へ写す。
    /// 3 バイトの形式を持たない backend（WebGPU）が createImage で alpha の無い絵を広げる。
    // WhyNot: 1 画素ずつ get と put を呼ばない — 入れ物の呼び出しが画素の数の 4 倍になる。配列へまとめて取って広げ、1 回で写す。
    pub def opaqueRgbaOf(rgb: ByteBuffer, count: Int32): ByteBuffer \ IO = region rc {
        let src = Array.repeat(rc, count * 3, 0i8);
        discard rgb.get(0, src, 0, count * 3);
        let dst = Array.repeat(rc, count * 4, -1i8);
        spreadRgb(src, dst, count, 0);
        let rgba = ByteBuffer.allocateDirect(Int32.max(4, count * 4));
        discard rgba.put(0, dst, 0, count * 4);
        rgba
    }

    /// src の RGB を dst の RGBA の頭 3 バイトへ画素 i から写す（dst の alpha は呼ぶ側が埋めておく）。
    def spreadRgb(src: Array[Int8, r], dst: Array[Int8, r], count: Int32, i: Int32): Unit \ r =
        if (i >= count) ()
        else {
            Array.put(Array.get(i * 3, src), i * 4, dst);
            Array.put(Array.get(i * 3 + 1, src), i * 4 + 1, dst);
            Array.put(Array.get(i * 3 + 2, src), i * 4 + 2, dst);
            spreadRgb(src, dst, count, i + 1)
        }

    /// 組み込みの放射の絵（Render.lightAt / darkAt が引く）を上げて名前で引けるようにする。ゲームの manifest には載らない名前なので、
    /// engine が上げる（ゲームに上げさせると「アセット配線をしたゲームだけ光が出る」になる）。上げる時は ensureRadialBuiltins が決める。
    pub def putRadialBuiltins(uploads: Uploads, tables: Tables): Unit \ IO =
        let side = RadialBuiltin.size();
        putTexture(tables, RadialBuiltin.lightName(), uploads#createArgb(side, side, RadialBuiltin.lightPixels()));
        putTexture(tables, RadialBuiltin.darkName(), uploads#createArgb(side, side, RadialBuiltin.darkPixels()))

    /// 組み込みの放射の絵をまだ上げていなくて、reads() が真（これから描く物が引く）なら 2 枚とも上げる。描く物を描き先へ流す前に呼ぶ。
    // WhyNot: 起動時に上げない — 256×256 を 2 枚、画素ごとに平方根を取る仕事が、ブラウザでは「タッチして開始」の後の待ちに入る。引くゲームは少ない。
    // WhyNot: 同じ名前が登録簿にあれば上書きしない — `__` で始まる名前は engine の予約の綴りで、manifest の絵の名前に使われない。
    pub def ensureRadialBuiltins(uploads: Uploads, tables: Tables, reads: Unit -> Bool \ ef): Unit \ ef + IO =
        if (Map.memberOf(RadialBuiltin.lightName(), Ref.get(tables#registryRef))) ()
        else if (reads()) putRadialBuiltins(uploads, tables)
        else ()

    /// Render.lightAt / darkAt の組み込みの絵の名前か。
    pub def isRadialBuiltinName(name: String): Bool =
        name == RadialBuiltin.lightName() or name == RadialBuiltin.darkName()

    /// sprites と surfaces のどれかが、名前が isName に当たる絵を引くか。
    pub def isTextureRead(isName: String -> Bool, sprites: List[DrawCmd.Drawable], surfaces: List[DrawCmd.SurfaceRenderCmd]): Bool =
        List.exists(d -> isName(DrawCmd.textureOf(d)), sprites)
            or List.exists(cmd -> List.exists(read -> isName(fst(read)), cmd#texReads), surfaces)

    /// GpuResources.ensureTexture の中身。key が前と同じなら何もしない（毎フレーム呼ばれる前提）。
    /// 大きさが同じなら画素だけ差し替え（GPU の絵を作り直さない）、違えば古い方を捨てて作り直す（漏らすと作り直すたびに GPU のメモリが増え続ける）。
    /// 上げた時だけ noteUpload を呼ぶ（診断の textureUploads）。
    /// マニフェストで読んだ絵（key を持たない名前）と同じ名前には書かない — 辺長が同じだと元の絵の中身を上書きしてしまう。
    pub def ensureTexture(uploads: Uploads, tables: Tables, noteUpload: Unit -> Unit \ ef,
                          name: String, key: String, width: Int32, height: Int32, argb: Vector[Int32]): Unit \ ef + IO =
        let keys = Ref.get(tables#textureKeyRef);
        if (Map.get(name, keys) == Some(key)) ()
        else {
            noteUpload();
            let prev = Map.get(name, Ref.get(tables#registryRef));
            let taken = not Option.isEmpty(prev) and Option.isEmpty(Map.get(name, keys));
            if (taken) println("[ensureTexture] 名前 '${name}' はすでに別の絵が使っています（上書きしません）")
            else {
                let info = match prev {
                    case Some(old) if old#width == Int32.toFloat64(width) and old#height == Int32.toFloat64(height) =>
                        uploads#writeArgb(old, width, height, argb);
                        old
                    case Some(old) =>
                        uploads#drop(old);
                        uploads#createArgb(width, height, argb)
                    case None => uploads#createArgb(width, height, argb)
                };
                putTexture(tables, name, info);
                Ref.put(Map.insert(name, key, Ref.get(tables#textureKeyRef)), tables#textureKeyRef)
            }
        }
}
