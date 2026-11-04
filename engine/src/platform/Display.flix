// Display — 今ゲームを映している画面の情報（大きさ・画素の細かさ・入力の種類・端末の区分）。2D と 3D で共通。
// Platform.Window.getDisplay が返し、App が ViewCtx#display（全部）と Frame#sizeClass（区分だけ）に置く。
//
// WhyNot: 区分を窓の大きさだけで決めない — PC のブラウザの窓を狭めただけで Small になり、スマホ向けの並べ方が出る。
//   Ren'Py の screen variant と同じく「入力が指か」と「物理の大きさ」の両方で決める。
pub mod Display {

    /// 端末の区分。Ren'Py の screen variant（small / medium / large）に合わせた 3 つ
    /// （Material の window size class の compact / medium / expanded とは名前が違う）。
    /// Small = スマホ・Medium = タブレット・Large = PC（とデスクトップ版）。
    pub enum SizeClass with Eq, Order, ToString {
        case Small
        case Medium
        case Large
    }

    /// pointer の種類（ブラウザの PointerEvent.pointerType と同じ分け方。ペンは Mouse に入れる）。
    pub enum PointerKind with Eq, ToString {
        case Mouse
        case Touch
    }

    /// size = 描き先（ウィンドウ・canvas）の大きさ（論理 px。ブラウザは CSS px・mac は point）。
    /// scaleFactor = 論理 px 1 つが画素の何個か（ブラウザの devicePixelRatio・Bevy の Window の scale_factor）。
    /// designScale = design の 1px が論理 px で何 px に出るか（黒帯を除いた絵の倍率・縦横の小さい方）。指で押せる大きさ
    /// （44〜48 論理 px）や字の実際の大きさを測るのに使う。
    /// pointer = 最後に来た pointer の入力の種類（キーとゲームパッドでは変わらない。同じ遊びの中で変わる）。
    /// sizeClass = 端末の区分（起動の時に決めて、遊んでいる間は変わらない）。
    pub type alias Display = {
        size = Vec2.Vec2,
        scaleFactor = Float64,
        designScale = Float64,
        pointer = PointerKind,
        sizeClass = SizeClass
    }

    /// 窓の無い所（ヘッドレスの描き出し・当たりを取る View の木・テスト）とデスクトップ版の既定:
    /// Large・Mouse・大きさは design・倍率 1。デスクトップ版の実機は size・scaleFactor・designScale に実際の値を入れる
    /// （区分と pointer はこのまま）。
    pub def desktop(design: Vec2.Vec2): Display =
        { size = design, scaleFactor = 1.0, designScale = 1.0, pointer = PointerKind.Mouse, sizeClass = SizeClass.Large }

    /// 区分の決め方。主な pointer が指でなければ Large。指なら、画面の短い辺（論理 px）が 600 未満で Small・それ以上で Medium
    /// （600 は Material の window size class の compact の上限。スマホの短辺は 360〜430、小さいタブレットは 744 から）。
    pub def sizeClassOf(coarsePointer: Bool, shortSide: Float64): SizeClass =
        if (not coarsePointer) SizeClass.Large
        else if (shortSide < 600.0) SizeClass.Small
        else SizeClass.Medium
}
