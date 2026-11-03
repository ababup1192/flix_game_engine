// WhyNot: 2D の描き手に 3D の描き手の名前を書かせない — 3D を持たない入口（ブラウザ）から 3D の GL の呼び出しへ静的に届かせないため。
mod Scene3dRenderer {

    /// 3D の場面を描くインターフェース。1 コマの使い方: 溜めた場面を 2D の並びを描き始める前に prepare へ渡す（Design の解像度の場面と
    /// 影の地図はここで描き終える）。返った Prepared を 2D の z の並びへ番号で混ぜ、その位置で draw(vp, 番号) を呼ぶ。
    /// 画面のコマを描き終えたら endFrame を 1 回。
    /// prepare の引数 = (画面のコマの世代, 2D の絵の登録を名前で引く関数, 描き終えた後に戻す描き先, 積んだ順の場面)。
    /// endFrame の引数 = 世代。takeCounts = 前に呼んでからの 3D の数を返して 0 に戻す。
    /// readsTexture(name, scenes) = 場面のどれかのビルボードが name の絵を貼るか（材質の Tex は数えない。Pass が自分の前のコマの写しを読むかを決める）。
    /// 置き場と世代を持つので、1 つの値は 1 つの RenderPaint にだけ渡す（Render3d.makeRenderer を RenderPaint ごとに呼ぶ）。
    pub type alias Renderer = {
        prepare = (Int64, String -> Option[RegisteredTexture] \ IO, Dest, List[Scene3d.RenderCmd]) -> Prepared \ IO,
        endFrame = Int64 -> Unit \ IO,
        takeCounts = Unit -> FrameDiagnostics.Scene3dCounts \ IO,
        readsTexture = (String, List[Scene3d.RenderCmd]) -> Bool
    }

    /// そのコマ（か Pass）に準備した場面の並び。zIndexes の i 番目 = 番号 i の場面の z。
    /// draw(vp, i) = 番号 i の場面を 2D の並びの中で描く。描き終えたら viewport を vp へ、scissor を切り、blend を Normal へ戻す。
    pub type alias Prepared = { zIndexes = Vector[Int32], draw = (Viewport, Int32) -> Unit \ IO }

    /// 描き先の中の design 領域（GL の左下原点の画素）と、design px → 画素の倍率。
    pub type alias Viewport = { x = Int32, y = Int32, width = Int32, height = Int32, scaleX = Float64, scaleY = Float64 }

    /// 3D の場面を描く描き先。framebuffer = 描き終えた後に戻す FBO（今開いているレンダーターゲットの描く FBO か画面）・
    /// format = その形式・samples = その標本の数（1 なら MSAA なし）。
    pub type alias Dest = { framebuffer = Int32, format = RenderTarget.Format, samples = Int32 }

    /// 2D の絵の登録にある絵（ビルボードと 3D の材質が貼る）。flipped = レンダーターゲット（行 0 が下）で、v を上下反転して読む。
    /// version = 中身の版（実行中に画素を差し替えた絵は字が変わる。3D の材質が mip を作り直す合図）。
    pub type alias RegisteredTexture = { texId = Int32, width = Float64, height = Float64, flipped = Bool, version = String }

    /// 何も描かない描き手。積んだ場面は捨てる。
    pub def none(): Renderer =
        { prepare = (_, _, _, _) -> checked_ecast(noScenes()),
          endFrame = _ -> checked_ecast(()),
          takeCounts = () -> checked_ecast(FrameDiagnostics.emptyScene3dCounts()),
          readsTexture = (_, _) -> false }

    /// 場面の無い並び。
    pub def noScenes(): Prepared = { zIndexes = Vector.empty(), draw = (_, _) -> checked_ecast(()) }
}
