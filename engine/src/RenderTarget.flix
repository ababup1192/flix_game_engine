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

    /// レンダーターゲットへの描画チャンネル。eff Game とは別に隔離した効果。
    pub eff Target {
        /// ターゲットを開く。以降の renderCommands は画面でなくここに描かれる（swap もしない）。
        /// width/height はターゲットの px 寸法 — **design 解像度と同じ値を渡すこと**（投影行列が
        /// design 前提で固定されているため。別寸法のターゲットは投影の差し替えごと将来の拡張）。
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
