// ブラウザ版の入口（bin/fge export-web だけが組む）。
// URL の query に scene があれば測る（?scene=room か ?scene=field&n=12000&shapes=16&mats=16&moving=100&alpha=10&shadow=1。?scene=room&psx=full で PS1 風の部屋。結果は頁の上に残す）。
// 無ければ部屋を描き続けるだけ（頁の旗 capture:<n> で絵を撮る道）。
// WhyNot: 撮る道でも測らない — 診断を付けると撮る絵の道が実機の既定と変わる。
mod WebMain {
    use fge::{App, Gltf, ImageData, LoadProgress, Mesh3d, Model3d, Platform, WebFs, WebLayer}

    import fge.web.AssetTable
    import fge.web.Browser
    import fge.web.GlbWorker

    def loadScene(knobs: Map[String, String]): Result[String, SceneBench.Scene] \ Fs.FileRead + LoadProgress + IO =
        if (First.modeOf(knobs) == Some(First.Mode.Glb)) Ok(SceneBench.Scene.First(First.kitOf(First.Mode.Glb, knobs, None) |> First.withGlb(glbJob(knobs))))
        else if (First.modeOf(knobs) == Some(First.Mode.Group) or First.modeOf(knobs) == Some(First.Mode.Preload) or First.modeOf(knobs) == Some(First.Mode.Auto))
            Ok(SceneBench.Scene.First(First.kitOf(First.modeOf(knobs) |> Option.getWithDefault(First.Mode.Group), knobs, None)))
        else if (SceneBench.isField(knobs)) Ok(SceneBench.Scene.Field(Field.kitOf(Field.configOf(knobs))))
        else match Map.get("psx", knobs) {
            case Some(look) => Room.loadMeshes() |> Result.map(meshes -> SceneBench.Scene.PsxRoom(PsxRoom.kitOf(Room.kitOf(meshes)), look))
            case None       => Room.loadMeshes() |> Result.map(meshes -> SceneBench.Scene.Room(Room.kitOf(meshes)))
        }

    /// assets/<glb>（既定 props_a.glb・props_b.glb と合わせてテンプレートの 1 階の小物の束）を解く仕事（keyed=1 なら鍵つきの読み方）。かかった ms を返す。
    /// warm=1 なら読み込みの時に assets/entrance.glb を 1 回解いておく（ゲームが起動の束を先に解いた後の、wasm のコードが温まった状態で測る）。
    /// deferred=1 なら assets/deferred/<glb>（project.json の web.deferred）を、ゲームと同じく届いたバイトを 120 コマ目に読んで Model3d.decode で解く
    /// （頁は glb を Web Worker で解いてから届いたと言うので、頁の旗 deferred:all で全部届くまで main を待たせて測る。?fge=noworker でメインで解く道と比べる）。
    def glbJob(knobs: Map[String, String]): (Unit -> (Float64, Option[Model3d.Model3d]) \ IO) \ (Fs.FileRead + LoadProgress + IO) =
        if (Map.get("deferred", knobs) == Some("1")) deferredGlbJob(knobs) else localGlbJob(knobs)

    def deferredGlbJob(knobs: Map[String, String]): (Unit -> (Float64, Option[Model3d.Model3d]) \ IO) \ (Fs.FileRead + LoadProgress + IO) =
        let path = "assets/deferred/" + (Map.get("glb", knobs) |> Option.getWithDefault("props_a.glb"));
        let loader = Model3d.loader();
        let decoder = LoadProgress.imageDecoder();
        warmUp(knobs, decoder);
        () -> {
            let key = (decoder#versionedKey)(path) |> Option.getWithDefault(path);
            let carried = GlbWorker.hasParsed(key);
            let began = Browser.now();
            let raw = AssetTable.bytes(path);
            let bytes: Vector[Int8] = if (Object.isNull(raw)) Vector.empty() else unchecked_cast(raw as Vector[Int8]);
            let model = Model3d.decode(loader, path, bytes);
            let ms = Browser.now() - began;
            if (carried and Map.get("phases", knobs) == Some("1")) phases(decoder, key, path) else ();
            println("[scene3d] glb deferred（${if (carried) "Worker で解いた物を組む" else "メインで解く"}）: ${ms} ms・絵 ${model |> Result.map(m -> List.length(m#textures)) |> Result.getWithDefault(-1)} 枚");
            (ms, Result.toOption(model))
        }

    /// つまみ phases=1 の時、2 回目（コードが温まった後）の内訳: 読む・Worker の結果を写す・戻す・組む と、戻す中のつなぐ形（concat）の ms を [bench] の行（区間 phases）に出す。
    // WhyNot: 時刻を素の let で並べて取らない — Flix は純粋な式（deserialize など）を時刻を取る IO の前後へ動かせるので、前の結果を条件に入れて順を止める。
    def phases(decoder: ImageData.ImageDecoder, key: String, path: String): Unit \ IO =
        let began = Browser.now();
        let raw = AssetTable.bytes(path);
        let bytes: Vector[Int8] = if (Object.isNull(raw)) Vector.empty() else unchecked_cast(raw as Vector[Int8]);
        let tRead = if (Vector.length(bytes) >= 0) Browser.now() else 0.0;
        let pre = WebLayer.Internal.GlbWorker.preparsedOf(key);
        let tCopy = if (Option.nonEmpty(pre)) Browser.now() else Browser.now();
        let parsed = pre |> Option.map(p -> Gltf.Internal.Codec.deserialize(LoadProgress.Internal.partsOf(p)));
        let tDeser = if (Option.exists(Result.isOk, parsed)) Browser.now() else Browser.now();
        let assembled = parsed |> Option.flatMap(Result.toOption) |> Option.map(p -> Gltf.Internal.assemble(decoder, { vertexColors = true | Gltf.defaultLoadOptions() }, Some(key), bytes, p));
        let tAsm = if (Option.nonEmpty(assembled)) Browser.now() else Browser.now();
        let arrays = parsed |> Option.flatMap(Result.toOption) |> Option.map(p -> List.map(part -> Mesh3d.Internal.trustedPartsOf(part#givenTangents, part#mesh), p#parts)) |> Option.getWithDefault(Nil);
        let tArr = if (List.length(arrays) >= 0) Browser.now() else 0.0;
        let joined = Mesh3d.Internal.concatTrusted(false, arrays);
        let tCat = if (Mesh3d.vertexCount(joined) >= 0) Browser.now() else 0.0;
        Browser.log("[bench] result {\"section\":\"phases\",\"read\":${tRead - began},\"copy\":${tCopy - tRead},\"deser\":${tDeser - tCopy},\"assemble\":${tAsm - tDeser},\"concat\":${tCat - tArr}}")

    /// warm=1 なら assets/entrance.glb を 1 回解いておく。
    def warmUp(knobs: Map[String, String], decoder: ImageData.ImageDecoder): Unit \ (Fs.FileRead + IO) =
        if (Map.get("warm", knobs) == Some("1")) {
            let warmPath = "assets/entrance.glb";
            let warm = Fs.FileRead.readBytes(warmPath) |> Result.getWithDefault(Vector.empty());
            let began = Browser.now();
            let warmed = Gltf.decodeWith(decoder, { vertexColors = true | Gltf.defaultLoadOptions() }, Some((decoder#versionedKey)(warmPath) |> Option.getWithDefault(warmPath)), warm);
            println("[scene3d] warm entrance.glb: ${Browser.now() - began} ms・読めた ${Result.isOk(warmed)}")
        } else ()

    def localGlbJob(knobs: Map[String, String]): (Unit -> (Float64, Option[Model3d.Model3d]) \ IO) \ (Fs.FileRead + LoadProgress + IO) =
        let path = "assets/" + (Map.get("glb", knobs) |> Option.getWithDefault("props_a.glb"));
        let bytes = Fs.FileRead.readBytes(path) |> Result.getWithDefault(Vector.empty());
        let decoder = LoadProgress.imageDecoder();
        let keyed = Map.get("keyed", knobs) == Some("1");
        let options = { vertexColors = true | Gltf.defaultLoadOptions() };
        warmUp(knobs, decoder);
        () -> {
            let began = Browser.now();
            let key = if (keyed) Some((decoder#versionedKey)(path) |> Option.getWithDefault(path)) else None;
            let model = Gltf.decodeWith(decoder, options, key, bytes);
            let ms = Browser.now() - began;
            println("[scene3d] glb ${if (keyed) "keyed" else "plain"}: ${ms} ms・絵 ${model |> Result.map(m -> List.length(m#textures)) |> Result.getWithDefault(-1)} 枚");
            (ms, Result.toOption(model))
        }

    def measure(knobs: Map[String, String]): Unit \ (IO + Fs.FileRead + Fs.FileWrite + Platform.Services + LoadProgress) =
        match loadScene(knobs) {
            case Err(why)  => println("[scene3d] 家具を読めない: ${why}")
            case Ok(scene) =>
                SceneBench.app(SceneBench.planOf(knobs), line -> Browser.log(line), scene)
                    |> SceneBench.withPost(SceneBench.postOf(knobs))
                    |> App.quitWhen((_frame, _w) -> checked_ecast(false))
                    |> App.launchForBench
        }

    /// psx = query の psx（PsxRoom.lookOf の字。無ければ今までの部屋）。
    def show(psx: Option[String]): Unit \ (IO + Fs.FileRead + Fs.FileWrite + Platform.Services + LoadProgress) =
        match Room.loadMeshes() {
            case Err(why)   => println("[scene3d] 家具を読めない: ${why}")
            case Ok(meshes) =>
                let kit = Room.kitOf(meshes);
                let psxKit = PsxRoom.kitOf(kit);
                let items = (t: Float64) -> match psx {
                    case Some(look) => PsxRoom.items(psxKit, PsxRoom.lookOf(look), SceneBench.yawAt(t))
                    case None       => Room.items(kit, SceneBench.yawAt(t))
                };
                App.make(0.0)
                    |> App.addSystem((frame, t) -> t + frame#dt)
                    |> App.withView((_ctx, t) -> items(t))
                    |> App.launchWithDevTools(App.DevTools.none())
        }

    pub def main(): Unit \ IO =
        let knobs = BenchRun.knobsOfPairs(Array.toList(Browser.queryPairs()));
        run {
            if (Map.memberOf("scene", knobs) or Map.memberOf("first", knobs)) measure(knobs) else show(Map.get("psx", knobs))
        } with WebLayer.withProject3d(".")
          with WebFs.runFileRead
          with WebFs.runFileWrite
}
