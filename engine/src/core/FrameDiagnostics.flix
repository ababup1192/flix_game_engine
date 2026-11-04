// FrameDiagnostics — 1 コマぶんの、描く側の診断（Platform.Diagnostics.consumeDiagnostics が返す）。2D と 3D で共通。
// 描く側（render_gl）が集め、App が 1 コマに 1 回引き取って、ヒッチの記録（App.HitchDetector）と
// ゲーム（App.withDiagnostics → Frame#diagnostics と ViewCtx#diagnostics）へ配る。
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
    /// - gpuNs: GPU がコマの描き先（Pass と画面）を描くのにかけた時間の合計（描き先の間の GPU の空きは含まない）。
    ///   GPU を待たずに読むので 1〜2 コマ前の値。測れない描き手（CPU の描き出し・時間の query を作れない GL）と、
    ///   まだ結果が出ていないコマは None
    /// - gpuPasses: 描き先ごとの GPU の時間（Pass の名前・画面は "screen"。描いた順）。gpuNs と同じコマの値
    /// - scene3dCounts: 3D の場面（Render.scene3d）の数。instances = 置いた物・drawn = そのうち描いた物・
    ///   drawCalls = 3D の draw call（影の地図とビルボードを含む）・droppedPointLights / droppedSpotLights = 上限を超えて
    ///   描かなかった光の数（Scene3d.pickLights が落とした分）。3D を描かないコマは 0
    pub type alias Diagnostics = {
        submitNs = Int64,
        swapNs = Int64,
        shaderBuilds = List[ShaderBuild],
        shaderDeletes = Int32,
        liveShaders = Int32,
        drawItems = Int32,
        glyphsAdded = Int32,
        textureUploads = List[String],
        gpuNs = Option[Int64],
        gpuPasses = List[(String, Int64)],
        scene3dCounts = Scene3dCounts
    }

    /// 3D の場面の数（Diagnostics#scene3dCounts）。
    pub type alias Scene3dCounts = { instances = Int32, drawn = Int32, drawCalls = Int32, droppedPointLights = Int32, droppedSpotLights = Int32 }

    /// 3D を描かないコマの数（全部 0）。
    pub def emptyScene3dCounts(): Scene3dCounts =
        { instances = 0, drawn = 0, drawCalls = 0, droppedPointLights = 0, droppedSpotLights = 0 }

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
          drawItems = 0, glyphsAdded = 0, textureUploads = Nil, gpuNs = None, gpuPasses = Nil,
          scene3dCounts = emptyScene3dCounts() }

    /// 画面の隅に出す数行（ms は小数 2 桁）。描くのはゲームの字の部品（出す所と見た目はゲームが決める）。
    /// 診断は view か hudView の ctx#diagnostics から取る。
    /// World へ写さない — 系で Frame#diagnostics を読むと遊んだ記録と再生が食い違う。出すかどうかの切り替えだけを World に置く。
    /// 1 行目 CPU（submit・swap）・2 行目 GPU（全体と描き先ごと）・3 行目 3D の数（落とした光があれば末尾に）・4 行目 2D の描く物とシェーダー。
    /// WhyNot: 字は ASCII だけ — ゲームは欧文だけのフォントで描くことがあり、日本語の字は □ に化ける。
    pub def summaryLines(d: Diagnostics): List[String] =
        let gpu = match d#gpuNs {
            case Some(ns) => "GPU ${msText(ns)} ms"
            case None     => "GPU -"
        };
        let passes = d#gpuPasses |> List.map(p -> "${fst(p)} ${msText(snd(p))}") |> String.intercalate(", ");
        let c = d#scene3dCounts;
        ("CPU submit ${msText(d#submitNs)} ms / swap ${msText(d#swapNs)} ms") ::
        (if (passes == "") gpu else "${gpu} (${passes})") ::
        ("3D placed ${Int32.toString(c#instances)} / drawn ${Int32.toString(c#drawn)} / draw calls ${Int32.toString(c#drawCalls)}"
            + droppedLightsText(c)) ::
        ("2D draw items ${Int32.toString(d#drawItems)} / shaders ${Int32.toString(d#liveShaders)}") :: Nil

    /// 落とした光の数の字（落としていなければ空）。
    def droppedLightsText(c: Scene3dCounts): String =
        if (c#droppedPointLights == 0 and c#droppedSpotLights == 0) ""
        else " / dropped lights point ${Int32.toString(c#droppedPointLights)} / spot ${Int32.toString(c#droppedSpotLights)}"

    /// ナノ秒を ms の小数 2 桁の字に（四捨五入）。
    def msText(ns: Int64): String =
        let hundredths = (ns + 5000i64) / 10000i64;
        let frac = Int64.remainder(hundredths, 100i64);
        "${Int64.toString(hundredths / 100i64)}.${if (frac < 10i64) "0" else ""}${Int64.toString(frac)}"
}
