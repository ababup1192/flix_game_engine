// RenderPaint.Internal.TextureTable — 絵の CPU の側の表（名前 → TextureInfo の登録簿と、ensureTexture が上げた名前 → key）を、
// GL（RenderPaint）と WebGPU（WebGpuPaint）が同じ関数で育てる。GPU へ上げる所は backend ごとの関数の record（Uploads）で受ける。
// 決まり: Uploads は list を作る def（RenderFrame.emitSprite など 1 体ごとに通る物）へ渡さない。上げるのは list を作る前。
// WhyNot: 上げる所を effect にしない — 列を作る def の型にその effect が乗ると、ブラウザでは 1 体ごとに続きの入れ物の代金を払う
//   （plans/webgpu-shape-review-2d.md の 3.3）。
pub mod RenderPaint.Internal.TextureTable {

    /// backend が絵を GPU へ上げる関数の組。
    /// createArgb(幅, 高さ, ARGB の int の列（行優先・上の行から）) = 新しい絵を作って上げる（NEAREST・REPEAT）・
    /// writeArgb(絵, 幅, 高さ, ARGB) = 同じ大きさの絵の画素を差し替える・drop(絵) = 絵を捨てる。
    pub type alias Uploads = {
        createArgb = (Int32, Int32, Vector[Int32]) -> RenderAsset.TextureInfo \ IO,
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

    /// 組み込みの放射の絵（Render.lightAt / darkAt が引く）を上げて名前で引けるようにする。ゲームの manifest には載らない名前なので、
    /// 起動時に必ず上げる（ここで足さないと「アセット配線をしたゲームだけ光が出る」になる）。
    pub def putRadialBuiltins(uploads: Uploads, tables: Tables): Unit \ IO =
        let side = RadialBuiltin.size();
        putTexture(tables, RadialBuiltin.lightName(), uploads#createArgb(side, side, RadialBuiltin.lightPixels()));
        putTexture(tables, RadialBuiltin.darkName(), uploads#createArgb(side, side, RadialBuiltin.darkPixels()))

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
