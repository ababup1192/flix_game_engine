// Transition — 画面を覆う/晴らす切り替え演出を、進行度 t だけから絵にする道具箱。
// シーンの変え目に単色の覆いを重ねるだけで「唐突に切り替わった」感じを消せる。
// 利用例: フロア移動の前後で FadeOut → FadeIn を挟む / メニュー確定で WipeLeft を出す。
// カメラを使うゲームは HUD 側（withHudView / composeScene の hud）に重ねる — world 側だと覆いがカメラで動く。
// イージングは持たない: 呼び側で t を変形して渡せば効く（例: t*t でゆっくり立ち上がる）。
// 注意: 経過秒を貯める Progress 以外は状態を持たない純関数。UI やカメラは知らない。

pub mod Transition {

    // ── 種類（最初はこの 4 つで足りる）──

    pub enum Kind with Eq {
        case FadeOut,    // だんだん黒く覆っていく（t=0 素通し → t=1 全面黒）
        case FadeIn,     // 覆いがだんだん晴れる（t=0 全面黒 → t=1 素通し）
        case WipeLeft,   // 黒い覆いが右から左へ画面を広がっていく
        case WipeRight   // 黒い覆いが左から右へ画面を広がっていく
    }

    // ── 純関数層: 進行度 t → 画面を覆う描画物 ──

    /// itemsAt へ渡す指定ひとそろい（引数が多いので名前渡しで取り違えを防ぐ）。
    /// t は [0,1] にクランプ、viewport はデザイン解像度、color は覆いの色、
    /// z は重なり順（迷ったら defaultZ()）。
    pub type alias Cover = { kind = Kind, t = Float64, viewport = Vec2.Vec2, color = Color, z = Int32 }

    /// 覆いの既定 zIndex。UI（layer × CanvasLayer.layerStride = 10000 台）より手前、
    /// HUD の範囲（ZBand.hudBase）とデバッグ表示（ZBand.debugBase）より奥 —
    /// 遷移中も fps や注釈は隠れない。
    pub def defaultZ(): Int32 = 100000

    /// 進行度と種類から、画面を覆う描画物の列を返す。
    /// 返る列は 0 個（何も覆わない）か 1 個（覆いの矩形）。
    pub def itemsAt(cover: Cover): List[Render.PlacedItem] =
        let tc = Num.clamp01(cover#t);
        match cover#kind {
            case Kind.FadeOut  => fadeItems(tc, cover#viewport, cover#color, cover#z)
            case Kind.FadeIn   => fadeItems(1.0 - tc, cover#viewport, cover#color, cover#z)
            case Kind.WipeLeft => wipeItems(tc, cover#viewport, cover#color, cover#z, true)
            case Kind.WipeRight => wipeItems(tc, cover#viewport, cover#color, cover#z, false)
        }

    /// 画面全体を覆う矩形の alpha を t にする（t=0 で見えない・t=1 で不透明）。
    def fadeItems(t: Float64, viewport: Vec2.Vec2, color: Color, z: Int32): List[Render.PlacedItem] =
        if (t <= 0.0) Nil
        else {
            let center = Vec2.div(viewport, 2.0);
            (RawDraw.boxAt(center, viewport, color, z) |> withAlpha(t)) :: Nil
        }

    /// 画面幅 t 分だけ覆う（fromRight=true で右端から左へ、false で左端から右へ）。
    def wipeItems(t: Float64, viewport: Vec2.Vec2, color: Color, z: Int32, fromRight: Bool): List[Render.PlacedItem] =
        if (t <= 0.0) Nil
        else {
            let w = viewport#x * t;
            let size = { x = w, y = viewport#y };
            let x = if (fromRight) viewport#x - w else 0.0;
            { at = { x = x, y = 0.0 }, item = RawDraw.box(size, color, z) } :: Nil
        }

    /// PlacedItem に alpha を掛ける（Render.fade は Item 向けなので item だけ通す）。
    def withAlpha(alpha: Float64, placed: Render.PlacedItem): Render.PlacedItem =
        { item = Render.fade(alpha, placed#item) | placed }

    // ── 進行層: 経過秒を貯める小さな値 ──

    /// 遷移の進み具合。所要時間 duration に対して経過秒 elapsed がどれだけ進んだかだけを持つ。
    pub type alias Progress = { elapsed = Float64, duration = Float64 }

    /// 経過 0 から始める。duration が 0 以下だと即座に t=1 になる（一瞬で終わる遷移として扱う）。
    pub def start(duration: Float64): Progress =
        { elapsed = 0.0, duration = duration }

    /// dt を経過に足す（duration を超えても elapsed は伸び続けない。上限で止める）。
    pub def advance(dt: Float64, progress: Progress): Progress =
        { elapsed = Float64.min(progress#duration, progress#elapsed + dt) | progress }

    /// 現在の進行度 t（[0,1]）。duration が 0 以下なら常に 1.0。
    pub def tOf(progress: Progress): Float64 =
        if (progress#duration <= 0.0) 1.0
        else Num.clamp01(progress#elapsed / progress#duration)

    /// 遷移が終わっているか（t が 1.0 に達した）。
    pub def done(progress: Progress): Bool = tOf(progress) >= 1.0
}
