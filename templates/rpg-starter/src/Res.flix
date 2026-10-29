// Res — 描く元の束: Doc と、Doc から作る物（色票で解いたアトラス・マップの地面の層）。読むだけで、遊びの状態は持たない。
// 遊びの状態は World が持ち、App の w は Resources.With[Res, World] の組（Game.app）。
// Res は World を使わない（使う向きは World → Res だけ）。
mod Res {
    use fge::{AudioMixer, AudioMixerDoc, PxSpriteAtlas, PxSpriteDoc, Yarn}
    use Sheet.SheetId

    /// 起動時・描き出し・テストが同じ形で読む Doc の束。
    pub type alias Docs = {
        palette = Palette.Palette,
        sprites = Map[SheetId, PxSpriteDoc.Doc],
        rules = RulesDoc.Doc,
        text = TextDoc.Doc,
        keys = KeysDoc.Doc,
        party = PartyDoc.Doc,
        items = ItemsDoc.Doc,
        shops = ShopsDoc.Doc,
        foes = FoesDoc.Doc,
        foeMoves = FoeMovesDoc.Doc,
        recolors = RecolorsDoc.Doc,
        spells = SpellsDoc.Doc,
        maps = MapDoc.Table,
        mixer = AudioMixer.Mixer,
        dialogue = Yarn.Program
    }

    /// 描く元の束。sheets は色票で解いたアトラス、foeSheets は色違いの敵の鍵 → その 1 体のアトラス（Sheet.recolored）、
    /// arts はマップの名前 → 地面の層。
    pub type alias Res = {
        palette = Palette.Palette,
        sprites = Map[SheetId, PxSpriteDoc.Doc],
        sheets = Map[SheetId, Sheet.Sheet],
        rules = RulesDoc.Doc,
        text = TextDoc.Doc,
        keys = KeysDoc.Doc,
        party = PartyDoc.Doc,
        items = ItemsDoc.Doc,
        shops = ShopsDoc.Doc,
        foes = FoesDoc.Doc,
        foeMoves = FoeMovesDoc.Doc,
        recolors = RecolorsDoc.Doc,
        spells = SpellsDoc.Doc,
        foeSheets = Map[String, Sheet.Sheet],
        maps = MapDoc.Table,
        arts = Map[String, MapArt.Art],
        mixer = AudioMixer.Mixer,
        dialogue = Yarn.Program
    }

    /// 全部の Doc を読む（無い・壊れたファイルは既定。絵が無い部品は描く時に仮の四角になる）。
    pub def loadDocs(): Docs \ Fs.FileRead =
        let items = ItemsDoc.load(ItemsDoc.path());
        { palette = Palette.load(),
          sprites = Sheet.all() |> List.map(id -> (id, PxSpriteDoc.load(Sheet.pathOf(id)))) |> List.toMap,
          rules = RulesDoc.load(RulesDoc.path()),
          text = TextDoc.load(TextDoc.path()),
          keys = KeysDoc.load(KeysDoc.path()),
          party = PartyDoc.load(PartyDoc.path()),
          items = items,
          shops = ShopsDoc.load(ShopsDoc.path()),
          foes = FoesDoc.load(FoesDoc.path()),
          foeMoves = FoeMovesDoc.load(FoeMovesDoc.path()),
          recolors = RecolorsDoc.load(RecolorsDoc.path()),
          spells = SpellsDoc.load(SpellsDoc.path()),
          maps =MapDoc.loadTable(items),
          mixer = loadMixer(),
          dialogue = Talk.load() }

    /// Doc の束から描く元を組む（アトラスとマップの地面の層もここで作る）。
    pub def build(docs: Docs): Res =
        let sheets = sheetsOf(docs#palette, docs#sprites);
        { palette = docs#palette, sprites = docs#sprites, sheets = sheets,
          rules = docs#rules, text = docs#text, keys = docs#keys, party = docs#party, items = docs#items, shops = docs#shops,
          foes = docs#foes, foeMoves = docs#foeMoves, recolors = docs#recolors, spells = docs#spells,
          foeSheets = foeSheetsOf(docs#palette, docs#sprites, docs#foes, docs#recolors),
          maps = docs#maps, arts = artsOf(docs#palette, sheets, docs#maps), mixer = docs#mixer, dialogue = docs#dialogue }

    /// Doc の問題（各 Doc の読めない欄と行）と Doc どうしの食い違い（始まりのマップが無い・出入口と人の食い違い・会話のコマンドの引数を Doc で引けない）を 1 行ずつ。
    /// 起動時に言い（Game.app）、テストは空であることを見る。
    pub def problemsOf(res: Res): List[String] =
        let nodes = Yarn.nodeNames(res#dialogue) |> List.toSet;
        let start = RulesDoc.rec(res#rules)#startMap;
        let startProblem = if (Map.memberOf(start, res#maps)) Nil else "[rules] 始まりのマップ '${start}' が無い" :: Nil;
        let mapProblems = res#maps |> Map.toList |> List.flatMap(match (name, map) ->
            List.flatten(exitProblemsOf(res#maps, nodes, name, MapDoc.rec(map)#exits) :: npcProblemsOf(nodes, name, MapDoc.rec(map)#npcs) ::
                         objectProblemsOf(nodes, name, MapDoc.rec(map)#objects) :: eventProblemsOf(nodes, name, MapDoc.rec(map)#events) :: Nil));
        List.flatten(docProblemsOf(res) :: startProblem :: homeProblemOf(res) :: mapProblems :: flagProblemsOf(res#maps) :: itemRefProblemsOf(res) ::
                     foeRefProblemsOf(res) :: spellRefProblemsOf(res) :: Talk.problemsOf(res, res#maps, res#dialogue) :: Nil)

    /// 旗の食い違い: 旗を読む物（開く物・分かれ目・飛び石）の旗を立てる物（レバー・床のスイッチ・水晶）がどのマップにも無い
    /// （書き損じた旗で、読む物が黙ってずっと閉じたまま・開いたまま）。
    pub def flagProblemsOf(maps: MapDoc.Table): List[String] =
        let objects = maps |> Map.toList |> List.flatMap(match (name, map) -> MapDoc.rec(map)#objects |> List.map(o -> (name, o)));
        let raised = objects |> List.filterMap(pair -> MapDoc.profileOf(snd(pair)#kind)#raises) |> List.toSet;
        objects |> List.filterMap(match (name, o) -> MapDoc.profileOf(o#kind)#reads
            |> Option.filter(flag -> not Set.memberOf(flag, raised))
            |> Option.map(flag -> "[map] ${name} の物 '${o#id}' の旗 '${Flag.nameOf(flag)}' を立てる物（レバー・床のスイッチ・水晶）がどのマップにも無い"))

    /// 敵を鍵で指す所の食い違い: マップの encounter の敵が rpg.foes.json に無い・敵の技の行の敵が無い・
    /// 敵の絵が rpg.monsters.sprite.json に無い・色違いの名前が rpg.recolors.json に無い・戦いの背景の絵が無い。
    def foeRefProblemsOf(res: Res): List[String] =
        let known = key -> Option.nonEmpty(FoesDoc.idOf(res#foes, key));
        let monsters = Map.get(SheetId.Monsters, res#sprites) |> Option.map(doc -> Map.keysOf(doc#sprites)) |> Option.getWithDefault(Set.empty());
        let backs = Map.get(SheetId.BattleFx, res#sprites) |> Option.map(doc -> Map.keysOf(doc#sprites)) |> Option.getWithDefault(Set.empty());
        let encounters = res#maps |> Map.toList |> List.flatMap(match (name, map) ->
            MapDoc.rec(map)#encounter |> List.flatMap(e -> e#foes) |> List.filter(key -> not known(key))
                |> List.map(key -> "[map] ${name} の encounter の敵 '${key}' が ${FoesDoc.path()} に無い"));
        let backProblems = res#maps |> Map.toList |> List.filter(pair -> not Set.memberOf(MapDoc.rec(snd(pair))#battleBack, backs))
            |> List.map(match (name, map) -> "[map] ${name} の battleBack '${MapDoc.rec(map)#battleBack}' が rpg.battlefx.sprite.json に無い");
        let moves = FoeMovesDoc.rec(res#foeMoves)#moves |> List.map(m -> m#foe) |> List.toSet |> Set.toList |> List.filter(key -> not known(key))
            |> List.map(key -> "[foe_moves] 敵 '${key}' が ${FoesDoc.path()} に無い");
        let looks = FoesDoc.rec(res#foes)#foes |> Map.toList |> List.flatMap(match (key, foe) -> {
            let sprite = if (Set.memberOf(foe#sprite, monsters)) Nil else "[foes] '${key}' の絵 '${foe#sprite}' が rpg.monsters.sprite.json に無い" :: Nil;
            let recolor = if (String.isEmpty(foe#recolor) or Option.nonEmpty(RecolorsDoc.swapsOf(res#recolors, foe#recolor))) Nil
                          else "[foes] '${key}' の色違い '${foe#recolor}' が ${RecolorsDoc.path()} に無い" :: Nil;
            List.append(sprite, recolor)
        });
        let colors = RecolorsDoc.rec(res#recolors)#recolors |> Map.toList |> List.flatMap(match (name, swaps) ->
            swaps |> Map.toList |> List.flatMap(match (a, b) -> a :: b :: Nil) |> List.filter(key -> not Map.memberOf(key, res#palette))
                |> List.map(key -> "[recolors] '${name}' の色 '${key}' が ${Palette.path()} に無い"));
        List.flatten(encounters :: backProblems :: moves :: looks :: colors :: Nil)

    /// 呪文を鍵で指す所の食い違い: 覚える表（party の learns）・敵の技（foe_moves の spell）の呪文が rpg.spells.json に無い・
    /// 呪文の演出の絵が rpg.battlefx.sprite.json に無い（演出が黙って出なくなる）。
    def spellRefProblemsOf(res: Res): List[String] =
        let known = key -> Option.nonEmpty(SpellsDoc.idOf(res#spells, key));
        let fxs = Map.get(SheetId.BattleFx, res#sprites) |> Option.map(doc -> Map.keysOf(doc#sprites)) |> Option.getWithDefault(Set.empty());
        let learns = PartyDoc.rec(res#party)#learns |> List.filter(row -> not known(row#spell))
            |> List.map(row -> "[party] learns の呪文 '${row#spell}' が ${SpellsDoc.path()} に無い");
        let moves = FoeMovesDoc.rec(res#foeMoves)#moves |> List.filterMap(m -> FoeMovesDoc.spellKeyOf(m#act))
            |> List.filter(key -> not known(key)) |> List.map(key -> "[foe_moves] 呪文 '${key}' が ${SpellsDoc.path()} に無い");
        let looks = SpellsDoc.rec(res#spells)#spells |> Map.toList |> List.filter(pair -> not Set.memberOf(snd(pair)#fx, fxs))
            |> List.map(match (key, s) -> "[spells] '${key}' の演出の絵 '${s#fx}' が rpg.battlefx.sprite.json に無い");
        List.flatten(learns :: moves :: looks :: Nil)

    /// 宿の前のマップが無い（「つづきから」で入れない）。
    def homeProblemOf(res: Res): List[String] =
        let home = RulesDoc.rec(res#rules)#homeMap;
        if (Map.memberOf(home, res#maps)) Nil else "[rules] 宿の前のマップ '${home}' が無い（「つづきから」で入れない）" :: Nil

    /// 道具を鍵で指す所の食い違い: 店の品・仲間の初めの装備が rpg.items.json に無い。
    def itemRefProblemsOf(res: Res): List[String] =
        let known = key -> Option.nonEmpty(ItemsDoc.idOf(res#items, key));
        let goods = ShopsDoc.rec(res#shops)#goods |> List.map(g -> g#item) |> List.filter(key -> not known(key))
            |> List.map(key -> "[shops] 品 '${key}' が ${ItemsDoc.path()} に無い");
        let gear = Member.all() |> List.flatMap(m -> {
            let row = PartyDoc.memberOf(m, res#party);
            (row#weapon :: row#armor :: Nil) |> List.filter(key -> not String.isEmpty(key) and not known(key))
                |> List.map(key -> "[party] ${Member.idOf(m)} の初めの装備 '${key}' が ${ItemsDoc.path()} に無い")
        });
        List.append(goods, gear)

    /// 各 Doc を読む時に既定へ落とした欄・飛ばした行（load は言わず、ここで 1 回だけ言う）。
    def docProblemsOf(res: Res): List[String] =
        List.flatten(
            RulesDoc.rec(res#rules)#problems :: TextDoc.rec(res#text)#problems :: KeysDoc.rec(res#keys)#problems ::
            PartyDoc.rec(res#party)#problems :: ItemsDoc.rec(res#items)#problems :: ShopsDoc.rec(res#shops)#problems ::
            FoesDoc.rec(res#foes)#problems :: FoeMovesDoc.rec(res#foeMoves)#problems :: RecolorsDoc.rec(res#recolors)#problems ::
            SpellsDoc.rec(res#spells)#problems ::
            (res#maps |> Map.valuesOf |> List.flatMap(map -> MapDoc.rec(map)#problems)) :: Nil)

    /// 出入口の食い違い: 行き先のマップが無い・gate の会話のノードが会話に無い。
    def exitProblemsOf(maps: MapDoc.Table, nodes: Set[String], name: String, exits: List[MapDoc.Exit]): List[String] =
        let missingTo = exits |> List.filter(e -> not Map.memberOf(e#to, maps))
            |> List.map(e -> "[map] ${name} の出入口 '${e#id}' の行き先 '${e#to}' が無い");
        let missingGateNode = exits |> List.filterMap(e -> e#gate |> Option.map(gate -> (e#id, gate#node)))
            |> List.filter(pair -> not Set.memberOf(snd(pair), nodes))
            |> List.map(match (id, node) -> "[map] ${name} の出入口 '${id}' の gateNode '${node}' が ${Talk.dialoguePath()} に無い");
        List.append(missingTo, missingGateNode)

    /// 物の食い違い（道具・鍵の名前はマップの Doc を読む時に引き、引けない行は飛ばして problems に残す）:
    /// 種類ごとの食い違い（kindProblemsOf）・同じ id が 2 つ（開けた旗が混ざる）。
    def objectProblemsOf(nodes: Set[String], name: String, objects: List[MapDoc.Object]): List[String] =
        let rowProblems = objects |> List.flatMap(o -> kindProblemsOf(nodes, name, o));
        let twice = objects |> List.map(o -> (o#id, 1)) |> List.foldLeft((acc, pair) -> Map.insertWith((a, b) -> a + b, fst(pair), snd(pair), acc), Map.empty())
            |> Map.toList |> List.filter(pair -> snd(pair) > 1)
            |> List.map(pair -> "[map] ${name} の objects の id '${fst(pair)}' が 2 つ以上ある（開けた旗が混ざる）");
        List.append(rowProblems, twice)

    /// 物の種類ごとの食い違い: 中身の無い宝箱・番をする者の会話のノードが会話に無い。
    def kindProblemsOf(nodes: Set[String], name: String, o: MapDoc.Object): List[String] = match o#kind {
        case MapDoc.ObjectKind.Chest(c) if Option.isEmpty(c#item) and c#gold <= 0 => "[map] ${name} の宝箱 '${o#id}' に中身（item か gold）が無い" :: Nil
        case MapDoc.ObjectKind.Chest(_) => Nil
        case MapDoc.ObjectKind.Door(_)  => Nil
        case MapDoc.ObjectKind.Lever(_) => Nil
        case MapDoc.ObjectKind.Gate(_)  => Nil
        case MapDoc.ObjectKind.Guard(g) if not Set.memberOf(g#node, nodes) =>
            "[map] ${name} の番をする者 '${o#id}' の会話 '${g#node}' が ${Talk.dialoguePath()} に無い" :: Nil
        case MapDoc.ObjectKind.Guard(_) => Nil
        case MapDoc.ObjectKind.Plate(_) => Nil
        case MapDoc.ObjectKind.Rock     => Nil
        case MapDoc.ObjectKind.Cart(c) if not Set.memberOf(c#node, nodes) =>
            "[map] ${name} のトロッコ '${o#id}' の会話 '${c#node}' が ${Talk.dialoguePath()} に無い" :: Nil
        case MapDoc.ObjectKind.Cart(_)     => Nil
        case MapDoc.ObjectKind.Junction(_) => Nil
        case MapDoc.ObjectKind.Crystal(_)  => Nil
        case MapDoc.ObjectKind.Bridge(_)   => Nil
        case MapDoc.ObjectKind.Sign(s) if not Set.memberOf(s#node, nodes) =>
            "[map] ${name} の読む物 '${o#id}' の会話 '${s#node}' が ${Talk.dialoguePath()} に無い" :: Nil
        case MapDoc.ObjectKind.Sign(_)     => Nil
    }

    /// イベントのマスの食い違い: 会話のノードが会話に無い。
    def eventProblemsOf(nodes: Set[String], name: String, events: List[MapDoc.Event]): List[String] =
        events |> List.filter(e -> not Set.memberOf(e#node, nodes))
            |> List.map(e -> "[map] ${name} の (${e#x}, ${e#y}) のイベントの会話 '${e#node}' が ${Talk.dialoguePath()} に無い")

    /// 人の食い違い: 会話のノードが空・会話に無い。
    def npcProblemsOf(nodes: Set[String], name: String, npcs: List[MapDoc.Npc]): List[String] =
        npcs |> List.filter(n -> not Set.memberOf(n#node, nodes))
            |> List.map(n -> if (String.isEmpty(n#node)) "[map] ${name} の人 '${n#id}' に会話のノード（node）が無い"
                             else "[map] ${name} の人 '${n#id}' の会話 '${n#node}' が ${Talk.dialoguePath()} に無い")

    /// 全部の Doc を読んで組む。
    pub def load(): Res \ Fs.FileRead = build(loadDocs())

    def sheetsOf(palette: Palette.Palette, sprites: Map[SheetId, PxSpriteDoc.Doc]): Map[SheetId, Sheet.Sheet] =
        sprites |> Map.mapWithKey((id, doc) -> Sheet.fromDoc(palette, id, doc))

    def artsOf(palette: Palette.Palette, sheets: Map[SheetId, Sheet.Sheet], maps: MapDoc.Table): Map[String, MapArt.Art] =
        maps |> Map.map(map -> MapArt.build(palette, sheets, map))

    /// 色違いの敵（recolor のある行）ごとに、その 1 体の色を差し替えたアトラス。色違いの名前が無い敵は作らない（元の色で描く）。
    def foeSheetsOf(palette: Palette.Palette, sprites: Map[SheetId, PxSpriteDoc.Doc], foes: FoesDoc.Doc, recolors: RecolorsDoc.Doc): Map[String, Sheet.Sheet] =
        Map.get(SheetId.Monsters, sprites) |> Option.map(doc ->
            FoesDoc.rec(foes)#foes |> Map.toList |> List.filterMap(match (key, foe) ->
                RecolorsDoc.swapsOf(recolors, foe#recolor) |> Option.map(swaps -> (key, Sheet.recolored(palette, key, swaps, foe#sprite, doc))))
                |> List.toMap)
            |> Option.getWithDefault(Map.empty())

    /// GPU と描き出しへ渡すアトラスの一覧（テクスチャ名・鍵・生成した画素）。空のアトラスは渡さない。
    pub def atlases(res: Res): List[{ texture = String, key = String, baked = PxSpriteAtlas.Baked }] =
        List.append(Map.valuesOf(res#sheets), Map.valuesOf(res#foeSheets))
            |> List.filter(sheet -> sheet#baked#side > 0)
            |> List.map(sheet -> { texture = sheet#texture, key = sheet#key, baked = sheet#baked })

    // ── Doc の差し替え（保存即反映。Controls.docTable の reload） ──

    pub def withRules(rules: RulesDoc.Doc, res: Res): Res = { rules = rules | res }

    pub def withText(text: TextDoc.Doc, res: Res): Res = { text = text | res }

    pub def withKeys(keys: KeysDoc.Doc, res: Res): Res = { keys = keys | res }

    pub def withParty(party: PartyDoc.Doc, res: Res): Res = { party = party | res }

    pub def withItems(items: ItemsDoc.Doc, res: Res): Res = { items = items | res }

    pub def withShops(shops: ShopsDoc.Doc, res: Res): Res = { shops = shops | res }

    pub def withMixer(mixer: AudioMixer.Mixer, res: Res): Res = { mixer = mixer | res }

    /// 音の通り道（バス・ダッキング・連打の間引き）の Doc。
    pub def mixerPath(): String = "assets/rpg.mixer.json"

    /// 音の通り道を読む（無い・壊れていれば engine の既定 = 名前のまま鳴らす）。
    pub def loadMixer(): AudioMixer.Mixer \ Fs.FileRead = AudioMixerDoc.load(AudioMixer.defaults(), mixerPath())

    /// 敵か色違いを差し替えたら、色違いのアトラスも作り直す。
    pub def withFoes(foes: FoesDoc.Doc, res: Res): Res =
        { foes = foes, foeSheets = foeSheetsOf(res#palette, res#sprites, foes, res#recolors) | res }

    pub def withFoeMoves(foeMoves: FoeMovesDoc.Doc, res: Res): Res = { foeMoves = foeMoves | res }

    pub def withSpells(spells: SpellsDoc.Doc, res: Res): Res = { spells = spells | res }

    pub def withRecolors(recolors: RecolorsDoc.Doc, res: Res): Res =
        { recolors = recolors, foeSheets = foeSheetsOf(res#palette, res#sprites, res#foes, recolors) | res }

    pub def withDialogue(dialogue: Yarn.Program, res: Res): Res = { dialogue = dialogue | res }

    /// マップを差し替えたら地面の層も組み直す。
    pub def withMaps(maps: MapDoc.Table, res: Res): Res =
        { maps = maps, arts = artsOf(res#palette, res#sheets, maps) | res }

    /// 絵か色票を差し替えたら、アトラスと地面の層（アトラスの中の場所を持つ）を作り直す。
    pub def withSprites(palette: Palette.Palette, sprites: Map[SheetId, PxSpriteDoc.Doc], res: Res): Res =
        let sheets = sheetsOf(palette, sprites);
        { palette = palette, sprites = sprites, sheets = sheets, arts = artsOf(palette, sheets, res#maps),
          foeSheets = foeSheetsOf(palette, sprites, res#foes, res#recolors) | res }
}
