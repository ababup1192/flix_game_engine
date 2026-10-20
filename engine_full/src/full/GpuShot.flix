// GpuShot — 窓なしのゲームの 1 枚撮り（Studio の会話のプレビュー・bin/fge talk shot）を GPU で塗る。
// 塗る道は実機と同じ（App の view → Render.drawWith → render_gl の塗りのコア）で、行き先が窓ではなく
// GlOffscreen の FBO になるだけ。GL の文脈・フォント・テクスチャは最初の 1 枚で用意し、待ち受けの間持ち続ける。
// GPU が使えない所（画面の無い機械・GL を作れない）では、渡された SoftRaster の撮り方に戻る。
// 比べ（reference-check・compare）には使わない —— 人が見る絵だけ GPU で塗る（docs/design/render-speed.md 柱 3）。
//
// ゲームに置く形（src/E2e.flix の窓なしの入口）:
//   let app = Game.app(…);
//   let shot = GpuShot.shotOf(GpuShot.modeOf(ProcessEnv.snapshot()), app, SceneRender.shotWorld, SceneRender.shotOf);
//   App.Headless.serve(App.onShotRequest(shot, app))
pub mod GpuShot {
    import java.awt.image.BufferedImage
    import java.awt.image.RenderedImage
    import java.util.{List => JList}
    import javax.imageio.metadata.IIOMetadata
    import java.io.File
    import java.lang.ProcessHandle
    import java.lang.Throwable
    import javax.imageio.IIOImage
    import javax.imageio.ImageIO
    import javax.imageio.ImageWriteParam
    import javax.imageio.stream.FileImageOutputStream

    /// 塗る物の選び方（環境変数 FGE_GPU）。Auto = GPU を試し、駄目なら SoftRaster（1 行知らせる）・
    /// On = GPU だけ（駄目ならその旨を返す）・Off = いつも SoftRaster。
    pub enum Mode with Eq, ToString {
        case Auto
        case On
        case Off
    }

    /// 環境変数の表から（入口の頭で読んだ表を渡す）。知らない値は Auto。
    pub def modeOf(env: Map[String, String]): Mode = match Map.get("FGE_GPU", env) {
        case Some("off") => Mode.Off
        case Some("on")  => Mode.On
        case _           => Mode.Auto
    }

    /// GL の用意の今。
    enum State {
        case NotYet
        case Ready(GlOffscreen.Session, App.TileCache)
        case Unavailable(String)
    }

    /// App.onShotRequest に渡す撮り方を作る。prepare = 撮る前に World を整える（時計を描き出しの時刻へ置くなど。
    /// SoftRaster の撮り方と同じ物を渡す）、soft = GPU が使えない時の撮り方。返す関数は PNG のパスを返す。
    /// GL は 1 本の糸で: 返す関数は、窓なしのゲームの答える糸（いつも同じ糸）からだけ呼ぶ。入口の頭（AWT を使う前）で作る。
    pub def shotOf(mode: Mode, app: App.App[w, ef], prepare: w -> w, soft: w -> String \ IO):
            (w -> String \ (ef - GameEngine.Game - ShaderEffect.Shader - RenderTarget.Target) + IO) \ IO =
        // AWT（SoftRaster の撮り方・常駐の /run）より先に窓サーバへ繋いでおく（GlOffscreen.connect の doc）。
        if (mode == Mode.Off) () else GlOffscreen.connect();
        let state = Ref.fresh(Static, (State.NotYet: State));
        let scale = 2;
        world -> {
            if (mode == Mode.Off) soft(world)
            else {
                let ready = match Ref.get(state) {
                    case State.NotYet =>
                        let opened = openSession(scale);
                        let next = match opened {
                            case Ok(session) => State.Ready(session, App.freshTileCache())
                            case Err(why)    =>
                                println("[shot] GPU が使えない: ${why} — SoftRaster で塗る");
                                State.Unavailable(why)
                        };
                        Ref.put(next, state);
                        next
                    case other => other
                };
                match ready {
                    case State.Ready(session, cache) =>
                        // 描き直した PNG が次の 1 枚にすぐ出るように、撮る前に絵のファイルを見直す。
                        Option.forEach(manifest -> discard GlOffscreen.refreshTextures(session, manifest), textureManifest());
                        let next = GlOffscreen.handle(session, () -> App.paintOnce(app, prepare(world), cache));
                        Ref.put(State.Ready(session, next), state);
                        writeFastPng(GlOffscreen.readImage(session), shotPath())
                    case _ if mode == Mode.On => bug!("FGE_GPU=on だが GPU が使えない")
                    case _ => soft(world)
                }
            }
        }

    def openSession(scale: Int32): Result[String, GlOffscreen.Session] \ IO =
        match (run { ProjectLoader.loadProject(".") } with Fs.FileRead.runWithIO) {
            case Err(why)   => Err("project.json を読めない: ${why}")
            case Ok(loaded) => GlOffscreen.open({ config = loaded#config, scale = scale })
        }

    /// 今の project.json の textures（読めなければ None = 見直さない）。
    def textureManifest(): Option[List[GameEngine.TextureEntry]] \ IO =
        (run { ProjectLoader.loadProject(".") } with Fs.FileRead.runWithIO)
            |> Result.toOption |> Option.map(loaded -> loaded#config#textureManifest)

    /// SoftRaster の撮り方と同じ置き場（debug/shot/shot-<pid>.png）。
    def shotPath(): String \ IO =
        discard (new File("debug/shot")).mkdirs();
        "debug/shot/shot-${Int64.toString(ProcessHandle.current().pid())}.png"

    /// 圧縮を軽くして PNG に書く（既定の強さだと 960×600 で数十ミリ秒かかり、1 枚の予算に入らない）。
    def writeFastPng(image: BufferedImage, path: String): String \ IO =
        let writer = ImageIO.getImageWritersByFormatName("png").next();
        let param = writer.getDefaultWriteParam();
        try {
            param.setCompressionMode(ImageWriteParam.MODE_EXPLICIT);
            param.setCompressionQuality(1.0f32)
        } catch {
            case _: Throwable => ()
        };
        let file = new File(path);
        discard file.delete();
        let out = new FileImageOutputStream(file);
        writer.setOutput(out);
        let rendered: RenderedImage = checked_cast(image);
        let noThumbnails: JList[BufferedImage] = checked_cast(null);
        let noMetadata: IIOMetadata = checked_cast(null);
        writer.write(noMetadata, new IIOImage(rendered, noThumbnails, noMetadata), param);
        out.close();
        writer.dispose();
        path
}
