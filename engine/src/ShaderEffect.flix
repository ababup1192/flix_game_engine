// ShaderEffect — 宣言シェーダー面を GPU で描くための「別チャンネル」の入口（eff Shader）。
//
// なぜ eff Game でなく別の効果か: eff Game に描画オペを足すと、その効果を張る全ハンドラ
// （本番のバックエンド・テストのスタブ）が新オペの実装を義務づけられて波及する。シェーダー面は
// 通常の描画終端（renderCommands）に乗らない別物なので、別の eff Shader に隔離して既存の
// ハンドラを無傷に保つ。シェーダーを使わないゲームは runNoop を張れば「描けない」を素直に表せる。
//
// 利用例: 起動時に Spec を GPU プログラムへ compile（buildProgram）→ 毎フレーム面 1 枚を描く（drawSurface）。

pub mod ShaderEffect {

    /// シェーダー面 1 枚ぶんの描画依頼。
    /// program = buildProgram が返した GPU ハンドル、rect = 塗る矩形（スクリーン空間 px・uv=0..1 が
    /// この矩形）、time = uTime uniform に渡す秒、zIndex = 重なり順（骨格では固定 z-index の範囲へそろせる）、
    /// blend = 重ね方。
    /// texNames = Spec の Tex ノードが読むテクスチャ名（ShaderDoc.texNames の正典順）。
    /// program は GLSL ソースが鍵のキャッシュで共有され、名前を GLSL に写さないため、
    /// 「どの名前をどの sampler unit に bind するか」は cmd がここで運ぶ（構造が同じで
    /// 名前だけ違う 2 面が同じ program を使っても正しい絵になる）。
    pub type alias ShaderRenderCmd = {
        program = GpuHandle.ShaderProgram,
        texNames = List[String],
        rect = Rect2.Rect2,
        // 面を切り抜く多角形の列（スクリーン空間 px の三角形化前の頂点）。空なら矩形そのまま、
        // 非空なら GL がステンシルへ生成して「多角形の内側だけ」塗る（丸い池形など任意形に抜く）。
        mask = List[List[Vec2.Vec2]],
        time = Float64,
        zIndex = Int32,
        blend = DrawCmd.BlendMode
    }

    /// シェーダー面の描画チャンネル。eff Game とは別に隔離した効果。
    pub eff Shader {
        /// Spec を GLSL プログラムへコンパイルしハンドルを返す（起動時/リロード時に 1 回）。
        /// 失敗時は bug! でなく単色フォールバックプログラムを返す（fail-open）— theme 由来の
        /// codegen ミスで全体がクラッシュしないように。
        def buildProgram(spec: ShaderDoc.Spec): GpuHandle.ShaderProgram
        /// シェーダー面 1 枚を描く。骨格では「床タイルと壁の間の固定 z-index の範囲」へそろえて
        /// renderCommands の下に敷く（暗くするオーバーレイ・ハロが上に正しく乗る）。
        def drawSurface(cmd: ShaderRenderCmd): Unit
    }

    /// シェーダーを使わないゲーム・GL の無い環境（テスト等）向けの何もしないハンドラ。
    /// buildProgram は無効ハンドル（0）を返し、drawSurface は捨てる。面が来ても落ちない。
    pub def runNoop(f: Unit -> a \ ef + Shader): a \ ef =
        run f() with handler Shader {
            def buildProgram(_spec, k) = k(GpuHandle.wrapShaderProgram(0))
            def drawSurface(_cmd, k)   = k(())
        }
}
