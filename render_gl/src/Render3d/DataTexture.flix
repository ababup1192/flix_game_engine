// Render3d.DataTexture — 3D の描き手（Render3d）が頂点シェーダーへ渡す数を入れる RGBA32F のテクスチャの置き場。1 回の prepare につき 1 枚を使い、回して書く。
// 姿勢（Render3d.JointTexture）と 1 体ごとの値（Render3d.Instancing）がこの回し方を共有する。約束は Render3d.flix の頭。
// WhyNot: 1 コマ 1 枚に prepare ごとの行を後ろへ足さない — 前の prepare の draw が読んでいる最中のテクスチャへ書くことになり、ドライバが GPU を待つ。
mod Render3d.DataTexture {
    import fge.gl.GlConst
    import fge.gl.GlContext
    import java.nio.FloatBuffer
    use Render3d.{idleTargetFrames}

    /// GPU に置いたテクスチャ 1 枚。height = 確保した行の数・lastUsed = 最後に上げたコマの世代。
    pub type alias DataTexture = { texId = Int32, height = Int32, lastUsed = Int64 }

    /// テクスチャの置き場（GL の文脈ごと・使い道ごとに 1 つ）。texturesRef = (そのコマで何番目の prepare か, 回す順) → テクスチャ・
    /// slot = [次の prepare の順, 回す順]・rowLimit = 行の数の上限（0 は未読み出し）・bufferRef = 数を詰める置き場（初めて上げる時に作る）。
    pub type alias DataTextures = {
        texturesRef = Ref[Map[(Int32, Int32), DataTexture], Static], slot = Array[Int32, Static], rowLimit = Array[Int32, Static],
        bufferRef = Ref[Option[RenderBuf.Buf], Static]
    }

    /// 空の置き場。
    pub def freshTextures(): DataTextures \ IO =
        { texturesRef = Ref.fresh(Static, Map.empty()), slot = Array#{0, 0} @ Static, rowLimit = Array#{0} @ Static, bufferRef = Ref.fresh(Static, None) }

    // ── 決まりの数 ──

    /// テクスチャの幅（texel）。
    pub def textureWidth(): Int32 = Render3dGlsl.dataTextureWidth()

    /// テクスチャの高さの最低。
    def minHeight(): Int32 = 16

    /// 同じ prepare の順のテクスチャを何枚で回すか。
    // WhyNot: 1 枚にしない — 前のコマの draw が GPU でまだ読んでいるテクスチャへ書くと、ドライバが待つ。
    def ringSize(): Int32 = 3

    /// 1 コマの中で分ける prepare の順の数。これを超えた prepare は頭のテクスチャへ戻る（draw を持ち越したままこの数を超えると、持ち越した draw が別の値を読む）。
    // WhyNot: 順を endFrame だけで戻さない — ウィンドウの大きさの変更とスクリーンショットの塗り直しは endFrame を通らず、順が増え続けてテクスチャが溜まる。
    def maxPreparesPerFrame(): Int32 = 16

    /// rows 行を入れるテクスチャの高さ（minHeight() から倍にしていった数・limit で切る）。
    pub def heightFor(limit: Int32, rows: Int32): Int32 =
        Int32.min(limit, doubledUntil(rows, minHeight()))

    def doubledUntil(rows: Int32, height: Int32): Int32 =
        if (height >= rows) height else doubledUntil(rows, height * 2)

    /// 行の数の上限（その GL のテクスチャの高さの上限。1 回だけ読む）。
    pub def rowLimit(gl: GlContext, textures: DataTextures): Int32 \ IO =
        let held = Array.get(0, textures#rowLimit);
        if (held > 0) held
        else {
            let limit = gl.getInteger(GlConst.MAX_TEXTURE_SIZE);
            Array.put(limit, 0, textures#rowLimit);
            limit
        }

    /// need 個の float が入る置き場（prepare ごとに使い回す）。
    pub def bufferFor(gl: GlContext, textures: DataTextures, need: Int32): FloatBuffer \ IO =
        let buf = match Ref.get(textures#bufferRef) {
            case Some(held) => held
            case None       =>
                let made = RenderBuf.make(gl, need);
                Ref.put(Some(made), textures#bufferRef);
                made
        };
        RenderBuf.ensure(gl, buf, need);
        RenderBuf.buffer(buf)

    /// 次のテクスチャを、今の unit に貼って返す（そのコマの順を 1 つ進める）。高さが足りなければ置き場を確保し直す。
    /// 中身はそのコマの prepare ごとに全部の行を書き直すので、前の行を残さない。
    // WhyNot: 確保した高さを縮めない — 物の数は波で増減するので、縮めるとまた増えた時に遊びの途中で確保し直す。1 行 4 KB なので 1,000 体で 128 KB（回す 3 枚で 384 KB）で、持ち続ける代金の方が安い。
    pub def takeTexture(gl: GlContext, textures: DataTextures, gen: Int64, height: Int32): DataTexture \ IO =
        let slot = (Array.get(0, textures#slot), Array.get(1, textures#slot));
        Array.put(Int32.remainder(fst(slot) + 1, maxPreparesPerFrame()), 0, textures#slot);
        let held = Ref.get(textures#texturesRef);
        let texture = match Map.get(slot, held) {
            case Some(found) =>
                gl.bindTexture(GlConst.TEXTURE_2D, found#texId);
                if (found#height >= height) { lastUsed = gen | found }
                else {
                    gl.texImageRgba32f(textureWidth(), height);
                    { height = height, lastUsed = gen | found }
                }
            case None => createTexture(gl, gen, height)
        };
        Ref.put(Map.insert(slot, texture, held), textures#texturesRef);
        texture

    /// NEAREST で読むテクスチャを作り、今の unit に貼って返す。
    // WhyNot: LINEAR にしない — WebGL2 の RGBA32F は不完全なテクスチャになり、読むと 0 が返って形が消える。
    def createTexture(gl: GlContext, gen: Int64, height: Int32): DataTexture \ IO =
        let texId = gl.createTexture();
        gl.bindTexture(GlConst.TEXTURE_2D, texId);
        gl.texImageRgba32f(textureWidth(), height);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MIN_FILTER, GlConst.NEAREST);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MAG_FILTER, GlConst.NEAREST);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_WRAP_S, GlConst.CLAMP_TO_EDGE);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_WRAP_T, GlConst.CLAMP_TO_EDGE);
        { texId = texId, height = height, lastUsed = gen }

    /// 場面を描く前に、その prepare のテクスチャを unit に貼る。None なら何もしない。
    // WhyNot: 上げる時に貼ったままに任せない — Prepared の draw と別の prepare の順は約束していない。貼り直しは場面ごとに 1 回で済む。
    pub def bind(gl: GlContext, unit: Int32, texture: Option[Int32]): Unit \ IO =
        texture |> Option.forEach(texId -> {
            gl.activeTexture(GlConst.TEXTURE0 + unit);
            gl.bindTexture(GlConst.TEXTURE_2D, texId);
            gl.activeTexture(GlConst.TEXTURE0)
        })

    /// 画面のコマの終わりに 1 回: 回す順を進め、しばらく使わなかったテクスチャを捨てる。
    pub def endFrame(gl: GlContext, textures: DataTextures, gen: Int64): Unit \ IO =
        Array.put(0, 0, textures#slot);
        Array.put(Int32.remainder(Array.get(1, textures#slot) + 1, ringSize()), 1, textures#slot);
        let held = Ref.get(textures#texturesRef);
        let idle = Map.filter(t -> gen - t#lastUsed > idleTargetFrames(), held);
        if (Map.isEmpty(idle)) ()
        else {
            Map.forEach((_slot, t) -> gl.deleteTexture(t#texId), idle);
            Ref.put(Map.difference(held, idle), textures#texturesRef)
        }
}
