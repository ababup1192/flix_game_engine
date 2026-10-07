// GpuHandle — バックエンドが割り当てる描画リソースのハンドル。
//
// タイル VBO やテクスチャの実体（OpenGL の VAO/テクスチャ id など）を 1 枚の型で包む。
// フロントやゲームは中身を読まずに値として持ち運ぶだけで、中身の意味はバックエンド
// （render_gl など）だけが `*Int` で取り出して知る。バックエンドを差し替えても、
// ハンドルの中身の表現だけが変わり、運ぶ側のコードは変わらない。

pub mod GpuHandle {

    /// タイルマップの GPU インスタンスバッファのハンドル（`initTileBuffer` が返す）。
    pub enum TileVao { case TileVao(Int32) }

    /// 永続化した静的多角形の GPU バッファのハンドル（`initStaticPolys` が返す）。
    /// タイルと違い後で解放する（フロアを行き来するたびに作り直すため）ので、
    /// 削除に要る VBO も一緒に包む（vao, vbo の 2 つ）。
    pub enum StaticVao { case StaticVao(Int32, Int32) }

    /// テクスチャの GPU ハンドル。
    pub enum TextureId { case TextureId(Int32) }

    /// 宣言シェーダー面をコンパイルした GPU プログラムのハンドル（`buildProgram` が返す）。
    /// コンパイル/リンクに失敗した面のためのフォールバック単色プログラムも同じ型で運ぶ。
    pub enum ShaderProgram { case ShaderProgram(Int32) }

    /// Int32 の実体をハンドルに包む（バックエンドが割り当て時に呼ぶ）。
    pub def wrapTileVao(v: Int32): TileVao = TileVao.TileVao(v)

    /// ハンドルから Int32 の実体を取り出す（バックエンドが描画時に呼ぶ）。
    pub def tileVaoInt(h: TileVao): Int32 = let TileVao.TileVao(v) = h; v

    /// 静的多角形の VAO/VBO の実体をハンドルに包む（バックエンドが割り当て時に呼ぶ）。
    pub def wrapStaticVao(vao: Int32, vbo: Int32): StaticVao = StaticVao.StaticVao(vao, vbo)

    /// ハンドルから VAO の実体を取り出す（描画時に使う）。
    pub def staticVaoInt(h: StaticVao): Int32 = let StaticVao.StaticVao(v, _) = h; v

    /// ハンドルから VBO の実体を取り出す（解放時に使う）。
    pub def staticVboInt(h: StaticVao): Int32 = let StaticVao.StaticVao(_, v) = h; v

    /// Int32 の実体をハンドルに包む。
    pub def wrapTextureId(v: Int32): TextureId = TextureId.TextureId(v)

    /// ハンドルから Int32 の実体を取り出す。
    pub def textureIdInt(h: TextureId): Int32 = let TextureId.TextureId(v) = h; v

    /// Int32 の実体をハンドルに包む（バックエンドがコンパイル成功時に呼ぶ）。
    pub def wrapShaderProgram(v: Int32): ShaderProgram = ShaderProgram.ShaderProgram(v)

    /// ハンドルから Int32 の実体を取り出す（描画時に使う）。
    pub def shaderProgramInt(h: ShaderProgram): Int32 = let ShaderProgram.ShaderProgram(v) = h; v

}
