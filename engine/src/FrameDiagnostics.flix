// FrameDiagnostics — 1 コマぶんの、描く側の診断（GameEngine.Game.consumeDiagnostics が返す）。
// 描く側（render_gl）が集め、App のヒッチの記録（App.HitchDetector）が 1 コマごとに引き取る。
// 集めるのは setDiagnosticsEnabled(true) の間だけ。切っている間は数えない（本番の負担を作らない）。
pub mod FrameDiagnostics {

    /// 1 コマの診断。時間はナノ秒。
    /// - submitNs: renderCommands が GL へ命令を出し終えるまで
    /// - swapNs: 画面の入れ替え（vsync の待ち・ドライバが後回しにした GPU の仕事もここに出る）
    /// - shaderBuilds: このコマで作ったシェーダー（名前と理由）
    /// - shaderDeletes: このコマで GPU から消したシェーダーの数
    /// - liveShaders: 起動から作った数 − 消した数（増え続けるなら漏れ）
    /// - drawItems: renderCommands へ渡った sprite・多角形・タイル層の数
    /// - glyphsAdded: フォントのアトラスへ足した字の数
    /// - textureUploads: 画素を上げ直したテクスチャの名前
    pub type alias Diagnostics = {
        submitNs = Int64,
        swapNs = Int64,
        shaderBuilds = List[ShaderBuild],
        shaderDeletes = Int32,
        liveShaders = Int32,
        drawItems = Int32,
        glyphsAdded = Int32,
        textureUploads = List[String]
    }

    /// 作ったシェーダー 1 つ。
    pub type alias ShaderBuild = { name = String, reason = BuildReason }

    /// 作った理由。Changed は同じ名前で中身が違った時で、違う所の抜き書きを持つ。
    pub enum BuildReason with Eq, ToString {
        case First
        case Changed(String)
    }

    /// 何も起きなかったコマ。
    pub def empty(): Diagnostics =
        { submitNs = 0i64, swapNs = 0i64, shaderBuilds = Nil, shaderDeletes = 0, liveShaders = 0,
          drawItems = 0, glyphsAdded = 0, textureUploads = Nil }
}
