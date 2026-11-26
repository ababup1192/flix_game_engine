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
    ///   GPU を待たずに読み、測るのも数コマに 1 回なので、最後に読めた値（何コマか前の値）が続けて入る。
    ///   測れない描き手（CPU の描き出し・時間の query を作れない GL・ブラウザ）と、まだ 1 つも結果が出ていない間は None
    /// - gpuPasses: 描き先ごとの GPU の時間（Pass の名前・画面は "screen"。描いた順）。gpuNs と同じコマの値
    /// - draw2dCounts: 2D の draw call の数と、前の draw に続けられなかった理由ごとの数（欄の意味は Draw2dCounts・Draw2dBatchBreaks）。
    ///   3D の場面の中の draw call は含まない（scene3dCounts#drawCalls）
    /// - scene3dCounts: 3D の場面（Render.scene3d）の数。instances = 置いた物・drawn = そのうち描いた物・
    ///   drawCalls = 3D の draw call（影の地図とビルボードを含む）・droppedPointLights / droppedSpotLights = 上限を超えて
    ///   描かなかった光の数（Scene3d.pickLights が落とした分）。GPU へ上げ直した物と捨てた物の数・3D の描き手の CPU の区間の時間も持つ
    ///   （欄の意味は Scene3dCounts）。3D を描かないコマは 0
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
        draw2dCounts = Draw2dCounts,
        scene3dCounts = Scene3dCounts
    }

    /// 2D の draw call の数（Diagnostics#draw2dCounts）。
    /// - drawCalls: GPU へ出した draw call の数（スプライトの run・多角形の run・タイル層・static の範囲・Shader の面。
    ///   mask つきは stencil へ描く分も数える）
    /// - batchBreaks: 前の draw call に続けられなかった理由ごとの数。コマの最初の draw call は数えないので、合計は drawCalls − 1
    pub type alias Draw2dCounts = { drawCalls = Int32, batchBreaks = Draw2dBatchBreaks }

    /// 2D の draw call が前の draw call に続けられなかった理由ごとの数。1 つの draw call につき 1 つだけ数える。
    /// 当てはまる理由が 2 つ以上ある時は、target → kind → texture → blend → clip → mask の順で先に当てはまった 1 つ。
    /// - target: 描き先（Pass か画面）が変わった最初の draw call
    /// - kind: 種類（スプライト・多角形・タイル層・static の範囲・Shader の面・3D の場面）が前と違う。
    ///   タイル層・static の範囲・Shader の面は 1 つで 1 draw call なので、同じ種類が続いてもここに数える
    /// - texture: スプライトの絵（テクスチャ）が前と違う
    /// - blend: blend が前と違う
    /// - clip: 切り抜きの矩形（scissor）が前と違う
    /// - mask: mask つき（stencil へ描く分・mask つきの本体・その次の draw call）
    pub type alias Draw2dBatchBreaks = { target = Int32, kind = Int32, texture = Int32, blend = Int32, clip = Int32, mask = Int32 }

    /// 2D を描かないコマの数（全部 0）。
    pub def emptyDraw2dCounts(): Draw2dCounts =
        { drawCalls = 0, batchBreaks = { target = 0, kind = 0, texture = 0, blend = 0, clip = 0, mask = 0 } }

    /// 2 コマぶんの数を足す。
    pub def addDraw2dCounts(a: Draw2dCounts, b: Draw2dCounts): Draw2dCounts =
        let (x, y) = (a#batchBreaks, b#batchBreaks);
        { drawCalls = a#drawCalls + b#drawCalls,
          batchBreaks = { target = x#target + y#target, kind = x#kind + y#kind, texture = x#texture + y#texture,
                          blend = x#blend + y#blend, clip = x#clip + y#clip, mask = x#mask + y#mask } }

    /// 理由の名前と数（Draw2dBatchBreaks の欄の順）。
    pub def draw2dBreakList(b: Draw2dBatchBreaks): List[(String, Int32)] =
        ("target", b#target) :: ("kind", b#kind) :: ("texture", b#texture) :: ("blend", b#blend) :: ("clip", b#clip) :: ("mask", b#mask) :: Nil

    /// 理由の名前と数（Scene3dBatchBreaks の欄の順）。
    pub def scene3dBreakList(b: Scene3dBatchBreaks): List[(String, Int32)] =
        ("shadowPass", b#shadowPass) :: ("billboard", b#billboard) :: ("sky", b#sky) :: ("transparent", b#transparent) ::
        ("lightmap", b#lightmap) :: ("skinned", b#skinned) :: ("material", b#material) :: ("mesh", b#mesh) :: Nil

    /// 理由ごとの数を 1 行に（0 の理由は出さない・どれも 0 なら "-"）。breaks = draw2dBreakList か scene3dBreakList。
    pub def breaksText(breaks: List[(String, Int32)]): String = nonZeroText(breaks)

    /// 一番多い理由と数（同じ数なら欄の順で先の物・どれも 0 なら None）。
    pub def topBreak(breaks: List[(String, Int32)]): Option[(String, Int32)] =
        breaks |> List.foldLeft((best, p) -> match best {
            case Some(b) if snd(b) >= snd(p) => best
            case _ if snd(p) > 0             => Some(p)
            case _                           => best
        }, None)

    /// 0 でない数だけを "名前 数" で並べる（どれも 0 なら "-"）。
    def nonZeroText(named: List[(String, Int32)]): String =
        let parts = named |> List.filter(p -> snd(p) != 0) |> List.map(p -> "${fst(p)} ${Int32.toString(snd(p))}");
        if (List.isEmpty(parts)) "-" else String.intercalate(" / ", parts)

    /// 3D の場面の数（Diagnostics#scene3dCounts）。
    /// - meshUploads / meshEvictions: 形（Mesh3d）を GPU へ上げた数 / 置き場から捨てた数
    /// - texture3dUploads: 場面の絵（Texture3d）を mip を作って上げた数
    /// - mipCopies: 登録の絵を GPU から読み戻して mip つきの写しを作った数（読み戻しは GPU を待つ）
    /// - materialBuilds: 組んだ材質のプログラム（名前と理由。描き手は Diagnostics#shaderBuilds にも足す）
    /// - jointUploads: 骨の行列を joint texture へ上げた数（3D の場面を準備する 1 回につき 1 回まで）
    /// - targetRebuilds: Design の解像度の描き先と影の地図の描き先を作った数
    /// - cpuPhases: 3D の描き手の CPU の区間ごとの時間（名前, ns）。区間は入れ子を引いた残り（split の時間は draw に入れない）
    /// - batchBreaks: draw call が 1 つにまとまらなかった理由ごとの数（欄の意味は Scene3dBatchBreaks）
    /// - billboardRuns / billboardImages: 場面の pass のビルボードの行の数（来た順で続く同じ絵の板を 1 行 = 1 draw call にまとめた数）/ その行が貼る絵の種類の数。
    ///   行の数が絵の種類の数よりずっと多いなら、違う絵の板が交互に来ている（同じ絵の板を続けて並べると行が減る）
    /// - shadowMapsReused / shadowMapsRedrawn: 影の地図（点光源の atlas は面 1 つ）のうち、staticGroup の物だけを描いた控えを写して使った数 / 控えを描き直した数。
    ///   描き直しが毎コマ続くなら、光の行列が毎コマ変わっている（太陽の向きを毎コマ回す・点光源が動く）
    /// 作る関数は emptyScene3dCounts（`{ instances = 3 | FrameDiagnostics.emptyScene3dCounts() }`）。
    pub type alias Scene3dCounts = {
        instances = Int32, drawn = Int32, drawCalls = Int32, droppedPointLights = Int32, droppedSpotLights = Int32,
        meshUploads = Int32, meshEvictions = Int32, texture3dUploads = Int32, mipCopies = Int32, materialBuilds = List[ShaderBuild],
        jointUploads = Int32, targetRebuilds = Int32, cpuPhases = List[(String, Int64)], batchBreaks = Scene3dBatchBreaks,
        billboardRuns = Int32, billboardImages = Int32, shadowMapsReused = Int32, shadowMapsRedrawn = Int32
    }

    /// 3D の draw call が分かれた理由ごとの数。3D は batch を鍵でまとめてから描くので、draw call 1 つを 1 つの理由に数える（合計は drawCalls）。
    /// 当てはまる理由が 2 つ以上ある時は、shadowPass → billboard → sky → transparent → lightmap → skinned → material → mesh の順で先に当てはまった 1 つ。
    /// - shadowPass: 影の地図へ描いた draw call
    /// - billboard: ビルボード（来た順で続く同じ絵の板の並びで 1 draw call）
    /// - sky: 空（場面 1 つで 1 draw call）
    /// - transparent: 半透明の材質の物（遠い順に 1 体ずつ）
    /// - lightmap: lightmap つきの材質の物（1 体ずつ）
    /// - skinned: 骨つきの物の batch
    /// - material: 材質のある物の batch のうち、前の batch と材質が違う物（場面の最初の batch も）
    /// - mesh: 材質は前の batch と同じで形が違う batch と、材質の無い物の batch（形ごとに 1 つ）
    pub type alias Scene3dBatchBreaks = { shadowPass = Int32, billboard = Int32, sky = Int32, transparent = Int32,
                                          lightmap = Int32, skinned = Int32, material = Int32, mesh = Int32 }

    /// どの理由も 0。
    pub def emptyScene3dBatchBreaks(): Scene3dBatchBreaks =
        { shadowPass = 0, billboard = 0, sky = 0, transparent = 0, lightmap = 0, skinned = 0, material = 0, mesh = 0 }

    /// 2 コマぶんの理由ごとの数を足す。
    pub def addScene3dBatchBreaks(a: Scene3dBatchBreaks, b: Scene3dBatchBreaks): Scene3dBatchBreaks =
        { shadowPass = a#shadowPass + b#shadowPass, billboard = a#billboard + b#billboard, sky = a#sky + b#sky,
          transparent = a#transparent + b#transparent, lightmap = a#lightmap + b#lightmap, skinned = a#skinned + b#skinned,
          material = a#material + b#material, mesh = a#mesh + b#mesh }

    /// 3D を描かないコマの数（全部 0）。
    pub def emptyScene3dCounts(): Scene3dCounts =
        { instances = 0, drawn = 0, drawCalls = 0, droppedPointLights = 0, droppedSpotLights = 0,
          meshUploads = 0, meshEvictions = 0, texture3dUploads = 0, mipCopies = 0, materialBuilds = Nil,
          jointUploads = 0, targetRebuilds = 0, cpuPhases = Nil, batchBreaks = emptyScene3dBatchBreaks(), billboardRuns = 0, billboardImages = 0,
          shadowMapsReused = 0, shadowMapsRedrawn = 0 }

    /// 上げ直した物と捨てた物の数を 1 行に（どれも 0 なら "-"）。並びは Scene3dCounts の欄の順。
    pub def uploadsText(c: Scene3dCounts): String =
        nonZeroText(("mesh", c#meshUploads) :: ("evict", c#meshEvictions) :: ("tex3d", c#texture3dUploads) :: ("mip", c#mipCopies) ::
                    ("material", List.length(c#materialBuilds)) :: ("joints", c#jointUploads) :: ("targets", c#targetRebuilds) ::
                    ("shadow redraws", c#shadowMapsRedrawn) :: Nil)

    /// CPU の区間を 1 行に（ms は小数 2 桁・区間が無ければ "-"）。
    pub def cpuPhasesText(c: Scene3dCounts): String =
        if (List.isEmpty(c#cpuPhases)) "-"
        else c#cpuPhases |> List.map(p -> "${fst(p)} ${msText(snd(p))}") |> String.intercalate(", ")

    /// 2 コマぶんの数を足す（cpuPhases は同じ名前どうしを足し、初めて出た順に並べる）。
    pub def addScene3dCounts(a: Scene3dCounts, b: Scene3dCounts): Scene3dCounts =
        let names = List.append(a#cpuPhases, b#cpuPhases) |> List.map(fst) |> List.distinct;
        let total = List.append(a#cpuPhases, b#cpuPhases) |> List.foldLeft((acc, p) -> Map.insertWith((x, y) -> x + y, fst(p), snd(p), acc), Map.empty());
        { instances = a#instances + b#instances, drawn = a#drawn + b#drawn, drawCalls = a#drawCalls + b#drawCalls,
          droppedPointLights = a#droppedPointLights + b#droppedPointLights, droppedSpotLights = a#droppedSpotLights + b#droppedSpotLights,
          meshUploads = a#meshUploads + b#meshUploads, meshEvictions = a#meshEvictions + b#meshEvictions,
          texture3dUploads = a#texture3dUploads + b#texture3dUploads, mipCopies = a#mipCopies + b#mipCopies,
          materialBuilds = List.append(a#materialBuilds, b#materialBuilds), jointUploads = a#jointUploads + b#jointUploads,
          targetRebuilds = a#targetRebuilds + b#targetRebuilds,
          cpuPhases = names |> List.map(n -> (n, Map.getWithDefault(n, 0i64, total))),
          batchBreaks = addScene3dBatchBreaks(a#batchBreaks, b#batchBreaks),
          billboardRuns = a#billboardRuns + b#billboardRuns, billboardImages = a#billboardImages + b#billboardImages,
          shadowMapsReused = a#shadowMapsReused + b#shadowMapsReused, shadowMapsRedrawn = a#shadowMapsRedrawn + b#shadowMapsRedrawn }

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
          draw2dCounts = emptyDraw2dCounts(), scene3dCounts = emptyScene3dCounts() }

    /// 画面の隅に出す数行（ms は小数 2 桁）。描くのはゲームの字の部品（出す所と見た目はゲームが決める）。
    /// 診断は view か hudView の ctx#diagnostics から取る。
    /// World へ写さない — 系で Frame#diagnostics を読むと遊んだ記録と再生が食い違う。出すかどうかの切り替えだけを World に置く。
    /// 1 行目 CPU（submit・swap）・2 行目 GPU（全体と描き先ごと）・3 行目 3D の数（ビルボードの行と絵の種類・落とした光があれば末尾に）・4 行目 2D の描く物とシェーダー・
    /// 5 行目 2D の draw call の数と、続けられなかった理由のうち一番多い物。
    /// 3D を置いたコマだけ、続けて上げ直した物と捨てた物・3D の描き手の CPU の区間・3D の draw call が分かれた理由を足す。
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
            + billboardsText(c) + droppedLightsText(c)) ::
        ("2D draw items ${Int32.toString(d#drawItems)} / shaders ${Int32.toString(d#liveShaders)}") ::
        ("2D draw calls ${Int32.toString(d#draw2dCounts#drawCalls)}" + topBreakText(draw2dBreakList(d#draw2dCounts#batchBreaks))) ::
        (if (c#instances == 0) Nil
         else ("3D uploads ${uploadsText(c)}") :: ("3D cpu ${cpuPhasesText(c)}") ::
              ("3D batch breaks ${breaksText(scene3dBreakList(c#batchBreaks))}") :: Nil)

    /// 一番多い理由の字（どれも 0 なら空）。
    def topBreakText(breaks: List[(String, Int32)]): String = match topBreak(breaks) {
        case Some((name, n)) => " / top break ${name} ${Int32.toString(n)}"
        case None            => ""
    }

    /// ビルボードの行と絵の種類の数の字（行が無ければ空）。
    def billboardsText(c: Scene3dCounts): String =
        if (c#billboardRuns == 0) ""
        else " / billboard runs ${Int32.toString(c#billboardRuns)} / images ${Int32.toString(c#billboardImages)}"

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
