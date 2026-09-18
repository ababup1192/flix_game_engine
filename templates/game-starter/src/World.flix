// World — ゲームの状態そのものと、次の状態を作る規則（すべて純粋）。
// 主人公を矢印キーで動かすだけの最小の骨組み。数値の初期値（速さ）は SampleDoc、
// 色は ThemeDoc、絵の格子は PxSpriteDoc、空の塗りは ShaderDoc — 実行中の状態は
// この World だけが持つ。
mod World {

    /// このフレームの入力（横・縦の軸値。-1 / 0 / +1）。
    pub type alias Input = { x = Float64, y = Float64 }

    pub type alias World = {
        doc = SampleDoc.Doc,
        keys = KeysDoc.Doc,
        theme = ThemeDoc.Doc,
        sprites = PxSpriteDoc.Doc,
        // ドット絵を 1 枚にまとめたアトラスと、その画素から導いた鍵（下の bakedOf を参照）。
        atlas = PxSpriteAtlas.Baked,
        atlasKey = String,
        shader = ShaderDoc.Spec,
        x = Float64,
        y = Float64,
        t = Float64,
        activeDocsWritten = String
    }

    // ── 盤の寸法（design __W__×__H__ の中の定数。project.json と同じ値） ──

    pub def width(): Float64 = __W__.0
    pub def height(): Float64 = __H__.0

    /// ドット絵を何倍の大きさで描くか（1 セル = 何 px か）。
    pub def spriteScale(): Int32 = 2

    /// 主人公の大きさ = 絵の大きさ。絵を描き替えたら当たりもついてくる
    /// （固定値にすると、絵だけ大きくして当たりが古いまま、という食い違いが出る）。
    /// 絵がまだ読めていないときだけ 16×16 にする（fail-open）。
    pub def heroBox(w: World): Vec2.Vec2 =
        PxSprite.sizeOf(w#sprites, "hero", "idle", spriteScale())
            |> Option.getWithDefault({ x = 16.0, y = 16.0 })

    pub def spritePath(): String = "assets/__NAME__.sprite.json"

    pub def shaderPath(): String = "assets/__NAME__.shader.json"

    /// 「中の色 → (明るい色, 暗い色)」の対応。文字は sprite.json の legend に合わせる。
    /// 色そのものでなく文字の並びなので、これは絵の構造 = コード側に置く。
    def shadeRamp(): PxShade.Ramp =
        Map#{ 'a' => ('A', 'd') }

    /// 読み込んだドット絵に仕上げ（ふち光・接地影・ディザ・粒）を掛ける。
    /// 掛かるのは読み込み直後の 1 回だけで、毎フレームの絵づくりには入らない
    /// （何体出しても走行中の負荷は増えない）。強さと光の向きは theme.json から。
    pub def shaded(theme: ThemeDoc.Doc, doc: PxSpriteDoc.Doc): PxSpriteDoc.Doc =
        PxShade.shadeDoc(ThemeDoc.rec(theme)#shade, shadeRamp(), doc)

    /// GPU に登録するアトラスの論理名（View の drawQuad と Main の withSpriteAtlases が
    /// この名前で待ち合わせる）。
    pub def atlasName(): String = "px"

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

    /// 色か絵が変わったときに、仕上げを掛け直してアトラスを作り直す。
    /// テーマにも絵にも触らない更新（位置・時刻）はここを通らない。
    def withShadedSprites(theme: ThemeDoc.Doc, sprites: PxSpriteDoc.Doc, w: World): World =
        let doc = shaded(theme, sprites);
        let (baked, key) = bakedOf(theme, doc);
        { theme = theme, sprites = doc, atlas = baked, atlasKey = key | w }

    /// ゲーム開始時の状態。主人公は画面の真ん中。
    pub def initial(doc: SampleDoc.Doc, keys: KeysDoc.Doc, theme: ThemeDoc.Doc,
                    sprites: PxSpriteDoc.Doc, shader: ShaderDoc.Spec): World =
        let shadedSprites = shaded(theme, sprites);
        let (baked, key) = bakedOf(theme, shadedSprites);
        { doc = doc, keys = keys, theme = theme, sprites = shadedSprites,
          atlas = baked, atlasKey = key, shader = shader,
          x = width() / 2.0, y = height() / 2.0, t = 0.0, activeDocsWritten = "" }

    /// 大きさ box の物が画面から出ない位置へ丸める（端で止まるのはルール）。
    pub def clampInside(box: Vec2.Vec2, p: Vec2.Vec2): Vec2.Vec2 =
        { x = Num.clamp(box#x / 2.0, width() - box#x / 2.0, p#x),
          y = Num.clamp(box#y / 2.0, height() - box#y / 2.0, p#y) }

    /// 入力と経過時間から次の状態を作る。速さは Doc（sample.kind.json）から。
    /// t は積み上げた秒。空の流れ・塵・待ち姿の揺れがこれを見る。
    pub def step(input: Input, dt: Float64, w: World): World =
        let speed = SampleDoc.rec(w#doc)#speed;
        let moved = { x = w#x + input#x * speed * dt, y = w#y + input#y * speed * dt };
        let p = clampInside(heroBox(w), moved);
        { x = p#x, y = p#y, t = w#t + dt | w }

    // ── Doc の差し替え（保存即反映） ──

    pub def withDoc(doc: SampleDoc.Doc, w: World): World = { doc = doc | w }

    pub def withKeys(keys: KeysDoc.Doc, w: World): World = { keys = keys | w }

    /// テーマには仕上げの強さ・光の向きも入っているので、色を変えたら絵も掛け直す。
    pub def withTheme(theme: ThemeDoc.Doc, sprites: PxSpriteDoc.Doc, w: World): World =
        withShadedSprites(theme, sprites, w)

    pub def withSprites(sprites: PxSpriteDoc.Doc, w: World): World =
        withShadedSprites(w#theme, sprites, w)

    pub def withShader(shader: ShaderDoc.Spec, w: World): World = { shader = shader | w }
}
