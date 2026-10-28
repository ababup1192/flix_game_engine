// Res — 描く元の束: Doc と、Doc から作る物（仕上げを掛けたドット絵・アトラス）。読むだけで、Doc の読み直しの時だけ替わる。
// 遊びの状態は World が持ち、App の w は Resources.With[Res, World] の組（Main）。
// Res は World を使わない（使う向きは World → Res だけ。lint/rules.flix の module-cycle）。
mod Res {

    use fge::{PxShade, PxSpriteAtlas, PxSpriteDoc, ShaderDoc}

    /// 起動時と描き出しが同じ形で読む Doc の束（Controls.loadDocs）。
    pub type alias Docs = {
        sample = SampleDoc.Doc,
        keys = KeysDoc.Doc,
        theme = ThemeDoc.Doc,
        sprites = PxSpriteDoc.Doc,
        shader = ShaderDoc.Spec
    }

    /// 描く元の束。
    pub type alias Res = {
        sample = SampleDoc.Doc,
        keys = KeysDoc.Doc,
        theme = ThemeDoc.Doc,
        // 仕上げ（shaded）を掛けた後のドット絵。
        sprites = PxSpriteDoc.Doc,
        // ドット絵を 1 枚にまとめたアトラスと、その画素から導いた鍵（bakedOf）。
        atlas = PxSpriteAtlas.Baked,
        atlasKey = String,
        shader = ShaderDoc.Spec
    }

    /// Doc の束から描く元を組む（仕上げとアトラスもここで作る）。
    pub def build(docs: Docs): Res =
        let sprites = shaded(docs#theme, docs#sprites);
        let (baked, key) = bakedOf(docs#theme, sprites);
        { sample = docs#sample, keys = docs#keys, theme = docs#theme, sprites = sprites,
          atlas = baked, atlasKey = key, shader = docs#shader }

    /// GPU に登録するアトラスの論理名（View の drawQuad と Main の withSpriteAtlases が
    /// この名前で待ち合わせる）。
    pub def atlasName(): String = "px"

    /// 「中の色 → (明るい色, 暗い色)」の対応。文字は sprite.json の legend に合わせる。
    /// 色そのものでなく文字の並びなので、これは絵の構造 = コード側に置く。
    def shadeRamp(): PxShade.Ramp =
        Map#{ 'a' => ('A', 'd') }

    /// 読み込んだドット絵に仕上げ（ふち光・接地影・ディザ・粒）を掛ける。
    /// 掛かるのは読み込み直後の 1 回だけで、毎フレームの絵づくりには入らない
    /// （何体出しても走行中の負荷は増えない）。強さと光の向きは theme.json から。
    def shaded(theme: ThemeDoc.Doc, doc: PxSpriteDoc.Doc): PxSpriteDoc.Doc =
        PxShade.shadeDoc(ThemeDoc.rec(theme)#shade, shadeRamp(), doc)

    /// ドット絵を 1 枚のアトラスにまとめ、GPU キャッシュ用の鍵と対で返す。
    ///
    /// **なぜまとめるか**: 画面に出すとき 1 コマ = 1 クアッドで貼れる（PxSprite.drawQuad）。
    /// まとめずに描く PxSprite.draw は 1 コマを画素ぶんの四角に開くので、キャラ 1 体なら
    /// どちらでも同じでも、マス目や群れを出した瞬間に組む数の桁が変わる
    /// （予算と検査は engine の docs/performance.md §9）。まとめるのは読み込みの 1 回だけ。
    ///
    /// **なぜ鍵に画素のハッシュを混ぜるか**: Doc や色票を保存し直して絵が変わったとき、
    /// 鍵が同じままだと GPU に古いテクスチャが残って画面が更新されない。
    def bakedOf(theme: ThemeDoc.Doc, sprites: PxSpriteDoc.Doc): (PxSpriteAtlas.Baked, String) =
        let baked = PxSpriteAtlas.bake(sprites, key -> ThemeDoc.resolver(theme, key));
        let h = baked#pixels |> Vector.foldLeft((acc, px) -> acc * 31 + px, 17);
        (baked, "${atlasName()}:${Int32.toString(baked#side)}:${Int32.toString(h)}")

    // ── Doc の差し替え（保存即反映。Controls.docTable の reload） ──

    pub def withSample(sample: SampleDoc.Doc, res: Res): Res = { sample = sample | res }

    pub def withKeys(keys: KeysDoc.Doc, res: Res): Res = { keys = keys | res }

    /// テーマには仕上げの強さ・光の向きも入っているので、色を変えたら絵も掛け直す（sprites は仕上げを掛ける前の Doc）。
    pub def withTheme(theme: ThemeDoc.Doc, sprites: PxSpriteDoc.Doc, res: Res): Res =
        withShadedSprites(theme, sprites, res)

    pub def withSprites(sprites: PxSpriteDoc.Doc, res: Res): Res = withShadedSprites(res#theme, sprites, res)

    pub def withShader(shader: ShaderDoc.Spec, res: Res): Res = { shader = shader | res }

    /// 色か絵が変わったときに、仕上げを掛け直してアトラスを作り直す。
    /// WhyNot: 位置や時刻の更新ではここを通らない（作り直すのは Doc を読み直した時だけ）。
    def withShadedSprites(theme: ThemeDoc.Doc, sprites: PxSpriteDoc.Doc, res: Res): Res =
        let doc = shaded(theme, sprites);
        let (baked, key) = bakedOf(theme, doc);
        { theme = theme, sprites = doc, atlas = baked, atlasKey = key | res }
}
