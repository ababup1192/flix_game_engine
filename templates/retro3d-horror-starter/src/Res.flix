// Res — 描く元の束: Doc（歩き・キー・光）と配置の表（Layout）、読み込んだ形と絵、そこから組んだ校舎（School）。
// 読むだけで、Doc の読み直しの時だけ替わる。遊びの状態は World が持ち、App の w は Resources.With[Res, World] の組。
// Res は World を使わない（使う向きは World → Res だけ。lint/rules.flix の module-cycle）。
mod Res {
    use fge::{BackgroundLoad, LoadProgress, Log, Model3d, Texture3d, Yarn}
    use Textures.Surface

    /// 起動と描き出しが同じ形で読む物の束（Controls.loadDocs）。
    /// cast = 人物の置き場所と話し方・people = 人物の形（model の名前 → 骨つきの glb）・dialogue = 会話の台詞（assets/talk/dialogue.json）。
    /// bundles = 校舎の束の表・pending = まだ解いていない束と人物の鍵（ブラウザ版の後回し。デスクトップは全部 Loaded）・
    /// group と downloads = 残りの鍵をループの中で解く口（App.withBackgroundLoad へ渡す）。
    pub type alias Docs = { walk = WalkDoc.Doc, keys = KeysDoc.Doc, look = LookDoc.Doc, sound = SoundDoc.Doc, layout = Layout.Layout, assets = School.Assets,
                            items = ItemsDoc.Doc, cast = CastDoc.Doc, people = Map[String, Model3d.Model3d], dialogue = Yarn.Program,
                            bundles = List[Bundles.Entry], pending = BackgroundLoad.Pending,
                            group = BackgroundLoad.Group[Result[String, (String, Vector[Int8])], Model3d.Model3d], downloads = LoadProgress.AssetDownloads }

    /// 描く元の束。school = layout と assets から組んだ当たり判定と階ごとの集まり（光の Doc のプレートの光り方も入る）。
    /// mapFrame = 紙のマップの縮尺（layout から 1 回だけ）。items = 拾える物と鍵の Doc・doors = 鍵のかかった部屋の戸口（layout と items から）。
    /// 持ち物の形は小物と同じ assets#props に入る（根の名前 prop_item_<id> → item_<id>。itemModelKey）。
    pub type alias Res = { walk = WalkDoc.Doc, keys = KeysDoc.Doc, look = LookDoc.Doc, sound = SoundDoc.Doc, layout = Layout.Layout, assets = School.Assets, school = School.School,
                           items = ItemsDoc.Doc, doors = List[Items.Door], mapFrame = PaperMap.Frame, cast = CastDoc.Doc, people = Map[String, Model3d.Model3d], dialogue = Yarn.Program,
                           bundles = List[Bundles.Entry], pending = BackgroundLoad.Pending }

    /// docs の group と downloads は読まないので、それの無い束からも組める（テスト）。
    pub def build(docs: { walk = WalkDoc.Doc, keys = KeysDoc.Doc, look = LookDoc.Doc, sound = SoundDoc.Doc, layout = Layout.Layout, assets = School.Assets,
                          items = ItemsDoc.Doc, cast = CastDoc.Doc, people = Map[String, Model3d.Model3d], dialogue = Yarn.Program,
                          bundles = List[Bundles.Entry], pending = BackgroundLoad.Pending | r }): Res =
        let doors = Items.doorsOf(docs#layout, docs#items);
        { walk = docs#walk, keys = docs#keys, look = docs#look, sound = docs#sound, layout = docs#layout, assets = docs#assets,
          school = School.build(docs#layout, docs#assets, glowOf(docs#look), movedOf(doors)), items = docs#items, doors = doors, mapFrame = PaperMap.frameOf(docs#layout),
          cast = docs#cast, people = docs#people, dialogue = docs#dialogue, bundles = docs#bundles, pending = docs#pending }

    // ── 束と人物の glb（起動の読み込みと、ブラウザ版で後から届いた鍵） ──

    /// 解いた鍵 1 つを置き場へ: 人物の鍵は people へ・束は根の名前で建物（school_floor<n>）と小物（prop_<名前>）へ。
    pub def placeModel(layout: Layout.Layout, key: String, model: Model3d.Model3d,
                       placed: (School.Assets, Map[String, Model3d.Model3d])): (School.Assets, Map[String, Model3d.Model3d]) =
        let (assets, people) = placed;
        match Bundles.personOf(key) {
            case Some(name) => (assets, Map.insert(name, model, people))
            case None       => (Bundles.roots(model) |> Map.foldLeftWithKey((acc, name, m) -> placeRoot(layout, name, m, acc), assets), people)
        }

    def placeRoot(layout: Layout.Layout, name: String, m: Model3d.Model3d, assets: School.Assets): School.Assets =
        match layout#floors |> List.find(f -> f#glb == "${name}.glb") {
            case Some(f) => { floors = Map.insert(f#index, m, assets#floors) | assets }
            case None    =>
                if (String.startsWith(prefix = "prop_", name)) { props = Map.insert(String.dropLeft(5, name), m, assets#props) | assets }
                else assets
        }

    /// 後から解けた鍵を置いて校舎を組み直す（取れない・解けない鍵は 1 行言って今のまま）。
    pub def withLoaded(key: String, result: Result[String, Model3d.Model3d], res: Res): Res = match result {
        case Ok(model) =>
            let (assets, people) = placeModel(res#layout, key, model, (res#assets, res#people));
            { assets = assets, people = people, school = School.build(res#layout, assets, glowOf(res#look), movedOf(res#doors)) | res }
        case Err(why) => Log.warnThen("[school] ${key} を読めない（その物なしで続ける）: ${why}", res)
    }

    /// 待つ鍵の無い表（束の無い校舎・テスト）。
    pub def nothingPending(): BackgroundLoad.Pending = { group = "school", states = Map.empty(), sentPriority = Nil, costMs = 0.0, idleSinceMs = -1.0 }

    pub def withPending(pending: BackgroundLoad.Pending, res: Res): Res = { pending = pending | res }

    /// コードで作る絵（仮の建物と非常口のプレート）。
    pub def surfaces(): Map[Surface, Texture3d.Texture3d] =
        Textures.surfaces() |> List.filterMap(s -> Textures.build(s) |> Option.map(t -> (s, t))) |> List.toMap

    def glowOf(look: LookDoc.Doc): School.SignGlow =
        let l = LookDoc.rec(look);
        { color = l#exit#color, intensity = l#exitGlow }

    pub def walkOf(res: Res): WalkDoc.Rec = WalkDoc.rec(res#walk)

    pub def lookOf(res: Res): LookDoc.Rec = LookDoc.rec(res#look)

    // ── 差し替え（保存即反映。Controls.docTable の reload） ──

    pub def withWalk(walk: WalkDoc.Doc, res: Res): Res = { walk = walk | res }

    pub def withKeys(keys: KeysDoc.Doc, res: Res): Res = { keys = keys | res }

    pub def withSound(sound: SoundDoc.Doc, res: Res): Res = { sound = sound | res }

    pub def soundOf(res: Res): SoundDoc.Rec = SoundDoc.rec(res#sound)

    pub def withCast(cast: CastDoc.Doc, res: Res): Res = { cast = cast | res }

    pub def withDialogue(dialogue: Yarn.Program, res: Res): Res = { dialogue = dialogue | res }

    /// 光の Doc は非常口のプレートの光り方を集まりに焼き込んでいるので、校舎を組み直す。
    pub def withLook(look: LookDoc.Doc, res: Res): Res =
        { look = look, school = School.build(res#layout, res#assets, glowOf(look), movedOf(res#doors)) | res }

    /// 配置の表を替えて組み直す（glb は起動時に読んだ物のまま）。
    pub def withLayout(layout: Layout.Layout, res: Res): Res =
        let doors = Items.doorsOf(layout, res#items);
        { layout = layout, doors = doors, school = School.build(layout, res#assets, glowOf(res#look), movedOf(doors)), mapFrame = PaperMap.frameOf(layout) | res }

    /// 拾える物と鍵の Doc を替えて、鍵のかかった戸口を引き直し、校舎を組み直す（動く戸を動かない物の集まりから外す）。
    pub def withItems(items: ItemsDoc.Doc, res: Res): Res =
        let doors = Items.doorsOf(res#layout, items);
        { items = items, doors = doors, school = School.build(res#layout, res#assets, glowOf(res#look), movedOf(doors)) | res }

    /// 動かない物の集まりに入れない小物（鍵のかかった部屋の戸。毎コマ開け閉めの位置で描く）。
    def movedOf(doors: List[Items.Door]): Layout.Prop -> Bool = p -> List.exists(d -> Items.isSameProp(d#prop, p), doors)

    /// 持ち物の形の assets#props の鍵（glb の根の名前 prop_<名前> の <名前>）。
    pub def itemModelKey(item: ItemsDoc.Item): String = String.stripPrefix(substr = "prop_", item#glb) |> Option.getWithDefault(item#glb)
}
