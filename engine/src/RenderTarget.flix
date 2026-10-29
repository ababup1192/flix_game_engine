// RenderTarget — レンダーターゲット（描いた結果をテクスチャとして読み返せる描き込み先）の
// 入口（eff Target）。
//
// なぜ eff Game でなく別の効果か: eff Game に描画オペを足すと、その効果を張る全ハンドラ
// （本番のバックエンド・テストのスタブ）が新オペの実装を義務づけられて波及する。描き込み先の
// 切り替えは通常の描画終端（renderCommands）の外側の関心なので、別の eff Target に隔離して
// 既存のハンドラを無傷に保つ（ShaderEffect と同じ理由・同じ形）。
//
// 利用の形: beginTarget(名前, …) → renderCommands（この間の描画は画面でなくターゲットに
// 着く）→ endTarget。ターゲットの中身は同じ名前のテクスチャとして登録され、以降
// Render.sprite(名前, z) で普通のスプライトとして貼れる（部分切り出し・blend・拡大も
// 既存の道がそのまま効く）。
pub mod RenderTarget {

    /// ターゲットを開くたびに前の中身をどう始末するかの 3 択（wgpu / Vulkan の LoadOp と同じ語彙）。
    /// Keep = 前フレームの中身をそのまま残す（残像・軌跡。ターゲットの作成直後だけは全画素透明）。
    /// Clear(c) = 毎フレームその色の不透明で塗ってから始める。
    /// ClearTransparent = 毎フレーム全画素透明から始める — Normal 合成で貼っても、描いて
    /// いない画素が下の絵を潰さない（黒 Clear のターゲットを Normal で貼ると下が黒く潰れる）。
    pub enum LoadOp {
        case Keep
        case Clear(Color)
        case ClearTransparent
    }

    /// ターゲットの作り方（毎コマの中身 = Render.Pass とは別に、名前ごとに 1 つ）。wgpu / Unity の
    /// TextureDescriptor・RenderTextureDescriptor と同じ分け方で、LoadOp は「描くたび」の性質なので Pass に、
    /// 寸法は「テクスチャを作る時」の性質なのでここに置く。
    /// scale = design 解像度に掛ける倍率（Unity の renderScale・Godot の scaling_3d_scale と同じ語）。0 より大きく 1 以下。
    /// 組む時は `{ scale = 0.5 | RenderTarget.defaultDescriptor() }` の形で書く（欄を足してもゲームの字が止まらないように）。
    pub type alias Descriptor = { scale = Float64 }

    /// 既定（design 解像度そのまま）。
    pub def defaultDescriptor(): Descriptor = { scale = 1.0 }

    /// 範囲に収めた倍率。0 以下・1 より大きい・非有限は 1.0（既定値で続ける。知らせるのは呼び手）。
    pub def scaleOf(d: Descriptor): Float64 =
        if (Float64.isFinite(d#scale) and d#scale > 0.0 and d#scale <= 1.0) d#scale else 1.0

    /// ターゲットのテクセル寸法。どの経路もこの 1 本で決める（GL・描き出し・App が別々に丸めると 1px 割れる）。
    /// 各軸 max(1, ceil(design × scale))。scale = 1 なら design そのもの。
    pub def sizeOf(design: Vec2.Vec2, d: Descriptor): (Int32, Int32) =
        let s = scaleOf(d);
        let axis = v -> Int32.max(1, Float64.tryToInt32(Float64.ceil(v * s)) |> Option.getWithDefault(1));
        (axis(design#x), axis(design#y))

    /// 自分の名前を読む Pass が、前のコマの中身（history）を読むための別名。Render.resolvePassReads が書き換え、
    /// GL（RenderPaint）と描き出し（HeadlessRender）が同じ字で用意する。
    pub def historyName(name: String): String = name + "@history"

    /// レンダーターゲットへの描画チャンネル。eff Game とは別に隔離した効果。
    pub eff Target {
        /// ターゲットを開く。以降の renderCommands は画面でなくここに描かれる（swap もしない）。
        /// width/height はターゲットのテクセル寸法（sizeOf の答え）。中は design 座標のまま描き、design 全面が
        /// テクスチャ全面に写る（投影は差し替えない）。貼るときの大きさは design 寸法のまま。
        /// clear は前の中身の始末（LoadOp の doc を参照）。
        def beginTarget(name: String, width: Int32, height: Int32, clear: RenderTarget.LoadOp): Unit
        /// ターゲットを閉じて描画先を画面へ戻す。
        def endTarget(): Unit
    }

    /// レンダーターゲットを使わないゲーム・GL の無い環境（テスト等）向けの何もしないハンドラ。
    pub def runNoop(f: Unit -> a \ ef + Target): a \ ef =
        run f() with handler Target {
            def beginTarget(_name, _w, _h, _clear, k) = k(())
            def endTarget(k)                           = k(())
        }
}
