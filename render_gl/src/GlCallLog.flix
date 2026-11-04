// GlCallLog — デスクトップの描き手（LwjglLayer・GlOffscreen）が GL の値（GlContext の LWJGL 版）を作る所。
// 環境変数 FLIX_GE_GL_LOG=<ファイル> がある時だけ、呼び出しを 1 行ずつ控える版（RecordingGl）で包み、画面のコマを出すたびに
// 控えをファイルへ足す（描く手順を替える前と後で、呼び出しの並びを比べる用。控える間は起動画面を描かない — RenderSplash.disabled）。控えるのは起動の分と、頭の FLIX_GE_GL_LOG_FRAMES コマ（既定 6）。
mod GlCallLog {
    import fge.gl.GlContext
    import fge.gl.LwjglGl
    import fge.gl.RecordingGl
    import java.io.FileWriter
    import java.lang.System

    /// 作った GL の値と、画面のコマを出し終えた時に呼ぶ関数（控えていなければ何もしない）。
    pub type alias Opened = { gl = GlContext, onScreenFrame = Unit -> Unit \ IO }

    /// GL の値を 1 つ作る。GL の文脈は要らない（呼ぶのは文脈が付いてから）。
    pub def open(): Opened \ IO =
        let lwjgl = plain();
        match pathOf() {
            case None       => { gl = lwjgl, onScreenFrame = () -> checked_ecast(()) }
            case Some(path) => recording(lwjgl, path, framesOf())
        }

    /// 控えない LWJGL 版（1 回きりの塗りの口が自分で作る時）。
    pub def plain(): GlContext \ IO = checked_cast(new LwjglGl())

    def recording(inner: GlContext, path: String, frames: Int32): Opened \ IO =
        let recorder = new RecordingGl(inner);
        writeText(path, "", false);
        let count = Ref.fresh(Static, 0);
        let onScreenFrame = () -> {
            let n = Ref.get(count);
            if (n >= frames) ()
            else {
                writeText(path, recorder.drainLog(), true);
                Ref.put(n + 1, count);
                if (n + 1 >= frames) recorder.setEnabled(false) else recorder.markFrame(n + 1)
            }
        };
        println("[lwjgl] FLIX_GE_GL_LOG: GL の呼び出しを ${path} へ控える（起動と頭の ${frames} コマ）");
        { gl = checked_cast(recorder), onScreenFrame = onScreenFrame }

    def pathOf(): Option[String] \ IO =
        let v = System.getenv("FLIX_GE_GL_LOG");
        if (Object.isNull(v) or String.isEmpty(v)) None else Some(v)

    def framesOf(): Int32 \ IO =
        let v = System.getenv("FLIX_GE_GL_LOG_FRAMES");
        if (Object.isNull(v)) 6 else Int32.fromString(v) |> Option.getWithDefault(6) |> Int32.max(1)

    def writeText(path: String, text: String, append: Bool): Unit \ IO =
        let writer = new FileWriter(path, append);
        writer.write(text);
        writer.close()
}
