// RenderPaint.Internal.WebGpuPaint.Scenes — 塗りのコア（WebGpuPaint）の 3D の場面の分。2D の pass を開く前に場面を Render3d.WebGpuRenderer に描かせ、
// 2D の並びの z の位置でその texture を貼る。3D の描き手へ貸す encoder・submit・知らせ（Host）もここで組む。
// WhyNot: WebGpuPaint の兄弟の mod にしない — Host は WebGpuPaint の encoder と submit と数えを借りるので、子の mod でなければそれらを pub にすることになる。
pub mod RenderPaint.Internal.WebGpuPaint.Scenes {
    import fge.webgpu.RenderPass
    use RenderFrame.Internal.RenderList
    use RenderFrame.Internal.RenderList.{PassSpec}
    use RenderFrame.Internal.WebGpuRows
    use RenderPaint.Internal.WebGpuPaint.{Paint, PaintData, encoderOf, flushPending, skip, skipMany}
    use RenderPaint.Internal.WebGpuPipelines

    /// 1 回の renderCommands の場面 scenes を、2D の pass を開く前にそれぞれの texture へ描き、貼る物を返す。
    /// stencilKey = mask の stencil を引く描き先の番号・target = 2D の pass の形式と標本・pass = 2D の描き先の指定。
    pub def prepare(paint: Paint, stencilKey: Int32, target: (RenderTarget.Format, Int32), pass: PassSpec,
                    scenes: List[Scene3d.RenderCmd]): Render3d.WebGpuRenderer.Prepared \ IO =
        let PaintData.PaintData(p) = paint;
        let (format, samples) = target;
        let prepared = Render3d.WebGpuRenderer.prepare(p#scenes3d, hostOf(paint),
                                                       { key = stencilKey, format = format, samples = samples, viewport = viewportOf(paint, pass), height = pass#height },
                                                       scenes);
        // WhyNot: 診断の 3D の数を黙って 0 で出さない — bench の JSON で「描いた物が 0」と読み違える（数えるのは P8）。
        if (List.isEmpty(scenes) or Option.isEmpty(Ref.get(p#diagnosticsRef))) ()
        else skip(paint, "3D の診断の数（scene3dCounts は未計測で 0）");
        prepared

    /// 先に描いた場面 1 つ（prepare の答え）を、場面の矩形の scissor で貼り、その描き先の値を今の encoder の中で使い中と控える
    /// （描く物の無い場面は何もしない）。
    pub def paste(paint: Paint, target: (RenderTarget.Format, Int32), scene: Option[Render3d.WebGpuRenderer.Paste],
                  pass: RenderPass, stencil: Int32): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        let pipes = p#pipes;
        let (format, samples) = target;
        scene |> Option.forEach(found -> {
            Render3d.WebGpuRenderer.notePasted(p#scenes3d, found);
            let (x, y, w, h) = found#scissor;
            pass.setPipeline(WebGpuPipelines.pipelineOf(pipes, WebGpuRows.shapeScene(), WebGpuRows.blendScene(), format, samples, stencil));
            pass.setBindGroup(1, found#group);
            pass.setScissorRect(x, y, w, h);
            pass.draw(3, 1, 0, 0)
        })

    /// 場面の矩形を描き先の画素へ写すための design 領域（GL の左下が原点）と倍率（GL の RenderPaint が Scene3dRenderer.Prepared#draw に渡す物と同じ）。
    def viewportOf(paint: Paint, pass: PassSpec): Scene3dRenderer.Viewport =
        let PaintData.PaintData(p) = paint;
        let (x, y, w, h) = RenderList.glViewportOf(pass);
        { x = x, y = y, width = w, height = h, scaleX = Int32.toFloat64(w) / p#designW, scaleY = Int32.toFloat64(h) / p#designH }

    /// 3D の描き手へ貸す encoder・submit・知らせ。
    def hostOf(paint: Paint): Render3d.WebGpuRenderer.Host =
        let PaintData.PaintData(p) = paint;
        { encoder = () -> encoderOf(paint),
          notePass = () -> Array.put(Array.get(0, p#frameCounters) + 1, 0, p#frameCounters),
          flush = () -> flushPending(paint),
          skip = (name, n) -> skipMany(paint, name, n) }
}
