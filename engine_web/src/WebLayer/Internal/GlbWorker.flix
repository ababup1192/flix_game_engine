// WebLayer.Internal.GlbWorker — 後から届く glb を Web Worker で解く道の wasm の側（解く側の輪と、頼む側が結果を引く口）。
// Worker を起こす・頼む・状態を移すのは頁の fge-web.js、Worker の中の JS は fge-glb-worker.js。

/// glb の Worker の道。ゲームからは呼ばない。
// WhyNot: Worker の入口を別の wasm にしない — 書き出しで TeaVM を 2 回流し、配る物も 1 本増える。ゲームの WebMain をそのまま通し、WebLayer の入口で分ける。
pub mod WebLayer.Internal.GlbWorker {
    import fge.web.{GlbWorker => GlbWorkerJs}
    import java.lang.Throwable

    /// この wasm が glb の Worker の中で動いているか。
    pub def isWorker(): Bool \ IO = GlbWorkerJs.isWorker()

    /// Worker の中で、頼みを 1 本ずつ待って解き、結果を頁へ返す（戻らない）。
    pub def serve(): a \ IO =
        GlbWorkerJs.awaitRequest();
        serveOne();
        serve()

    // WhyNot: parse の中で投げた例外を輪の外へ出さない — 輪が止まると、後の glb が全部 30 秒待ってからメインで読み直しになる。
    def serveOne(): Unit \ IO =
        try {
            let bytes: Vector[Int8] = unchecked_cast(GlbWorkerJs.requestBytes() as Vector[Int8]);
            match Gltf.Internal.preparse(GlbWorkerJs.requestGltf(), bytes) {
                case Ok((parts, images)) => send(parts, images)
                case Err(e)              => GlbWorkerJs.fail(e)
            }
        } catch {
            case e: Throwable => GlbWorkerJs.fail("glb の Worker の中で例外: ${e.toString()}")
        }

    def send(parts: LoadProgress.Internal.PreparsedParts, images: List[(Int32, Int32, Int32)]): Unit \ IO =
        put(parts, images);
        GlbWorkerJs.finish()

    /// 並びを JS の結果の入れ物（fgeGlbWorkerResult）へ積む。
    def put(parts: LoadProgress.Internal.PreparsedParts, images: List[(Int32, Int32, Int32)]): Unit \ IO =
        Vector.forEach(s -> GlbWorkerJs.putString(s), parts#strings);
        GlbWorkerJs.putInts(unchecked_cast(parts#ints as Array[Int32, Static]));
        GlbWorkerJs.putFloats(unchecked_cast(parts#floats as Array[Float64, Static]));
        Vector.forEach(v -> GlbWorkerJs.pushF64s(unchecked_cast(v as Array[Float64, Static])), parts#f64s);
        Vector.forEach(v -> GlbWorkerJs.pushI32s(unchecked_cast(v as Array[Int32, Static])), parts#i32s);
        List.forEach(image -> { let (k, start, length) = image; GlbWorkerJs.putImage(k, start, length) }, images)

    /// 頁が後回しの glb を Worker で解く見込みなら、小さな結果を頁の表に置いて preparsedOf と戻す関数を 1 度通しておく（読み込みの間に呼ぶ）。
    pub def warmUp(): Unit \ IO =
        if (not GlbWorkerJs.expected()) ()
        else {
            let key = "fge-glb-warm-up";
            let ok = match Gltf.Internal.warmUpWire() {
                case Ok(wire) =>
                    GlbWorkerJs.beginLocal();
                    put(wire, Nil);
                    GlbWorkerJs.storeLocal(key);
                    let carried = preparsedOf(key) |> Option.map(p -> Gltf.Internal.warmUpCodec(LoadProgress.Internal.partsOf(p))) |> Option.getWithDefault(false);
                    GlbWorkerJs.dropParsed(key);
                    carried
                case Err(_) => false
            };
            if (ok) () else Log.warn("[glb-worker] 結果を戻す道を前もって走らせられなかった（初めて届いた束のコマが重くなる）")
        }

    /// 鍵（道と版）の glb を Worker で解いた結果（LoadProgress.AssetDownloads#preparsedOf）。まだ・無い・解けなかった時は None。
    pub def preparsedOf(key: String): Option[LoadProgress.Preparsed] \ IO =
        if (not GlbWorkerJs.hasParsed(key)) None
        else {
            let text = GlbWorkerJs.text(key);
            let strings = startsOf(intsOf(key, "strLens")) |> Vector.map(span -> String.slice(start = fst(span), end = fst(span) + snd(span), text));
            let f64s = startsOf(intsOf(key, "f64Lens")) |> slicesOf(GlbWorkerJs.floats(key, "f64"));
            let i32s = startsOf(intsOf(key, "i32Lens")) |> slicesOf(GlbWorkerJs.ints(key, "i32"));
            Some(LoadProgress.Internal.makePreparsed({ strings = strings, ints = intsOf(key, "ints"), floats = floatsOf(key, "floats"), f64s = f64s, i32s = i32s }))
        }

    def intsOf(key: String, field: String): Vector[Int32] \ IO = unchecked_cast(GlbWorkerJs.ints(key, field) as Vector[Int32])

    def floatsOf(key: String, field: String): Vector[Float64] \ IO = unchecked_cast(GlbWorkerJs.floats(key, field) as Vector[Float64])

    /// 長さの並びを (始まり, 長さ) の並びにする。
    def startsOf(lengths: Vector[Int32]): Vector[(Int32, Int32)] =
        let (_, spans) = Vector.foldLeft((acc, n) -> { let (at, out) = acc; (at + n, (at, n) :: out) }, (0, Nil), lengths);
        List.toVector(List.reverse(spans))

    /// all を spans で切った配列の並び。
    def slicesOf(all: Array[t, Static], spans: Vector[(Int32, Int32)]): Vector[Vector[t]] \ IO =
        spans |> Vector.map(span -> {
            let (start, length) = span;
            let part = Array.copyOfRange(Static, start, start + length, all);
            let v: Vector[t] = unchecked_cast(part as Vector[t]);
            v
        })
}
