// Display — 今ゲームを映している画面の情報（大きさ・画素の細かさ・入力の種類・端末の区分・design の向き）。2D と 3D で共通。
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

    /// 起動の時に選んだ design の向き（持ち方ではない）。縦の指定（project.json の web.portraitDesign）を持つゲームを
    /// 縦に持って開いた時だけ Portrait で、縦の指定の無いゲームは縦に持っても Landscape（横の design を帯で出す）。
    /// 遊んでいる間に回しても変わらない（作り直さず、起動の時の比のまま帯で合わせる）。
    // WhyNot: 持ち方で決めない — ゲームが並べ方を替えたいのは design の形が変わった時だけで、持ち方の差（パッドの置き場所）は頁の CSS が持つ。
    pub enum Orientation with Eq, ToString {
        case Landscape
        case Portrait
    }

    /// design の大きさの形から向きを決める（高さが幅より大きい時だけ Portrait）。
    pub def orientationOf(design: Vec2.Vec2): Orientation =
        if (design#y > design#x) Orientation.Portrait else Orientation.Landscape

    /// size = 描き先（ウィンドウ・canvas）の大きさ（論理 px。ブラウザは CSS px・mac は point）。
    /// scaleFactor = 論理 px 1 つが画素の何個か（ブラウザの devicePixelRatio・Bevy の Window の scale_factor）。
    /// designScale = design の 1px が論理 px で何 px に出るか（黒帯を除いた絵の倍率・縦横の小さい方）。指で押せる大きさ
    /// （44〜48 論理 px）や字の実際の大きさを測るのに使う。
    /// pointer = 最後に来た pointer の入力の種類（キーとゲームパッドでは変わらない。同じ遊びの中で変わる）。
    /// sizeClass = 端末の区分（起動の時に決めて、遊んでいる間は変わらない）。
    /// orientation = 起動の時に選んだ design の向き（orientationOf(design)。遊んでいる間は変わらない）。
    pub type alias Display = {
        size = Vec2.Vec2,
        scaleFactor = Float64,
        designScale = Float64,
        pointer = PointerKind,
        sizeClass = SizeClass,
        orientation = Orientation
    }

    /// 窓の無い所（ヘッドレスの描き出し・当たりを取る View の木・テスト）とデスクトップ版の既定:
    /// Large・Mouse・大きさは design・倍率 1・向きは design の形から。デスクトップ版の実機は size・scaleFactor・designScale に実際の値を入れる
    /// （区分と pointer と向きはこのまま）。
    pub def desktop(design: Vec2.Vec2): Display =
        { size = design, scaleFactor = 1.0, designScale = 1.0, pointer = PointerKind.Mouse, sizeClass = SizeClass.Large,
          orientation = orientationOf(design) }

    /// 縦に持ったスマホの画面の大きさ（CSS px）の既定。デスクトップで縦を確かめる起動（FLIX_GE_PORTRAIT=1）と、
    /// 画面なしの縦の描き出しが、縦の design の高さを決めるのに使う。
    pub def defaultPortraitView(): Vec2.Vec2 = { x = 390.0, y = 844.0 }

    /// 窓の無い所で「縦に持ったスマホ」を表す既定（縦の画面の描き出し・テスト）: Small・Touch・大きさは view（CSS px）・
    /// 倍率 3・design の 1px は画面の幅 ÷ design の幅・向きは design の形から（縦の design を渡せば Portrait）。
    pub def phonePortrait(view: Vec2.Vec2, design: Vec2.Vec2): Display =
        { size = view, scaleFactor = 3.0, designScale = if (design#x > 0.0) view#x / design#x else 1.0,
          pointer = PointerKind.Touch, sizeClass = SizeClass.Small, orientation = orientationOf(design) }

    /// 区分の決め方。主な pointer が指でなければ Large。指なら、画面の短い辺（論理 px）が 600 未満で Small・それ以上で Medium
    /// （600 は Material の window size class の compact の上限。スマホの短辺は 360〜430、小さいタブレットは 744 から）。
    pub def sizeClassOf(coarsePointer: Bool, shortSide: Float64): SizeClass =
        if (not coarsePointer) SizeClass.Large
        else if (shortSide < 600.0) SizeClass.Small
        else SizeClass.Medium
}
