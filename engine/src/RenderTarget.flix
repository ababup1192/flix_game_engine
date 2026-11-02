// RenderTarget — レンダーターゲット（描いた結果をテクスチャとして読み返せる描き込み先）の
// 入口（eff Target）。
//
// なぜ eff Game でなく別の効果か: eff Game に描画オペを足すと、その効果を張る全ハンドラ
// （本番のバックエンド・テストのスタブ）が新オペの実装を義務づけられて波及する。描き込み先の
// 切り替えは通常の描画終端（renderCommands）の外側の関心なので、別の eff Target に隔離して
// 既存のハンドラを無傷に保つ（ShaderEffect と同じ理由・同じ形）。
//
// 利用の形: beginTarget({ name, … }) → renderCommands（この間の描画は画面でなくターゲットに
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

    /// ターゲットの寸法の基準。Design = design 解像度（ドット絵の画素の大きさにそろえる）・
    /// Window = 描き先の画素（窓の実際の大きさ・動画やスクリーンショットの書き出しの倍率。3D や後処理を画面の解像度で描く）。
    pub enum Basis with Eq, ToString {
        case Design
        case Window
    }

    /// ターゲットの画素の形式（wgpu の TextureFormat と同じ名前）。
    /// Rgba8Unorm = 各成分 8bit・0..1（書く時に 0..1 へ切る）。
    /// Rgba16Float = 各成分 16bit の浮動小数（half）。1 を超える明るさをそのまま持てる（HDR の Pass。最後にトーンマッピングで 0..1 へ収める）。
    ///   描き先が対応していない環境では Rgba8Unorm で作り直し、名前ごとに 1 回知らせる。
    pub enum Format with Eq, ToString {
        case Rgba8Unorm
        case Rgba16Float
    }

    /// ターゲットの作り方（毎コマの中身 = Render.Pass とは別に、名前ごとに 1 つ）。wgpu / Unity の
    /// TextureDescriptor・RenderTextureDescriptor と同じ分け方で、LoadOp は「描くたび」の性質なので Pass に、
    /// 寸法と形式は「テクスチャを作る時」の性質なのでここに置く。
    /// scale = basis の寸法に掛ける倍率（Unity の renderScale・Godot の scaling_3d_scale と同じ語）。0 より大きく 1 以下。
    /// basis = 寸法の基準（Design なら design × scale・Window なら描き先の画素 × scale）。
    /// format = 画素の形式（既定は Rgba8Unorm。HDR の Pass は withHdr で Rgba16Float に）。
    /// 組む時は `{ scale = 0.5 | RenderTarget.defaultDescriptor() }` の形で書く（欄を足してもゲームの字が止まらないように）。
    pub type alias Descriptor = { scale = Float64, basis = Basis, format = Format }

    /// 既定（design 解像度そのまま・Rgba8Unorm）。
    pub def defaultDescriptor(): Descriptor = { scale = 1.0, basis = Basis.Design, format = Format.Rgba8Unorm }

    /// 描き先の画素そのまま（窓が 1920 × 1080 なら 1920 × 1080 で描く）・Rgba8Unorm。
    pub def windowDescriptor(): Descriptor = { scale = 1.0, basis = Basis.Window, format = Format.Rgba8Unorm }

    /// d の形式を Rgba16Float にした作り方（1 を超える明るさを持つ Pass。`RenderTarget.withHdr(RenderTarget.windowDescriptor())`）。
    pub def withHdr(d: Descriptor): Descriptor = { format = Format.Rgba16Float | d }

    /// scale が範囲（0 より大きく 1 以下・有限）の中か。外なら scaleOf が 1.0 に直す（Render.resolvePassReads が知らせる）。
    pub def isScaleInRange(d: Descriptor): Bool =
        Float64.isFinite(d#scale) and d#scale > 0.0 and d#scale <= 1.0

    /// 範囲に収めた倍率。0 以下・1 より大きい・非有限は 1.0（既定値で続ける。知らせるのは呼び手）。
    pub def scaleOf(d: Descriptor): Float64 =
        if (isScaleInRange(d)) d#scale else 1.0

    /// ターゲットのテクセル寸法。どの経路もこの 1 本で決める（GL・描き出し・App が別々に丸めると 1px 割れる）。
    /// pixelScale = 描き手の design px → 描き先の画素の倍率（Target.pixelScale の答え・描き出しは RenderConfig#scale）。
    /// 各軸 max(1, ceil(design × 基準の倍率 × scale))。基準の倍率は Design なら 1・Window なら pixelScale（0 以下・非有限は 1）。
    pub def texelSizeOf(design: Vec2.Vec2, pixelScale: Float64, d: Descriptor): (Int32, Int32) =
        let base = match d#basis {
            case Basis.Design => 1.0
            case Basis.Window => if (Float64.isFinite(pixelScale) and pixelScale > 0.0) pixelScale else 1.0
        };
        let s = base * scaleOf(d);
        let axis = v -> Int32.max(1, Float64.tryToInt32(Float64.ceil(v * s)) |> Option.getWithDefault(1));
        (axis(design#x), axis(design#y))

    /// 自分の名前を読む Pass が、前のコマの中身（history）を読むための別名。Render.resolvePassReads が書き換え、
    /// GL（RenderPaint）と描き出し（HeadlessRender）が同じ字で用意する。
    pub def historyName(name: String): String = name + "@history"

    /// ターゲットを開く時の宣言（Target.beginTarget に渡す 1 つ）。
    /// name = ターゲットの名前（そのままテクスチャ名）。width / height = テクセル寸法（texelSizeOf の答え）。
    /// format = 画素の形式（Descriptor#format）。clear = 前の中身の始末（LoadOp の doc を参照）。
    /// WhyNot: op の引数に並べない — 欄を足すたびに eff の形が変わり、全部のハンドラが止まる。
    pub type alias TargetSpec = { name = String, width = Int32, height = Int32, format = Format, clear = LoadOp }

    /// レンダーターゲットへの描画チャンネル。eff Game とは別に隔離した効果。
    pub eff Target {
        /// ターゲットを開く。以降の renderCommands は画面でなくここに描かれる（swap もしない）。
        /// 中は design 座標のまま描き、design 全面がテクスチャ全面に写る（投影は差し替えない）。貼るときの大きさは design 寸法のまま。
        def beginTarget(spec: RenderTarget.TargetSpec): Unit
        /// 描き手の design px → 描き先の画素の倍率（窓なら窓の実際の大きさに収めた倍率・動画やスクリーンショットはその書き出しの倍率）。
        /// Window の基準のターゲットの寸法（texelSizeOf）に使う。
        def pixelScale(): Float64
        /// ターゲットを閉じて描画先を画面へ戻す。
        def endTarget(): Unit
    }

    /// レンダーターゲットを使わないゲーム・GL の無い環境（テスト等）向けの何もしないハンドラ。
    pub def runNoop(f: Unit -> a \ ef + Target): a \ ef =
        run f() with handler Target {
            def beginTarget(_spec, k) = k(())
            def pixelScale(k)         = k(1.0)
            def endTarget(k)          = k(())
        }
}
