// Res — 描く元の束: Doc と、Doc から作る物（仕上げを掛けたドット絵・アトラス・面の列）。読むだけで、Doc の読み直しの時だけ替わる。
// 遊びの状態は World が持ち、App の w は Resources.With[Res, World] の組（Game.app）。
// Res は World を使わない（使う向きは World → Res だけ。lint/rules.flix の module-cycle）。
mod Res {

    use fge::{AudioMixer, Log, PxShade, PxSpriteAtlas, PxSpriteDoc, ShaderDoc}

    /// 遊べる 1 面（Doc の名前と最少手数と盤）。rocks は盤から導いた岩の段の形（描くための形を前もって作って持つ。atlas と同じ扱い）。
    pub type alias Stage = { name = String, parMoves = Int32, board = Board.Board, rocks = Layout.RockLevels }

    /// 面を塗る宣言シェーダーの一式（どれも assets/*.shader.json から読む）。
    pub type alias Surfaces = {
        rock = ShaderDoc.Spec,
        water = ShaderDoc.Spec,
        caustics = ShaderDoc.Spec
    }

    /// 起動時と描き出しが同じ形で読む Doc の束。
    pub type alias Docs = {
        rules = RulesDoc.Doc,
        levels = LevelsDoc.Doc,
        keys = KeysDoc.Doc,
        theme = ThemeDoc.Doc,
        sprites = PxSpriteDoc.Doc,
        surfaces = Surfaces,
        mixer = AudioMixer.Mixer
    }

    /// 描く元の束。
    pub type alias Res = {
        rules = RulesDoc.Doc,
        levels = LevelsDoc.Doc,
        keys = KeysDoc.Doc,
        theme = ThemeDoc.Doc,
        // 仕上げ（shaded）を掛けた後のドット絵。
        sprites = PxSpriteDoc.Doc,
        // ドット絵を 1 枚にまとめたアトラスと、その画素から導いた鍵（bakedOf）。
        atlas = PxSpriteAtlas.Baked,
        atlasKey = String,
        surfaces = Surfaces,
        mixer = AudioMixer.Mixer,
        // rules と levels から組んだ面の列。
        stages = Vector[Stage]
    }

    /// Doc の束から描く元を組む（仕上げ・アトラス・面の列もここで作る）。
    pub def build(docs: Docs): Res =
        let sprites = shaded(docs#theme, docs#sprites);
        let (baked, key) = bakedOf(docs#theme, sprites);
        { rules = docs#rules, levels = docs#levels, keys = docs#keys, theme = docs#theme, sprites = sprites,
          atlas = baked, atlasKey = key, surfaces = docs#surfaces, mixer = docs#mixer,
          stages = stagesOf(docs#rules, docs#levels) }

    /// GPU に登録するアトラスの論理名（View の drawQuad と Main の withSpriteAtlases がこの名前で待ち合わせる）。
    pub def atlasName(): String = "px"

    /// Doc から遊べる面の列を組む（組めない面は飛ばして 1 行ずつ言う。LevelsDoc.boardsOf）。
    def stagesOf(rules: RulesDoc.Doc, levels: LevelsDoc.Doc): Vector[Stage] =
        let built = LevelsDoc.boardsOf(rules, levels);
        built#boards
            |> Log.warnAllThen(built#problems)
            |> List.map(match (level, b) -> { name = level#name, parMoves = level#parMoves, board = b, rocks = Layout.rockLevelsOf(b) })
            |> List.toVector

    /// 「中の色 → (明るい色, 暗い色)」の対応。文字は sprite.json の legend に合わせる。
    def shadeRamp(): PxShade.Ramp = Map#{ 'a' => ('A', 'd') }

    /// 読み込んだドット絵に仕上げ（ふち光・接地影・ディザ・粒）を掛ける（読み込み直後の 1 回だけ）。
    def shaded(theme: ThemeDoc.Doc, doc: PxSpriteDoc.Doc): PxSpriteDoc.Doc =
        PxShade.shadeDoc(ThemeDoc.rec(theme)#shade, shadeRamp(), doc)

    /// ドット絵を 1 枚のアトラスにまとめ、GPU キャッシュ用の鍵と対で返す。
    /// WhyNot: 鍵を名前だけにしない。Doc や色票を保存し直して絵が変わっても、鍵が同じだと GPU に古いテクスチャが残る。
    def bakedOf(theme: ThemeDoc.Doc, sprites: PxSpriteDoc.Doc): (PxSpriteAtlas.Baked, String) =
        let baked = PxSpriteAtlas.bake(sprites, key -> ThemeDoc.resolver(theme, key));
        let h = baked#pixels |> Vector.foldLeft((acc, px) -> acc * 31 + px, 17);
        (baked, "${atlasName()}:${Int32.toString(baked#side)}:${Int32.toString(h)}")

    // ── Doc の差し替え（保存即反映。Controls.docTable の reload） ──

    /// 決まりか面の Doc を差し替えたら面の列も組み直す（遊んでいる面を収め直すのは World.settleStages）。
    pub def withRules(rules: RulesDoc.Doc, res: Res): Res = { rules = rules, stages = stagesOf(rules, res#levels) | res }

    pub def withLevels(levels: LevelsDoc.Doc, res: Res): Res = { levels = levels, stages = stagesOf(res#rules, levels) | res }

    pub def withKeys(keys: KeysDoc.Doc, res: Res): Res = { keys = keys | res }

    /// テーマには仕上げの強さ・光の向きも入っているので、色を変えたら絵も掛け直す（sprites は仕上げを掛ける前の Doc）。
    pub def withTheme(theme: ThemeDoc.Doc, sprites: PxSpriteDoc.Doc, res: Res): Res =
        withShadedSprites(theme, sprites, res)

    pub def withSprites(sprites: PxSpriteDoc.Doc, res: Res): Res = withShadedSprites(res#theme, sprites, res)

    pub def withSurfaces(surfaces: Surfaces, res: Res): Res = { surfaces = surfaces | res }

    pub def withMixer(mixer: AudioMixer.Mixer, res: Res): Res = { mixer = mixer | res }

    def withShadedSprites(theme: ThemeDoc.Doc, sprites: PxSpriteDoc.Doc, res: Res): Res =
        let doc = shaded(theme, sprites);
        let (baked, key) = bakedOf(theme, doc);
        { theme = theme, sprites = doc, atlas = baked, atlasKey = key | res }
}
