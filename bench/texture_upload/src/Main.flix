// 毎フレーム作ったアトラスを GPU へ上げる経路（App.withSpriteAtlases → GameEngine.Game.ensureTexture
// → RenderTexture.updateTexturePixels）の費用を測るベンチ。
//
// 区間ごとにやり方を切り替えて、1 回の実行の中で背中合わせのペアを取る:
//   none … 何も上げない（この機械のその時の床）
//   old  … 直す前の書き方をこのベンチに写した物（毎回 direct buffer を取り直して 1 要素ずつ put
//          してから glTexImage2D）
//   new  … いまの RenderTexture.updateTexturePixels（int[] のまま一括で写して glTexSubImage2D）
//
// 1 フレームに 320x240 を 2 枚上げる（material_lab の実際の使い方に合わせた大きさと枚数）。
// 画素の中身は毎フレーム同じ物を使う — 画素を作る費用を測りたいのではなく、GPU へ上げる
// 費用だけを見たいので。
use flix_game_engine::{App, GameEngine, LwjglLayer}

mod BenchTextureUpload {
    use flix_game_engine::{App, GpuHandle, RawDraw, Render, RenderAsset, RenderTexture, RenderUtil}

    import java.lang.System
    import org.lwjgl.glfw.GLFW
    import org.lwjgl.opengl.GL11
    import org.lwjgl.opengl.GL12
    import org.lwjgl.BufferUtils
    import org.lwjgl.system.MemoryUtil

    pub type alias World = {
        t = Float64,
        segment = Int32,
        frameInSegment = Int32,
        frameSamples = List[Float64],
        uploadSamples = List[Float64],
        textures = List[RenderAsset.TextureInfo],
        pixels = Vector[Int32],
        done = Bool
    }

    def texWidth(): Int32 = 320

    def texHeight(): Int32 = 240

    def texCount(): Int32 = 2

    /// 画素はどれでもよいが、0 だらけだとドライバが手を抜けるので中身を散らす。
    def makePixels(): Vector[Int32] =
        Vector.range(0, texWidth() * texHeight()) |> Vector.map(i -> i * 1103515245)

    pub def initialWorld(): World =
        { t = 0.0, segment = 0, frameInSegment = 0, frameSamples = Nil, uploadSamples = Nil,
          textures = Nil, pixels = makePixels(), done = false }

    // ── 区間の台本 ──

    def segments(): List[String] =
        "none" :: "old" :: "bulk" :: "new" ::
        "none" :: "old" :: "bulk" :: "new" ::
        "none" :: "old" :: "bulk" :: "new" ::
        "none" :: "old" :: "bulk" :: "new" :: Nil

    def segmentCount(): Int32 = List.length(segments())

    def modeOf(i: Int32): String =
        segments() |> List.drop(i) |> List.head |> Option.getWithDefault("none")

    def framesPerSegment(): Int32 = 200

    def warmupOf(segment: Int32): Int32 =
        if (segment < 4) 80 else 40

    // ── 上げ方 2 通り ──

    /// 直す前の書き方（このベンチに写した物）。
    def uploadOld(info: RenderAsset.TextureInfo, px: Vector[Int32]): Unit \ IO =
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, GpuHandle.textureIdInt(info#id));
        let buf = BufferUtils.createIntBuffer(Int32.max(1, texWidth() * texHeight()));
        Vector.forEach(p -> discard buf.put(p), px);
        discard buf.flip();
        GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL11.GL_RGBA, texWidth(), texHeight(), 0,
                          GL12.GL_BGRA, GL12.GL_UNSIGNED_INT_8_8_8_8_REV, buf)

    /// 一括で写すところだけ直した中間形（置き場の確保は glTexImage2D のまま）。
    /// 効きが「写し方」と「確保し直し」のどちらから来ているかを分けるための区間。
    def uploadBulk(info: RenderAsset.TextureInfo, px: Vector[Int32]): Unit \ IO =
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, GpuHandle.textureIdInt(info#id));
        let arr = unchecked_cast(px as Array[Int32, Static]);
        let buf = MemoryUtil.memAllocInt(Int32.max(1, texWidth() * texHeight()));
        discard buf.put(arr);
        discard buf.flip();
        GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL11.GL_RGBA, texWidth(), texHeight(), 0,
                          GL12.GL_BGRA, GL12.GL_UNSIGNED_INT_8_8_8_8_REV, buf);
        MemoryUtil.memFree(buf)

    def uploadAll(mode: String, w: World): Unit \ IO =
        match mode {
            case "old"  => List.forEach(t -> uploadOld(t, w#pixels), w#textures)
            case "bulk" => List.forEach(t -> uploadBulk(t, w#pixels), w#textures)
            case "new" => List.forEach(t ->
                RenderTexture.updateTexturePixels(t, texWidth(), texHeight(), w#pixels), w#textures)
            case _     => ()
        }

    def ensureTextures(w: World): World \ IO =
        if (List.isEmpty(w#textures))
            { textures = List.range(0, texCount())
                |> List.map(_ -> RenderTexture.loadTextureFromPixels(
                    texWidth(), texHeight(), w#pixels)) | w }
        else w

    // ── 進行 ──

    pub def step(frame: App.Frame, w0: World): World \ IO =
        if (w0#done) w0
        else {
            let w = ensureTextures(w0);
            if (w#frameInSegment < 4) GLFW.glfwSwapInterval(0) else ();
            let mode = modeOf(w#segment);
            let t0 = System.nanoTime();
            uploadAll(mode, w);
            let t1 = System.nanoTime();
            let counted = w#frameInSegment >= warmupOf(w#segment);
            let uploadMs = Int64.toFloat64(t1 - t0) / 1000000.0;
            let uploads = if (counted) uploadMs :: w#uploadSamples else w#uploadSamples;
            let frames = if (counted) frame#dt * 1000.0 :: w#frameSamples else w#frameSamples;
            let t = w#t + frame#dt;
            if (w#frameInSegment + 1 >= framesPerSegment()) {
                report(w#segment, mode, frames, uploads);
                let next = w#segment + 1;
                { t = t, segment = next, frameInSegment = 0, frameSamples = Nil,
                  uploadSamples = Nil, done = next >= segmentCount() | w }
            } else
                { t = t, frameInSegment = w#frameInSegment + 1,
                  frameSamples = frames, uploadSamples = uploads | w }
        }

    def avgOf(xs: List[Float64]): Float64 =
        match List.length(xs) {
            case 0 => 0.0
            case n => List.foldLeft((acc, x) -> acc + x, 0.0, xs) / Int32.toFloat64(n)
        }

    def pctOf(p: Int32, xs: List[Float64]): Float64 =
        match List.length(xs) {
            case 0 => 0.0
            case n => List.sort(xs)
                |> List.drop(Int32.min(n - 1, n * p / 100))
                |> List.head
                |> Option.getWithDefault(0.0)
        }

    def report(segment: Int32, mode: String, frames: List[Float64], uploads: List[Float64]): Unit \ IO =
        println("seg=${segment} mode=${mode} n=${List.length(frames)}"
            + " frame_avg=${fmt3(avgOf(frames))}ms frame_p50=${fmt3(pctOf(50, frames))}ms"
            + " frame_p99=${fmt3(pctOf(99, frames))}ms"
            + " upload_avg=${fmt3(avgOf(uploads))}ms upload_p99=${fmt3(pctOf(99, uploads))}ms")

    def fmt3(x: Float64): String =
        let milli = RenderUtil.floatToInt32(x * 1000.0);
        let frac = Int32.modulo(milli, 1000);
        let pad = if (frac < 10) "00" else if (frac < 100) "0" else "";
        "${milli / 1000}.${pad}${frac}"

    /// 絵は測る物ではないので最小限。ただし完全に空だとドライバが frame を丸ごと畳めるので、
    /// 動く物を少しだけ置く。
    pub def view(_ctx: App.ViewCtx, w: World): List[Render.PlacedItem] =
        List.range(0, 24) |> List.map(i -> {
            let fi = Int32.toFloat64(i);
            let raw = fi * 13.0 + w#t * 40.0;
            let x = 16.0 + (raw - Float64.floor(raw / 288.0) * 288.0);
            RawDraw.boxAt({ x = x, y = 40.0 + fi * 7.0 }, { x = 12.0, y = 12.0 },
                         { r = 0.6, g = 0.7, b = 0.9 }, 10)
        })
}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else
        run {
            App.make(BenchTextureUpload.initialWorld())
                |> App.addSystem(BenchTextureUpload.step)
                |> App.withView((ctx, w) -> checked_ecast(BenchTextureUpload.view(ctx, w)))
                |> App.quitWhen((_frame, w) -> checked_ecast(w#done))
                |> App.launch
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
          with Fs.Glob.runWithIO
          with Fs.ModificationTime.runWithFileTime
          with Fs.FileTime.runWithIO
