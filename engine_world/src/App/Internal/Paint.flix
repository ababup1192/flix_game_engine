// App.Internal.Paint — World を 1 コマの絵にして描き手へ渡す所: カメラの確定・View と HUD の合成・タイル層と静的層・Pass・Shader 面と 3D の場面の振り分け・字の用意・絵の値段の知らせ。
// ゲームからは呼ばない（App の中身。ゲームの src・test で App.Internal. を書くと lint が止める）。
pub mod App.Internal.Paint {
    import java.lang.System

    /// 生成したアトラスを描画部へ渡しておく（同じ key の間は何も起きない）。
    /// 同じ名前が 2 つ来たら後の方だけを使う — 両方渡すと毎フレーム key が入れ替わり、
    /// 大きさが違えば 1 枚ずつ GPU に置き去りになる。
    def uploadAtlases(uploads: List[App.AtlasUpload]): Unit \ GameEngine.Game =
        uploads
            |> List.foldLeft((acc, a) -> Map.insert(a#texture, a, acc), Map.empty())
            |> Map.forEach((_, a) ->
                if (a#baked#side > 0)
                    GameEngine.Game.ensureTexture(a#texture, a#key,
                        a#baked#side, a#baked#side, a#baked#pixels)
                else ())

    /// debug 有効時だけ、画面右上に小さく fps を出す絵を組む（無効なら空 = 本番に一切出ない）。
    /// fps 表示は withView を使うゲームのみ（view = None の自前描画ゲームには出ない）—
    /// renderFrame が App の絵を描かない構成では、ここで組んでも捨てられるだけなので組まない。
    /// 字はゲームのフォントではなく組み込みフォントで出す — ゲームごとにフォント名が違い、
    /// 特定の名前を当てにすると名前が違うゲームで fps 表示が出せなくなる。
    pub def fpsOverlayOf(r: App.Rec[w, ef], anno: Annotate.State): List[Render.PlacedItem] \ GameEngine.Game =
        if (not r#debug or Option.isEmpty(r#view)) Nil
        else {
            let atlas = GameEngine.Game.getFontAtlas(BootFont.name());
            let design = GameEngine.Game.getViewportRect()#size;
            // 組み込みフォントはドット絵なので、作った大きさの等倍で出す。
            Annotate.fpsItems(atlas, atlas#fontSize, design, Annotate.fpsOf(anno))
        }

    /// 静的レイヤーを通常の動的アイテムとして描くための PlacedItem 列（F8 のズーム・パン中と、注釈の書き出し）。
    /// build（ワールド座標）に主 view と同じ camera（resolvedCamera → composeScene）を掛けて、
    /// 動的な絵と重なり順・位置を揃える。静的レイヤーが無ければ空。
    pub def staticPausedItems(app: App[w, ef], design: Vec2.Vec2, world: w): List[Render.PlacedItem] \ ef =
        let r = App.rec(app);
        match r#staticLayer {
            case None    => Nil
            case Some(sl) =>
                let (center, z) = App.resolvedCamera(r, world, design);
                App.composeScene(center, z, design, { world = (sl#build)(world), hud = Nil })
        }

    /// 静的レイヤー（withStaticLayer）を、この World の camera から解決した描画依頼にする。
    /// key と polys（build → Render.draw の多角形チャンネル）はエンジンがキャッシュに使い、
    /// viewOffset/viewScale/halfDesign は動的な絵と同じ camera 値（resolvedCamera）から出すので、
    /// 静的な絵と動的な絵の視点は 1px もずれない。カメラ無しなら恒等（world 座標そのまま）。
    /// polys は build（純粋）だけを包むので、キャッシュヒット時に呼ばれても副作用は無い。
    def staticLayerCmd(app: App[w, ef], world: w): Option[GameEngine.StaticLayerCmd] \ (ef + GameEngine.Game) =
        let r = App.rec(app);
        match r#staticLayer {
            case None    => None
            case Some(sl) =>
                let design = GameEngine.Game.getViewportRect()#size;
                let (center, z) = App.resolvedCamera(r, world, design);
                let (viewOffset, viewScale, halfDesign) = match center {
                    case Some(c) => (c, { x = z, y = z }, Vec2.div(design, 2.0))
                    case None    => (Vec2.zero(), { x = 1.0, y = 1.0 }, Vec2.zero())
                };
                let key = (sl#key)(world);
                let build = sl#build;
                Some({ key = key,
                       // 箱で組んだ絵（ドット絵の走りなど）も生成できるよう、飾りの無い箱は
                       // 多角形へ直してから渡す — 静的層が生成するのは多角形チャンネルだけ。
                       polys = () -> {
                           let (_, polys) = Render.draw(Render.boxesAsPolys(build(world)));
                           polys },
                       viewOffset = viewOffset, viewScale = viewScale, halfDesign = halfDesign })
        }

    /// タイル層の GPU 生成結果の持ち回し。ループが引数で持ち回す。
    /// gen は「Doc の読み直し（watchFile / reloadOn）が起きた回数」= タイル層の世代。
    /// entries は層のスロット（宣言リストの並び順）→ (生成した時点の世代, 生成した時の key, VAO, 数)。
    /// スロットで引くので、key が頻繁に転がる層（照明・カメラ追随で作り直しが多い地形など）でも
    /// VAO は 1 層に 1 本のまま — 作り直しは updateTileBuffer の入れ直しで済む。
    /// passTargets はこれまでに Pass として描いたターゲットの名前（GPU に残っている物。増えるだけ）—
    /// Pass の中で、このコマで宣言していない古いターゲットを読んだのを見分ける（Render.resolvePassReads）。
    pub type alias TileCache =
        { gen = Int32, entries = Map[String, (Int32, String, GpuHandle.TileVao, Int32)], passTargets = Set[String] }

    /// まだ何も生成していない起動時の持ち回し。
    pub def freshTileCache(): TileCache = { gen = 0, entries = Map.empty(), passTargets = Set.empty() }

    /// Doc の読み直しが起きたフレームで世代を進める。ゲームの書く key は素のまま、
    /// 世代の不一致が「作り直しが要る」の判定になる（tileCacheHit が見る）。
    // どの Doc がどのタイル層に効くかの依存表は持たない — 無関係な Doc の保存でも全層が
    // 作り直されるが、保存は人の手の速さでしか起きず、作り直しは 1 回のバッファ転送で済む。
    pub def bumpTileGen(fired: Bool, cache: TileCache): TileCache =
        if (fired) { gen = cache#gen + 1 | cache } else cache

    /// スロットに取ってある生成結果を引く。生成した時点の世代と key が今と一致した時だけ使い回せる。
    pub def tileCacheHit(slot: String, key: String, cache: TileCache): Option[(GpuHandle.TileVao, Int32)] =
        Map.get(slot, cache#entries) |> Option.flatMap(e -> {
            let (g, k, vao, n) = e;
            if (g == cache#gen and k == key) Some((vao, n)) else None
        })

    /// スロットに生成結果があれば、その VAO を返す（世代・key が古くてもよい —
    /// updateTileBuffer で中身を入れ直す先として使う）。
    pub def tileCacheVaoAt(slot: String, cache: TileCache): Option[GpuHandle.TileVao] =
        Map.get(slot, cache#entries) |> Option.map(e -> {
            let (_, _, vao, _) = e;
            vao
        })

    /// 生成した結果をスロットへ上書きで置く（一覧表は宣言中のレイヤーの数までしか育たない）。
    pub def tileCacheStore(slot: String, key: String, vao: GpuHandle.TileVao, count: Int32,
                           cache: TileCache): TileCache =
        { entries = Map.insert(slot, (cache#gen, key, vao, count), cache#entries) | cache }

    /// 宣言されたタイル層を描画コマンドにする。スロット（宣言リストの並び順）に同じ世代・
    /// 同じ key でキャッシュ済みなら使い回し、key か世代が変われば同じ VAO へ中身を
    /// 入れ直す（updateTileBuffer）。新しいスロットだけ initTileBuffer で VAO を作る —
    /// key が毎バケツ転がる層でも GPU バッファは 1 層 1 本のまま。
    /// 位置と倍率は動的な絵と同じ camera 値（resolvedCamera）から出すので視点はずれない。
    def tileLayerCmds(app: App[w, ef], world: w, cache: TileCache):
            (List[GameEngine.TileMapRenderCmd], TileCache) \ (ef + GameEngine.Game) =
        let r = App.rec(app);
        match r#tileLayers {
            case None    => (Nil, cache)
            case Some(f) =>
                let design = GameEngine.Game.getViewportRect()#size;
                let (center, z) = App.resolvedCamera(r, world, design);
                let (cmds, nextCache) = List.foldLeft((acc, entry) -> {
                    let (i, spec) = entry;
                    let slot = "${i}";
                    let (done, c) = acc;
                    let (vao, count) = match tileCacheHit(slot, spec#key, c) {
                        case Some(h) => h
                        case None    =>
                            let ts = spec#tileSet#atlasSource#tileSize;
                            let tilesOf = spec#tiles;
                            let instances = TileLayer.buildInstances(tilesOf(), spec#tileSet, ts);
                            match tileCacheVaoAt(slot, c) {
                                case Some(v) => GameEngine.Game.updateTileBuffer(v, instances)
                                case None    => GameEngine.Game.initTileBuffer(instances)
                            }
                    };
                    let (pos, scale) = match center {
                        case Some(c0) => (Vec2.add(Vec2.mul(Vec2.sub(spec#origin, c0), z),
                                                   Vec2.div(design, 2.0)),
                                          ({ x = z, y = z }: Vec2.Vec2))
                        case None     => (spec#origin, ({ x = 1.0, y = 1.0 }: Vec2.Vec2))
                    };
                    let cmd: GameEngine.TileMapRenderCmd = {
                        textureName = spec#tileSet#atlasSource#textureName,
                        tileSize    = spec#tileSet#atlasSource#tileSize,
                        position    = pos,
                        tileScale   = scale,
                        color       = { r = 1.0, g = 1.0, b = 1.0 },
                        zIndex      = spec#zIndex,
                        tileVaoId   = vao,
                        tileCount   = count };
                    (cmd :: done, tileCacheStore(slot, spec#key, vao, count, c))
                }, ((Nil: List[GameEngine.TileMapRenderCmd]), cache), List.zipWithIndex(f(world)));
                (List.reverse(cmds), nextCache)
        }

    /// タイル層を通常の動的アイテムとして描くための PlacedItem 列（F8 のズーム・パン中と、注釈の書き出し）。
    /// staticPausedItems と同じ理屈 — F8 のズーム・パンは描く前の絵に掛けるので、
    /// GPU タイル経路の camera では追随できない。CPU 投影（TileScene.toItems）で普通のアイテムに変換する。
    pub def tilePausedItems(app: App[w, ef], design: Vec2.Vec2, world: w): List[Render.PlacedItem] \ ef =
        let r = App.rec(app);
        match r#tileLayers {
            case None    => Nil
            case Some(f) =>
                let (center, z) = App.resolvedCamera(r, world, design);
                let items = f(world) |> List.flatMap(TileScene.toItems);
                App.composeScene(center, z, design, { world = items, hud = Nil })
        }

    /// 1 コマの見え方。走っている間は等倍（plainLook）、F8 で止めている間はズーム・パン（pausedLook）。
    /// どちらも同じ renderFrame で描く。
    pub type alias Look = {
        view = Annotate.View,                  // 絵に掛けるズーム・パン（等倍なら掛けない）
        inspected = List[Render.PlacedItem],   // 見え方と一緒に動く重ね物（ドラッグ中の矩形）
        fixed = List[Render.PlacedItem]        // 見え方の後に重ねる物（fps・トースト・スクラブの位置）
    }

    /// 等倍の見え方に fixed を重ねるだけの Look。design は等倍なので使われず、0 で足りる。
    pub def plainLook(fixed: List[Render.PlacedItem]): Look =
        { view = { zoom = 1.0, pan = Vec2.zero(), design = Vec2.zero() }, inspected = Nil, fixed = fixed }

    /// フレームをまたいで持ち回す、描き方の覚え（タイル層の VAO・欠けの無かった字の指紋・予算を知らせたか）。
    pub type alias Painted = { tileCache = TileCache, glyphSeen = Option[Int64], budgetWarned = Bool }

    /// GPU の道へ 1 枚分（画面のコマか、開いている Pass の中）の描き物を渡す。順は Shader 面（drawSurface）→ 3D の場面
    /// （drawScene3d）→ 残りの 2D（drawWith → renderCommands）。面と場面は 2D の列から外して二重に描かない。
    /// 重なり順は描き手が (zIndex, 種類, 追加順) で合流させて決める（docs/z-bands.md）。
    /// warnOnce = 同じ z の並びと Param の渡し忘れの知らせ（黙らせるなら `_ -> ()`）。
    /// tiles と staticLayer は画面のコマの物（Pass の中は Nil と None）。
    // WhyNot: 面も場面も無いコマで withoutShaders / withoutScenes3d を通さない — filter が全件を作り直す。
    //   drawShaders・drawScenes3d と同じ unwrapClip で見るので、命令が空 = 外す物も無い。
    pub def submitGpuItems(warnOnce: String -> Unit \ ef, items: List[Render.PlacedItem],
                           tiles: List[GameEngine.TileMapRenderCmd], staticLayer: Option[GameEngine.StaticLayerCmd]):
            Unit \ (ef + GameEngine.Game + ShaderEffect.Shader) =
        let sceneCmds = Render.drawScenes3d(items);
        let shaderCmds = noteSurfaceZ(warnOnce, items, sceneCmds,
            Render.drawShaders(spec -> ShaderEffect.Shader.buildProgram(spec), items));
        List.forEach(cmd -> ShaderEffect.Shader.drawSurface(cmd), shaderCmds);
        List.forEach(cmd -> ShaderEffect.Shader.drawScene3d(cmd), sceneCmds);
        let withoutSurfaces = if (List.isEmpty(shaderCmds)) items else Render.withoutShaders(items);
        let itemsToDraw = if (List.isEmpty(sceneCmds)) withoutSurfaces else Render.withoutScenes3d(withoutSurfaces);
        // drawWith(getTextureInfo): regionRect 付き Sprite（PxSprite.drawQuad のアトラス 1 クアッド等）の UV を
        // registry の寸法で解決する。regionRect 無しの絵は draw と同一の Drawable になる。
        let (sprites, polygons) = Render.drawWith(name -> GameEngine.Game.getTextureInfo(name), itemsToDraw);
        GameEngine.Game.renderCommands(sprites, tiles, polygons, staticLayer)

    /// 面か 3D の場面のある画面で、面か場面の後ろに同じ z の描き物を並べた z・面と場面を同じ z に並べた z と、
    /// 値の渡されていない Param を知らせてから shaderCmds を返す（面も場面も無ければ見ない）。
    // WhyNot: 知らせを文として並べて Unit を捨てない — note が純粋な型だと、Flix はその呼び出しごと消す
    //   （docs/flix-conventions.md「値を let _ = で捨てない」）。返す値に繋いで必ず走らせる。
    def noteSurfaceZ(note: String -> Unit \ ef, items: List[Render.PlacedItem], sceneCmds: List[d], shaderCmds: List[c]): List[c] \ ef =
        if (List.isEmpty(shaderCmds) and List.isEmpty(sceneCmds)) shaderCmds
        else match Render.surfaceZShared(items) |> List.forEach(z ->
                note("[render] z=${Int32.toString(z)}: ShaderDoc の面か 3D の場面の後ろに同じ z の描き物がある（または面と場面が同じ z にある）— 同じ z の中では面と場面が一番手前（面 → 場面の順）に描かれ、並びの順は効かない。手前に出す物の z を大きくする（docs/z-bands.md）")) {
            case () => if (List.isEmpty(shaderCmds)) shaderCmds else noteMissingParams(note, items, shaderCmds)
        }

    /// 面の Spec の Param のうち値の渡されていない物を知らせてから shaderCmds を返す（その値は 0 で描く）。
    def noteMissingParams(note: String -> Unit \ ef, items: List[Render.PlacedItem], shaderCmds: List[c]): List[c] \ ef =
        match Render.missingShaderParams(items) |> List.forEach(sp -> {
                let (specName, param) = sp;
                note("[render] 面 ${specName}: param '${param}' の値が渡されていない — 0 で描きました。Render.withShaderParams で値を付ける（docs/shader-doc.md）")
            }) {
            case () => noteWorld3dOnSurface(note, items, shaderCmds)
        }

    /// World / Normal を読む Spec が 2D の面に置かれていることを知らせてから shaderCmds を返す（その値は 0 で描く）。
    def noteWorld3dOnSurface(note: String -> Unit \ ef, items: List[Render.PlacedItem], shaderCmds: List[c]): List[c] \ ef =
        match Render.shadersReadingWorld3d(items) |> List.forEach(specName ->
                note("[render] 面 ${specName}: world / normal は 3D の材質（Scene3d.withMaterial）だけが値を持つ — 2D の面では 0 で描きました（docs/shader-doc.md）")) {
            case () => shaderCmds
        }

    /// 絵の値段の上限（1 フレームに組む描き物の数）。docs/performance.md の R3
    /// 「動的 PlacedItem < 2000 個/フレーム」から借りた既定値で、
    /// bin/lint-rules/check-render-budget.json の defaultCap と同じ数。
    def budgetCap(): Int32 = 2000

    /// 予算を超えていたら標準エラーへ 1 回だけ知らせる（戻り値は「もう知らせたか」）。
    /// headless の検査（reference-check の予算判定）は代表フレーム 1 枚しか見ないので、
    /// Fx の最悪化・場面の切り替わり・GIF でしか作らない場面はここでしか捕まらない。
    /// WhyNot: 毎フレーム出さない — 遅い画面をさらに遅くし、ログも読めなくなる。
    def warnOverBudget(count: Int32, warned: Bool): Bool \ IO =
        if (warned or count < budgetCap()) warned
        else {
            System.err.println("budget: この 1 フレームで ${count} 個の描き物を組みました"
                + "（上限 ${budgetCap()} 個）。盤や群れを毎フレーム組み直していませんか —"
                + " タイル層は App.withTileLayers（逆引き: make module Q=毎フレーム）");
            true
        }

    /// view の投影した絵を描画命令にしてエンジンへ渡す。タイルマップは withTileLayers の
    /// 宣言があるときだけ生成して添える（持ち回しの TileCache を返す）。
    /// view = None のゲームは App では描かない（自分のシステム内で renderCommands を呼ぶ。
    /// camera / hudView もこの場合は効かない）。
    /// fps は debug 有効時だけ隅に重ねる（本番は Nil を渡すので描画に一切現れない）。
    pub def renderFrame(app: App[w, ef], warnOnce: String -> Unit, world: w, look: Look,
                        tileCache: TileCache, glyphSeen: Option[Int64], budgetWarned: Bool):
            (TileCache, Option[Int64], Bool) \ (ef + GameEngine.Game + ShaderEffect.Shader + RenderTarget.Target + IO) =
        let r = App.rec(app);
        match r#view {
            case None          => (tileCache, glyphSeen, budgetWarned)
            case Some(toItems) =>
                uploadAtlases((r#spriteAtlases)(world));
                let atlas = GameEngine.Game.getFontAtlas("default");
                let design = GameEngine.Game.getViewportRect()#size;
                let plan = notePassIssues(warnOnce, Render.resolvePassReads(tileCache#passTargets, (r#passes)(world)));
                let passList = plan#passes;
                renderPasses(warnOnce, design, plan);
                let cacheSeen = { passTargets = passList |> List.foldLeft((acc, p) -> Set.insert(p#name, acc), tileCache#passTargets)
                                  | tileCache };
                // タイル層と静的層は GPU 側でカメラを掛けるので、見え方（F8 のズーム・パン）を掛けられない。
                // 見え方が等倍でない間だけ、ほかの絵と同じ PlacedItem に直して一緒に掛ける。
                let retained = Annotate.isIdentity(look#view);
                let scene = App.sceneItems(app, atlas, warnOnce, world, toItems);
                let base = if (retained) scene
                           else List.append(tilePausedItems(app, design, world),
                                            List.append(scene, staticPausedItems(app, design, world)));
                let inspected = Annotate.applyInspectItems(look#view,
                    if (List.isEmpty(look#inspected)) base else List.append(base, look#inspected));
                // fixed は本番ビルドで Nil — 空の append で本編全件を cons し直さない。
                let items = if (List.isEmpty(look#fixed)) inspected else List.append(inspected, look#fixed);
                // 字の欠け照合はレンダーターゲットの中の字も一緒に見る（ターゲットも本編と
                // 同じ「初めて出る字は 1 コマ遅れる」に乗せる）。
                let itemsForGlyphs = List.append(List.flatMap(p -> p#items, passList), items);
                // アトラスに無い字があれば、描く前に用意してもらう（初めて出る字は 1 コマ遅れる）。
                // たいていは空振りで、そのときは何も起きない。glyphSeen は「欠けが無かった
                // フレームの字の指紋」— 同じ指紋の間は 1 字ずつの照合を引き直さない。
                // アトラスは ensureGlyphs でしか育たず、育つのは欠けが出たフレームだけなので、
                // 欠けゼロの指紋を覚えても古い答えを返す余地が無い。欠けが出たフレームは
                // 覚えない（作った直後にアトラスが育ち、同じ字でも答えが変わるため）。
                let fp = Render.glyphFingerprint(itemsForGlyphs);
                let nextSeen = if (glyphSeen == Some(fp)) glyphSeen else {
                    let missing = Render.missingGlyphs(itemsForGlyphs);
                    Map.forEach((textureName, cps) -> GameEngine.Game.ensureGlyphs(textureName, cps),
                                missing);
                    if (Map.isEmpty(missing)) Some(fp) else None
                };
                // 面と 3D の場面は別チャンネル（eff Shader）へ積み、残りの 2D と一緒に描き手が z で合流させる。
                let (tileCmds, nextCache) = if (retained) tileLayerCmds(app, world, cacheSeen) else (Nil, cacheSeen);
                submitGpuItems(warnOnce, items, tileCmds, if (retained) staticLayerCmd(app, world) else None);
                // 数えるのは itemsForGlyphs（本編 + レンダーターゲットの中）— headless の
                // 検査と同じ量にそろえる。タイル層・静的層は GPU 側で 1 層 1 draw call に
                // なるので、ここには最初から乗っていない（= 正しく静的化した絵は安いまま）。
                // 知らせた後は数えない — List.length も毎フレームの一巡で、答えはもう使われない。
                (nextCache, nextSeen,
                 if (budgetWarned) true
                 else warnOverBudget(List.length(itemsForGlyphs), budgetWarned))
        }

    /// 1 コマだけ描く（窓なしで GPU に塗る 1 枚撮り・動画。render_gl の GlOffscreen.handle の下で呼ぶ）。
    /// 実機の 1 フレームの描く所（renderFrame）と同じ道で、fps の重ねと予算の知らせは無し。
    /// 初めて出る字はこのコマでは欠ける（アトラスを育てるのはこのコマの後）ので、欠けが出たら描き直す（最大 3 回）。
    /// tileCache は同じ GL の文脈の間で持ち回す（最初は freshTileCache()）。
    pub def paintOnce(app: App[w, ef], world: w, tileCache: TileCache):
            TileCache \ (ef + GameEngine.Game + ShaderEffect.Shader + RenderTarget.Target + IO) =
        def go(cache, left) = {
            let (next, seen, _) = renderFrame(app, _ -> (), world, plainLook(Nil), cache, None, true);
            if (Option.isEmpty(seen) and left > 1) go(next, left - 1) else next
        };
        go(tileCache, 3)

    /// レンダーターゲットの列を本編より先に描く（宣言順・resolvePassReads を通した後の計画）。ターゲットの中は
    /// design 座標そのままで、Shader 面と 3D の場面も本編と同じ道（submitGpuItems）で描く。
    /// テクセル寸法は RenderTarget.texelSizeOf（名前の作り方と、描き手の画素の倍率 Target.pixelScale）。
    def renderPasses(warnOnce: String -> Unit \ ef, design: Vec2.Vec2, plan: Render.PassPlan):
            Unit \ (ef + GameEngine.Game + ShaderEffect.Shader + RenderTarget.Target) =
        let pixelScale = RenderTarget.Target.pixelScale();
        List.forEach(p -> {
            let descriptor = Render.targetDescriptorOf(plan, p#name);
            let (tw, th) = RenderTarget.texelSizeOf(design, pixelScale, descriptor);
            RenderTarget.Target.beginTarget({ name = p#name, width = tw, height = th, format = descriptor#format, clear = p#clear,
                                              samples = RenderTarget.samplesOf(descriptor) });
            submitGpuItems(warnOnce, p#items, Nil, None);
            RenderTarget.Target.endTarget()
        }, plan#passes)

    /// Pass の計画を、本編より先に今の描き先へ描く（実機の毎コマと同じ道: resolvePassReads → 倍率 → drawShaders → renderCommands）。
    /// known = これまでに作ったターゲットの名前（コマをまたいで増える。実機の TileCache#passTargets と同じ役）。返すのは次の known。
    /// 実機の外で GL に描く所（VideoOut の GPU の道）が、App を持たずに同じ道を通るための口。
    /// warnOnce = 計画の問題・同じ z の並び・Param の渡し忘れの知らせ（毎コマ呼ばれるので、同じ字を 1 回にまとめるのは渡す側）。
    pub def drawPassPlan(warnOnce: String -> Unit \ ef, design: Vec2.Vec2, known: Set[String], plan: Render.PassPlan):
            Set[String] \ (ef + GameEngine.Game + ShaderEffect.Shader + RenderTarget.Target) =
        let resolved = notePassIssues(warnOnce, Render.resolvePassReads(known, plan));
        renderPasses(warnOnce, design, resolved);
        resolved#passes |> List.foldLeft((acc, p) -> Set.insert(p#name, acc), known)

    /// 計画の問題を知らせてから、書き換えた計画を返す。
    def notePassIssues(note: String -> Unit \ ef, resolved: { plan = Render.PassPlan, issues = List[Render.PassPlanIssue] }): Render.PassPlan \ ef =
        match resolved#issues |> List.forEach(issue -> note("[render] pass: ${passIssueText(issue)}")) {
            case () => resolved#plan
        }

    /// Pass の計画の問題 1 件の知らせの字。
    def passIssueText(issue: Render.PassPlanIssue): String = match issue {
        case Render.PassPlanIssue.ReadsLaterPass(pass, reads)        => "'${pass}' がまだ描いていない '${reads}' を読む — 黒になる（読む Pass を前に宣言する。前のコマが欲しいなら自分の名前を読む）"
        case Render.PassPlanIssue.ReadsUndeclaredTarget(pass, reads) => "'${pass}' がこのコマで宣言していない '${reads}' を読む — 黒になる"
        case Render.PassPlanIssue.DuplicatePass(name)                => "'${name}' を 2 回宣言した — 2 回目以降は描かない"
        case Render.PassPlanIssue.ReservedPassName(name)             => "'${name}' に '@' がある — 描かない（'@' は history の別名に使う）"
        case Render.PassPlanIssue.UnknownDescriptor(name)            => "targets の '${name}' に当たる Pass が無い — 倍率が効いていない"
        case Render.PassPlanIssue.ScaleOutOfRange(name, scale)       =>
            "targets の '${name}' の scale ${scale} は 0 より大きく 1 以下の外 — 1 として描く（画面の画素で描くなら RenderTarget.windowDescriptor()）"
    }
}
