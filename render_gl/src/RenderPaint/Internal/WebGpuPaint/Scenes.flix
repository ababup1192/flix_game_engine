// RenderPaint.Internal.WebGpuPaint.Scenes — 塗りのコア（WebGpuPaint）の 3D の場面の分。2D の pass を開く前に場面を Render3d.WebGpuRenderer に描かせ、
// 2D の並びの z の位置でその texture を貼る。3D の描き手へ貸す encoder・submit・知らせ（Host）もここで組む。
// WhyNot: WebGpuPaint の兄弟の mod にしない — Host は WebGpuPaint の encoder と submit と数えを借りるので、子の mod でなければそれらを pub にすることになる。
pub mod RenderPaint.Internal.WebGpuPaint.Scenes {
    import fge.webgpu.RenderPass
    use RenderFrame.Internal.RenderList
    use RenderFrame.Internal.RenderList.{PassSpec}
    use RenderFrame.Internal.WebGpuRows
    use RenderPaint.Internal.WebGpuPaint.{Paint, PaintData, encoderOf, flushPending, skipMany}
    use RenderPaint.Internal.WebGpuPipelines

    /// 1 回の renderCommands の場面 scenes を、2D の pass を開く前にそれぞれの texture へ描き、貼る物を返す。
    /// stencilKey = mask の stencil を引く描き先の番号・target = 2D の pass の形式と標本・pass = 2D の描き先の指定。
    pub def prepare(paint: Paint, stencilKey: Int32, target: (RenderTarget.Format, Int32), pass: PassSpec,
                    scenes: List[Scene3d.RenderCmd]): Render3d.WebGpuRenderer.Prepared \ IO =
        let PaintData.PaintData(p) = paint;
        let (format, samples) = target;
        (p#scenes3d#prepare)(hostOf(paint),
                             { key = stencilKey, format = format, samples = samples, viewport = viewportOf(paint, pass), height = pass#height },
                             scenes)

    /// 先に上げる物の宣言 cmd（withPreload3d）の形と絵と材質を 3D の描き手に上げさせる（前と同じ key なら何もしない）。
    pub def preload(paint: Paint, cmd: Scene3d.PreloadCmd): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        (p#scenes3d#preload)(hostOf(paint), cmd)

    /// 先に描いた場面 1 つ（prepare の答え）を、場面の矩形の scissor で貼り、その描き先の値を今の encoder の中で使い中と控える
    /// （描く物の無い場面は何もしない）。
    pub def paste(paint: Paint, target: (RenderTarget.Format, Int32), scene: Option[Render3d.WebGpuRenderer.Paste],
                  pass: RenderPass, stencil: Int32): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        let pipes = p#pipes;
        let (format, samples) = target;
        scene |> Option.forEach(found -> {
            (p#scenes3d#notePasted)(found);
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
          skip = (name, n) -> skipMany(paint, name, n),
          textureOf = name -> registeredOf(paint, name),
          textureById = id -> Map.get(id, Ref.get(p#slots)) |> Option.map(slot -> slot#texture),
          groupById = id -> Map.get(id, Ref.get(p#slots)) |> Option.map(slot -> slot#group) }

    /// 3D の材質が名前で読む全体の登録の絵（GL の RenderPaint.registeredTexture と同じ欄。レンダーターゲットは上下逆に読む印）。
    def registeredOf(paint: Paint, name: String): Option[Scene3dRenderer.RegisteredTexture] \ IO =
        let PaintData.PaintData(p) = paint;
        Map.get(name, Ref.get(p#registryRef)) |> Option.map(info ->
            ({ texId = GpuHandle.textureIdInt(info#id), width = info#width, height = info#height,
               flipped = RenderPaint.Internal.TargetTable.isTarget(p#targets, name),
               version = Map.getWithDefault(name, "", Ref.get(p#textureKeyRef)) }: Scene3dRenderer.RegisteredTexture))
}
