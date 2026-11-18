// Res — 描く元の束: Doc（地図・小物・見た目・歩きの手触り・キー）と、Doc から作る物（組んだ町・動かない板・通れるマスの格子・カメラのレンズ）。
// 読むだけで、Doc の読み直しの時だけ替わる。遊びの状態は World が持ち、App の w は Resources.With[Res, World] の組（Game.app）。
// Res は World を使わない（使う向きは World → Res だけ）。
// 絵（PNG）は起動の時に 1 回だけ読み（load）、Doc を読み直す時は読んだ絵から組み直す（build）。
mod Res {
    use fge::{ImageData, Mesh3d, Texture3d}
    use TownDecor.{Decor}
    use TownMap.{TownMap}

    /// 起動と描き出しが同じ形で読む Doc の束。decor = 小物の Doc のパス → 小物の列（decorPaths の順に描く）。
    pub type alias Docs = { map = TownMap, decor = Map[String, List[Decor]], look = TownLook.Look, explore = ExploreDoc.Doc, keys = KeysDoc.Doc }

    /// 描く元の束。
    /// docs = Doc の束・knobs = 描き方の重さのつまみ（Doc を読み直しても残す）・quality = Doc の重さにつまみを掛けた物・
    /// boards = 板を作る道具（読み込んだ絵・引き方・足元の影の形と材質）・built = 組んだ町・grid = 通れるマスの格子・
    /// lens = カメラのレンズ・groundZ = 立ち始めの床の高さ・eyeRise = 引き 1 の時の目の、立ち始めの床からの高さ・
    /// feetDepth = 足元が画面の feetV に来る奥行き・contact = 足元の影の絵（組み直しで使い回す）。
    pub type alias Res = { docs = Docs, knobs = Knobs.Knobs, quality = ExploreDoc.Quality, boards = TownScene.Boards, built = TownScene.Built,
                           grid = CollisionGrid.Grid, lens = TownCamera.Lens, groundZ = Float64,
                           eyeRise = Float64, feetDepth = Float64, contact = Texture3d.Texture3d }

    pub def mapPath(): String = "assets/town.map.json"

    /// 小物の Doc のパス（店と人・動物と馬車）。
    pub def decorPaths(): List[String] = "assets/market.decor.json" :: "assets/animals.decor.json" :: Nil

    /// Doc の束を読む。地図と小物は無いと町が組めないので読めなければ Err・見た目と手触りとキーは既定値で続ける。
    def loadDocs(): Result[String, Docs] \ Fs.FileRead =
        forM (
            m <- TownMap.load(mapPath());
            decor <- decorPaths() |> Result.traverse(p -> TownDecor.load(p) |> Result.map(ds -> (p, ds)))
        ) yield { map = m, decor = List.toMap(decor), look = TownLook.load(TownLook.path()),
                  explore = ExploreDoc.load(ExploreDoc.path()), keys = KeysDoc.load(KeysDoc.path()) }

    /// 起動の Doc の束（地図か小物が読めなければ止める: 起動時の必須入力）。
    pub def loadDocsOrBug(): Docs \ Fs.FileRead = match loadDocs() {
        case Ok(docs) => docs
        case Err(why) => bug!("[hd2d] 町の Doc を読めない: ${why}")
    }

    /// 小物を decorPaths の順に並べた列。
    pub def decorOf(docs: Docs): List[Decor] =
        decorPaths() |> List.flatMap(p -> Map.get(p, docs#decor) |> Option.getWithDefault(Nil))

    /// 読み込む絵のパス（地図のタイル・地図の板・小物・隊列のストリップ）。
    pub def picturePathsOf(docs: Docs): List[String] =
        let strips = ExploreDoc.rec(docs#explore)#party |> List.flatMap(w -> w#strip :: w#idleStrip :: Nil);
        TownScene.picturePaths(decorOf(docs), strips)

    /// 絵を読んで描く元を組む。readImage = 絵を画素にする関数（assets からの相対のパス → 画素）・names = 板の絵の引き方。
    pub def load(readImage: String -> Result[String, ImageData.ImageData] \ ef, names: TownScene.TextureNames, knobs: Knobs.Knobs,
                 docs: Docs): Result[String, Res] \ ef =
        forM (
            pictures <- picturePathsOf(docs) |> Result.traverse(p -> readImage(p) |> Result.flatMap(Images.loadedOf(p)));
            contact <- Images.contactShadow();
            contactMesh <- TownScene.unitContactMesh()
        ) yield build(docs, knobs, pictures |> List.map(l -> (l#path, l)) |> List.toMap, names, contact, contactMesh)

    /// 窓を開かない入口（描き出し・flow・テスト）の描く元。Doc と絵を javax.imageio で読み、読めなければ止める。
    pub def loadOrBugIo(knobs: Knobs.Knobs): Res \ IO =
        run { loadOrBug(Images.readImageIo, TownScene.TextureNames.SceneTextures, knobs, loadDocsOrBug()) } with Fs.FileRead.runWithIO

    /// 起動の描き手の描く元（読めなければ止める: 起動時に絵の実体が読めない）。
    pub def loadOrBug(readImage: String -> Result[String, ImageData.ImageData] \ ef, names: TownScene.TextureNames, knobs: Knobs.Knobs,
                      docs: Docs): Res \ ef = match load(readImage, names, knobs, docs) {
        case Ok(res)  => res
        case Err(why) => bug!("[hd2d] 町を組めない: ${why}")
    }

    /// Doc の束と読み込んだ絵 pictures から組む。
    def build(docs: Docs, knobs: Knobs.Knobs, pictures: TownScene.Pictures, names: TownScene.TextureNames, contact: Texture3d.Texture3d,
              contactMesh: Mesh3d.Mesh3d): Res =
        let e = ExploreDoc.rec(docs#explore);
        let look = TownLook.rec(docs#look);
        let boards = TownScene.boardsOf(pictures, names, docs#look, contact, contactMesh);
        let m = docs#map;
        let lens = TownCamera.lensOf(look#topDeg, look#bottomDeg);
        let groundZ = TownMap.topAt(m, e#startCol, e#startRow);
        let eyeRise = TownCamera.frameHeight(lens, e#frameWidth, e#frameV, e#frameTargetZ) - groundZ;
        let feetDepth = TownCamera.snapToTexel(eyeRise / TownCamera.tanAt(lens, e#feetV));
        let decor = decorOf(docs);
        let decorWidth = (d: Decor) -> Map.get(d#sprite, boards#pictures)
            |> Option.map(l -> Int32.toFloat64(l#width / Int32.max(1, d#frames)) / Images.texelsPerMeter()) |> Option.getWithDefault(1.0);
        let hide = { slope = TownCamera.tanAt(lens, e#feetV), seenHeight = e#seenHeight, reach = e#hideReach,
                     halfWidth = halfWidthOf(boards, e#party), sideDrift = e#aheadMeters / Float64.max(1.0, feetDepth * e#walkZoom) };
        { docs = docs, knobs = knobs, quality = ExploreDoc.qualityWith(knobs, e#quality), boards = boards,
          built = TownScene.build(boards, contact, m), grid = CollisionGrid.build(m, decor, decorWidth, Some(hide)),
          lens = lens, groundZ = groundZ, eyeRise = eyeRise, feetDepth = feetDepth, contact = contact }

    /// 隊列の歩きの絵の 1 コマの横幅の半分（m・一番広い人）。
    def halfWidthOf(boards: TownScene.Boards, party: List[Walkers.Walker]): Float64 =
        party |> List.filterMap(w -> Map.get(w#strip, boards#pictures) |> Option.map(l -> Walkers.walkWidthOf(l, w#dirs) / 2.0))
            |> List.foldLeft(Float64.max, 0.0)

    /// Doc の束を docs に替えて組み直す（絵は読み直さない）。
    pub def withDocs(docs: Docs, res: Res): Res = build(docs, res#knobs, res#boards#pictures, res#boards#names, res#contact, res#boards#contactMesh)

    /// キーの割り当てを keys に替える（町と格子はそのまま）。
    pub def withKeys(keys: KeysDoc.Doc, res: Res): Res = { docs = { keys = keys | res#docs } | res }

    /// 歩きの手触りの Doc。
    pub def exploreOf(res: Res): ExploreDoc.Rec = ExploreDoc.rec(res#docs#explore)

    /// 見た目の Doc。
    pub def lookOf(res: Res): TownLook.Rec = TownLook.rec(res#docs#look)

    /// 地図。
    pub def mapOf(res: Res): TownMap = res#docs#map
}
