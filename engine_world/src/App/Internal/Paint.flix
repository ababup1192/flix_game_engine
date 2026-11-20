// App.Internal.Paint — World を 1 コマの絵にして描き手へ渡す所: カメラの確定・View と HUD の合成・タイル層と静的層・Pass・Shader 面と 3D の場面の振り分け・字の用意・絵の値段の知らせ。
// ゲームからは呼ばない（App の中身。ゲームの src・test で App.Internal. を書くと lint が止める）。
pub mod App.Internal.Paint {
    import java.lang.System

    /// withFonts で宣言された名前を先に全部引いておき、名前 → アトラスの純粋な引き当てを作る。
    /// view は純粋（ef）なので、その場で getFontAtlas を呼べない — ここで先に解いておく。
    /// 宣言していない名前は既定フォントへ落とす（字が消えるより既定で出るほうがよい）。
    def fontResolver(r: App.Rec[w, ef], dflt: FontAtlas): (String -> FontAtlas) \ Platform.GpuResources =
        let table = r#fonts |> List.foldLeft((acc, n) ->
            Map.insert(n, Platform.GpuResources.getFontAtlas(n), acc),
            (Map.empty(): Map[String, FontAtlas]));
        name -> Map.get(name, table) |> Option.getWithDefault(dflt)

    /// world から画面に出す絵一式を組む（実機の字のフォントで buildSceneItems）。diagnostics は前のフレームの診断で、
    /// view・hudView・視差レイヤの ViewCtx#diagnostics に入る。F8 スクラブ中は「表示中の瞬間」の World を渡すこと — 現在の world を
    /// 渡すと絵は過去・カメラは現在のズレた画面になり、注釈の当たり判定も全部ずれる。
    pub def sceneItems(app: App[w, ef], design: Vec2.Vec2, display: Display.Display, atlas: FontAtlas, warnOnce: String -> Unit,
                       diagnostics: Option[FrameDiagnostics.Diagnostics], world: w,
                       toItems: (App.ViewCtx, w) -> List[Render.PlacedItem] \ ef):
            List[Render.PlacedItem] \ (ef + Platform.GpuResources) =
        App.buildSceneItems(app, design, baseCtx(app, design, display, atlas, warnOnce, diagnostics), world, toItems)

    /// view・hudView に渡す ViewCtx の元（visible は層ごとに置き換わる）。
    def baseCtx(app: App[w, ef], design: Vec2.Vec2, display: Display.Display, atlas: FontAtlas, warnOnce: String -> Unit,
                diagnostics: Option[FrameDiagnostics.Diagnostics]): App.ViewCtx \ Platform.GpuResources =
        { atlas = atlas, fontOf = fontResolver(App.rec(app), atlas),
          visible = App.visibleOf(None, 1.0, design), warnOnce = warnOnce, diagnostics = diagnostics, display = display }

    /// view・視差レイヤの絵に camera を掛けた物（world）と、HUD の範囲へ持ち上げた hudView の絵（hud）。
    /// base の visible は層ごとに見えている矩形へ置き換わり、ほかの欄（字・知らせ・診断）はどの層にも同じ値で渡る。
    pub def sceneLayers(app: App[w, ef], design: Vec2.Vec2, base: App.ViewCtx, world: w,
                        toItems: (App.ViewCtx, w) -> List[Render.PlacedItem] \ ef): { world = List[Render.PlacedItem], hud = List[Render.PlacedItem] } \ ef =
        let r = App.rec(app);
        let (center, z) = resolvedCamera(r, world, design);
        let hud = match r#hudView {
            case None    => Nil
            // HUD は画面固定なので、見えている矩形は常に design 全体（原点起点）で zoom も掛けない。
            case Some(h) => h({ visible = App.visibleOf(None, 1.0, design) | base }, world)
        };
        // 視差レイヤ: 見かけの center（parallaxCenter）で culling も合成も行う。hud は混ぜない。
        let layers = r#parallaxLayers |> List.flatMap(fl -> {
            let (factor, lview) = fl;
            let lcenter = Option.map(c -> CameraRig.parallaxCenter(factor, c, design = design), center);
            App.composeScene(lcenter, z, design, { world = lview({ visible = App.visibleOf(lcenter, z, design) | base }, world), hud = Nil })
        });
        let ctx = { visible = App.visibleOf(center, z, design) | base };
        { world = List.append(layers, App.composeScene(center, z, design, { world = toItems(ctx, world), hud = Nil })),
          hud = App.composeScene(None, 1.0, design, { world = Nil, hud = hud }) }

    /// 1 コマの Pass の計画と画面の絵（App.buildFrame の中身）。withPostStack があれば world を後がけの Pass へ回し、
    /// 画面には後がけの面と HUD を置く。計画の名前が重なれば後がけを掛けずに 1 行知らせる。
    pub def buildFrame(app: App[w, ef], design: Vec2.Vec2, base: App.ViewCtx, world: w,
                    toItems: (App.ViewCtx, w) -> List[Render.PlacedItem] \ ef): { plan = Render.PassPlan, items = List[Render.PlacedItem] } \ ef =
        let r = App.rec(app);
        let layers = sceneLayers(app, design, base, world, toItems);
        let gamePlan = (r#passes)(world);
        let plain = { plan = gamePlan, items = List.append(layers#world, layers#hud) };
        match r#postStack {
            case None    => plain
            case Some(f) =>
                let stack = PostStack.resolveQuality(base#display#sizeClass, f(world));
                let built = PostStack.build({ size = design, clear = PostStack.backgroundOf(stack) |> Option.getWithDefault(r#screenClear), world = layers#world }, stack);
                let reserved = gamePlan#passes |> List.filter(p -> String.startsWith(prefix = PostStack.reservedPrefix(), p#name))
                    |> List.map(p -> "[post] withPassPlan の Pass '${p#name}' が ps_ で始まる（ps_ は PostStack の Pass。名前を替える）");
                let noted = List.append(built#issues |> List.map(issue -> "[post] ${PostStack.issueText(issue)}"), reserved) |> List.forEach(base#warnOnce);
                match (noted, Render.mergePassPlans(gamePlan, built#plan)) {
                    case ((), Ok(plan))     => { plan = plan, items = built#present :: layers#hud }
                    case ((), Err(clashes)) =>
                        match clashes |> List.forEach(c -> base#warnOnce("[post] withPassPlan の Pass と名前が重なる（${c}）— 後がけを掛けない")) {
                            case () => plain
                        }
                }
        }

    /// 生成したアトラスを描画部へ渡しておく（同じ key の間は何も起きない）。
    /// 同じ名前が 2 つ来たら後の方だけを使う — 両方渡すと毎フレーム key が入れ替わり、
    /// 大きさが違えば 1 枚ずつ GPU に置き去りになる。
    def uploadAtlases(uploads: List[App.AtlasUpload]): Unit \ Platform.GpuResources =
        uploads
            |> List.foldLeft((acc, a) -> Map.insert(a#texture, a, acc), Map.empty())
            |> Map.forEach((_, a) ->
                if (a#baked#side > 0)
                    Platform.GpuResources.ensureTexture(a#texture, a#key,
                        a#baked#side, a#baked#side, a#baked#pixels)
                else ())

    /// debug 有効時だけ、画面右上に小さく fps を出す絵を組む（無効なら空 = 本番に一切出ない）。
    /// fps 表示は withView を使うゲームのみ（view = None の自前描画ゲームには出ない）—
    /// renderFrame が App の絵を描かない構成では、ここで組んでも捨てられるだけなので組まない。
    /// 字はゲームのフォントではなく組み込みフォントで出す — ゲームごとにフォント名が違い、
    /// 特定の名前を当てにすると名前が違うゲームで fps 表示が出せなくなる。
    pub def fpsOverlayOf(r: App.Rec[w, ef], design: Vec2.Vec2, anno: Annotate.State): List[Render.PlacedItem] \ Platform.GpuResources =
        if (not r#debug or Option.isEmpty(r#view)) Nil
        else {
            let atlas = Platform.GpuResources.getFontAtlas(BootFont.name());
            // 組み込みフォントはドット絵なので、作った大きさの等倍で出す。
            Annotate.fpsItems(atlas, atlas#fontSize, design, Annotate.fpsOf(anno))
        }

    /// App が待っている間の表示（withLoadingIndicator の答え）。待っていなければ空。Custom はゲームの View と同じ ViewCtx で、待ちの間は毎コマ呼ぶ。
    pub def loadingOverlayOf(app: App[w, ef], warnOnce: String -> Unit, design: Vec2.Vec2, display: Display.Display,
                             wait: Option[LoadProgress.LoadWait], press: Option[Vec2.Vec2]): List[Render.PlacedItem] \ Platform.GpuResources =
        match (App.rec(app)#loadingIndicator, wait) {
            case (_, None)                                   => Nil
            case (App.LoadingIndicator.Hidden, _)            => Nil
            case (App.LoadingIndicator.Default, Some(lw))    => App.Internal.LoadingView.itemsOf(design, lw, press)
            case (App.LoadingIndicator.Custom(f), Some(lw))  =>
                f(baseCtx(app, design, display, Platform.GpuResources.getFontAtlas("default"), warnOnce, None), lw)
        }

    /// 静的レイヤーを通常の動的アイテムとして描くための PlacedItem 列（F8 のズーム・パン中と、注釈の書き出し）。
    /// build（ワールド座標）に主 view と同じ camera（resolvedCamera → composeScene）を掛けて、
    /// 動的な絵と重なり順・位置を揃える。静的レイヤーが無ければ空。
    pub def staticPausedItems(app: App[w, ef], design: Vec2.Vec2, world: w): List[Render.PlacedItem] \ ef =
        let r = App.rec(app);
        match r#staticLayer {
            case None    => Nil
            case Some(sl) =>
                let (center, z) = resolvedCamera(r, world, design);
                App.composeScene(center, z, design, { world = (sl#build)(world), hud = Nil })
        }

    /// 静的レイヤー（withStaticLayer）を、この World の camera から解決した描画依頼にする。
    /// key と polys（build → Render.draw の多角形チャンネル）はエンジンがキャッシュに使い、
    /// viewOffset/viewScale/halfDesign は動的な絵と同じ camera 値（resolvedCamera）から出すので、
    /// 静的な絵と動的な絵の視点は 1px もずれない。カメラ無しなら恒等（world 座標そのまま）。
    /// polys は build（純粋）だけを包むので、キャッシュヒット時に呼ばれても副作用は無い。
    def staticLayerCmd(app: App[w, ef], design: Vec2.Vec2, world: w): Option[GameEngine.StaticLayerCmd] \ ef =
        let r = App.rec(app);
        match r#staticLayer {
            case None    => None
            case Some(sl) =>
                let (center, z) = resolvedCamera(r, world, design);
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

    /// camera 無しでも zoom があれば「画面中央の world 点 = design/2」を軸に据える正規化。
    /// App.composeScene・App.visibleOf・resolvedCamera が同じ規則を共有するための 1 点
    /// （NaN も 1.0 と等しくないので Some 側へ落ち、下流の safeZoom が丸める）。
    pub def zoomedCenter(center: Option[Vec2.Vec2], zoom: Float64, design: Vec2.Vec2): Option[Vec2.Vec2] =
        match center {
            case Some(c) => Some(c)
            case None    => if (zoom != 1.0) Some(Vec2.div(design, 2.0)) else None
        }

    /// 先に上げる物の宣言（withPreload3d）を、この World の頼みにする。ゲームの key に Doc の世代 docGen と変種の字を足すので、読み直しと変種が替わるたびに組み直す。
    /// instances と textures は包むだけで、ここでは読まない（variants は毎コマ読む。短い列）。
    pub def preloadCmd(app: App[w, ef], docGen: Int32, world: w): Option[Scene3d.PreloadCmd] =
        App.rec(app)#preload3d |> Option.map(plan -> {
            let variants = (plan#variants)(world);
            let variantKey = if (List.isEmpty(variants)) "" else (variants |> List.map(Scene3d.preloadVariantKey) |> String.intercalate(",")) + ":";
            { key = "${docGen}:${variantKey}" + (plan#key)(world), instances = () -> (plan#instances)(world), textures = () -> (plan#textures)(world),
              variants = variants }
        })

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
    def tileLayerCmds(app: App[w, ef], design: Vec2.Vec2, world: w, specs: List[TileLayerSpec], cache: TileCache):
            (List[GameEngine.TileMapRenderCmd], TileCache) \ (ef + Platform.GpuResources) =
        let r = App.rec(app);
        match specs {
            case Nil => (Nil, cache)
            case _   =>
                let (center, z) = resolvedCamera(r, world, design);
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
                                case Some(v) => Platform.GpuResources.updateTileBuffer(v, instances)
                                case None    => Platform.GpuResources.initTileBuffer(instances)
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
                }, ((Nil: List[GameEngine.TileMapRenderCmd]), cache), List.zipWithIndex(specs));
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
                let (center, z) = resolvedCamera(r, world, design);
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
            Unit \ (ef + Platform.Rendering) =
        let sceneCmds = Render.drawScenes3d(items);
        let shaderCmds = noteSurfaceZ(warnOnce, items, sceneCmds,
            Render.drawShaders(spec -> Platform.GpuResources.buildProgram(spec), items));
        List.forEach(cmd -> Platform.Draw2d.drawSurface(cmd), shaderCmds);
        List.forEach(cmd -> Platform.Draw3d.drawScene3d(cmd), sceneCmds);
        let withoutSurfaces = if (List.isEmpty(shaderCmds)) items else Render.withoutShaders(items);
        let itemsToDraw = if (List.isEmpty(sceneCmds)) withoutSurfaces else Render.withoutScenes3d(withoutSurfaces);
        // drawWith(getTextureInfo): regionRect 付き Sprite（PxSprite.drawQuad のアトラス 1 クアッド等）の UV を
        // registry の寸法で解決する。regionRect 無しの絵は draw と同一の Drawable になる。
        let (sprites, polygons) = Render.drawWith(name -> Platform.GpuResources.getTextureInfo(name), itemsToDraw);
        Platform.Draw2d.renderCommands(sprites, tiles, polygons, staticLayer)

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
    /// 宣言があるときだけ生成して添える（持ち回しの TileCache を返す）。画面へ出す（presentFrame）のは呼ぶ側。
    /// view = None のゲームは App では描かない（camera / hudView もこの場合は効かない。系は純粋なので、系から描く手段も無い）。
    /// fps は debug 有効時だけ隅に重ねる（本番は Nil を渡すので描画に一切現れない）。
    /// diagnostics は view・hudView の ViewCtx#diagnostics へ渡す前のフレームの診断（実機の道だけ Some になりうる）。
    pub def renderFrame(app: App[w, ef], warnOnce: String -> Unit, diagnostics: Option[FrameDiagnostics.Diagnostics],
                        design: Vec2.Vec2, display: Display.Display, world: w, look: Look,
                        tileCache: TileCache, glyphSeen: Option[Int64], budgetWarned: Bool):
            (TileCache, Option[Int64], Bool) \ (ef + Platform.Rendering + RenderTarget.Target + IO) =
        let built = buildPainted(app, warnOnce, diagnostics, design, display, world, look, tileCache);
        submitPainted(app, warnOnce, design, world, built, tileCache, glyphSeen, budgetWarned)

    /// 1 コマの組み立ての結果（GPU に触らずに作った物）。submitPainted がそのまま描き手へ渡す。
    /// items = 画面の絵（見え方と重ね物を掛けた後）・plan = 計画の問題を直した Pass の列・letterbox = 余りへ塗る絵（余りの無いコマは None）・
    /// tiles = タイル層の宣言（見え方が等倍の時だけ）・retained = 見え方が等倍か（タイル層と静的層を GPU の道で描くか）。
    pub type alias Built = { items = List[Render.PlacedItem], plan = Render.PassPlan, letterbox = Option[List[Render.PlacedItem]],
                             tiles = List[TileLayerSpec], retained = Bool }

    /// 組み立てた 1 コマが名前で引く絵とフォント（画面・Pass の中・余りの絵・タイル層のアトラス）。3D の場面の中は数えない。
    pub def assetNamesOf(built: Built): Set[String] =
        let passItems = built#plan#passes |> List.flatMap(p -> p#items);
        let tileNames = built#tiles |> List.map(spec -> spec#tileSet#atlasSource#textureName) |> List.toSet;
        Set.union(tileNames, Render.assetNames(List.append(List.append(passItems, Option.getWithDefault(Nil, built#letterbox)), built#items)))

    /// world から 1 コマを組む（GPU に触らない。字のアトラスは引くだけ）。view = None のゲームは None。
    /// 計画の問題の知らせはここで出す。
    pub def buildPainted(app: App[w, ef], warnOnce: String -> Unit, diagnostics: Option[FrameDiagnostics.Diagnostics],
                         design: Vec2.Vec2, display: Display.Display, world: w, look: Look, tileCache: TileCache):
            Option[Built] \ (ef + Platform.GpuResources) =
        let r = App.rec(app);
        r#view |> Option.map(toItems -> {
            let atlas = Platform.GpuResources.getFontAtlas("default");
            let ctx = baseCtx(app, design, display, atlas, warnOnce, diagnostics);
            let frame = buildFrame(app, design, ctx, world, toItems);
            let plan = notePassIssues(warnOnce, Render.resolvePassReads(tileCache#passTargets, frame#plan));
            let letterboxItems = letterboxItemsOf(app, design, ctx, world);
            // タイル層と静的層は GPU 側でカメラを掛けるので、見え方（F8 のズーム・パン）を掛けられない。
            // 見え方が等倍でない間だけ、ほかの絵と同じ PlacedItem に直して一緒に掛ける。
            let retained = Annotate.isIdentity(look#view);
            let scene = frame#items;
            let base = if (retained) scene
                       else List.append(tilePausedItems(app, design, world),
                                        List.append(scene, staticPausedItems(app, design, world)));
            let inspected = Annotate.applyInspectItems(look#view,
                if (List.isEmpty(look#inspected)) base else List.append(base, look#inspected));
            // fixed は本番ビルドで Nil — 空の append で本編全件を cons し直さない。
            let items = if (List.isEmpty(look#fixed)) inspected else List.append(inspected, look#fixed);
            let tiles = if (retained) (r#tileLayers |> Option.map(f -> f(world)) |> Option.getWithDefault(Nil)) else Nil;
            { items = items, plan = plan, letterbox = letterboxItems, tiles = tiles, retained = retained }
        })

    /// buildPainted で組んだ 1 コマを描き手へ渡す（アトラスの上げ・先に上げる 3D・Pass・余り・字の用意・タイル層・本編の順）。
    /// 画面へ出す（presentFrame）のは呼ぶ側。built が None（view = None）なら何もしない。
    pub def submitPainted(app: App[w, ef], warnOnce: String -> Unit, design: Vec2.Vec2, world: w, built: Option[Built],
                          tileCache: TileCache, glyphSeen: Option[Int64], budgetWarned: Bool):
            (TileCache, Option[Int64], Bool) \ (ef + Platform.Rendering + RenderTarget.Target + IO) =
        let r = App.rec(app);
        match built {
            case None        => (tileCache, glyphSeen, budgetWarned)
            case Some(frame) =>
                uploadAtlases((r#spriteAtlases)(world));
                preloadCmd(app, tileCache#gen, world) |> Option.forEach(cmd -> Platform.Draw3d.preload3d(cmd));
                let passList = frame#plan#passes;
                renderPasses(warnOnce, design, frame#plan);
                Option.forEach(drawLetterbox(warnOnce, design), frame#letterbox);
                let letterboxItems = Option.getWithDefault(Nil, frame#letterbox);
                let cacheSeen = { passTargets = passList |> List.foldLeft((acc, p) -> Set.insert(p#name, acc), tileCache#passTargets)
                                  | tileCache };
                let retained = frame#retained;
                let items = frame#items;
                // 字の欠け照合はレンダーターゲットの中の字も一緒に見る（ターゲットも本編と
                // 同じ「初めて出る字は 1 コマ遅れる」に乗せる）。
                let itemsForGlyphs = List.append(List.append(List.flatMap(p -> p#items, passList), letterboxItems), items);
                // アトラスに無い字があれば、描く前に用意してもらう（初めて出る字は 1 コマ遅れる）。
                // たいていは空振りで、そのときは何も起きない。glyphSeen は「欠けが無かった
                // フレームの字の指紋」— 同じ指紋の間は 1 字ずつの照合を引き直さない。
                // アトラスは ensureGlyphs でしか育たず、育つのは欠けが出たフレームだけなので、
                // 欠けゼロの指紋を覚えても古い答えを返す余地が無い。欠けが出たフレームは
                // 覚えない（作った直後にアトラスが育ち、同じ字でも答えが変わるため）。
                let fp = Render.glyphFingerprint(itemsForGlyphs);
                let nextSeen = if (glyphSeen == Some(fp)) glyphSeen else {
                    let missing = Render.missingGlyphs(itemsForGlyphs);
                    Map.forEach((textureName, cps) -> Platform.GpuResources.ensureGlyphs(textureName, cps),
                                missing);
                    if (Map.isEmpty(missing)) Some(fp) else None
                };
                // 面と 3D の場面は別チャンネル（Platform.Draw2d.drawSurface・Platform.Draw3d.drawScene3d）へ積み、残りの 2D と一緒に描き手が z で合流させる。
                let (tileCmds, nextCache) = if (retained) tileLayerCmds(app, design, world, frame#tiles, cacheSeen) else (Nil, cacheSeen);
                submitGpuItems(warnOnce, items, tileCmds, if (retained) staticLayerCmd(app, design, world) else None);
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
    /// tileCache は同じ GL の文脈の間で持ち回す（最初は freshTileCache()）。画面へは出さない（読み戻すのは呼ぶ側）。
    pub def paintOnce(app: App[w, ef], world: w, tileCache: TileCache):
            TileCache \ (ef + Platform.Rendering + Platform.Window + RenderTarget.Target + IO) =
        let design = Platform.Window.getViewportRect()#size;
        let display = Platform.Window.getDisplay();
        def go(cache, left) = {
            let (next, seen, _) = renderFrame(app, _ -> (), None, design, display, world, plainLook(Nil), cache, None, true);
            if (Option.isEmpty(seen) and left > 1) go(next, left - 1) else next
        };
        go(tileCache, 3)

    /// レンダーターゲットの列を本編より先に描く（宣言順・resolvePassReads を通した後の計画）。ターゲットの中は
    /// design 座標そのままで、Shader 面と 3D の場面も本編と同じ道（submitGpuItems）で描く。
    /// テクセル寸法は RenderTarget.texelSizeOf（名前の作り方と、描き手の画素の倍率 Target.pixelScale）。
    def renderPasses(warnOnce: String -> Unit \ ef, design: Vec2.Vec2, plan: Render.PassPlan):
            Unit \ (ef + Platform.Rendering + RenderTarget.Target) =
        let pixelScale = RenderTarget.Target.pixelScale();
        List.forEach(p -> {
            let descriptor = Render.targetDescriptorOf(plan, p#name);
            let (tw, th) = RenderTarget.texelSizeOf(design, pixelScale, descriptor);
            RenderTarget.Target.beginTarget({ name = p#name, width = tw, height = th, format = descriptor#format, clear = p#clear,
                                              samples = RenderTarget.samplesOf(descriptor) });
            submitGpuItems(warnOnce, p#items, Nil, None);
            RenderTarget.Target.endTarget()
        }, plan#passes)

    /// withLetterboxView があり窓に余りがあれば、その絵（字の用意と絵の値段に数える）。余りの無いコマは None。
    def letterboxItemsOf(app: App[w, ef], design: Vec2.Vec2, base: App.ViewCtx, world: w): Option[List[Render.PlacedItem]] \ ef =
        match App.rec(app)#letterboxView {
            case Some(v) if isLetterboxed(base#display, design) =>
                Some(App.composeScene(None, 1.0, design, { world = v({ visible = App.visibleOf(None, 1.0, design) | base }, world), hud = Nil }))
            case _ => None
        }

    /// 余りの絵を Pass（letterboxTarget。design の 1/4 の画素）へ描き、次の画面のコマで余りへ広げて塗るよう描き手に頼む
    /// （Platform.Draw2d.fillLetterbox）。
    // WhyNot: テクセルを design の大きさにしない — 余りは窓いっぱいに広げてぼかして見せる所で、小さく描いて 2 つの画素の間をなめらかにつないで広げる方が
    //   ぼけが強く、ぼかしの shader を塗る画素も 1/16 で済む。
    def drawLetterbox(warnOnce: String -> Unit, design: Vec2.Vec2, items: List[Render.PlacedItem]):
            Unit \ (Platform.Rendering + RenderTarget.Target) =
        let size = n -> Int32.max(1, Float64.tryToInt32(Float64.round(n)) |> Option.getWithDefault(1));
        RenderTarget.Target.beginTarget({ name = letterboxTarget(), width = size(design#x / 4.0), height = size(design#y / 4.0),
                                          format = RenderTarget.Format.Rgba8Unorm, clear = RenderTarget.LoadOp.Clear({ r = 0.0, g = 0.0, b = 0.0 }),
                                          samples = 1 });
        submitGpuItems(warnOnce, items, Nil, None);
        RenderTarget.Target.endTarget();
        Platform.Draw2d.fillLetterbox(letterboxTarget())

    /// withLetterboxView の絵を描く Pass の名前。
    pub def letterboxTarget(): String = "fge_letterbox"

    /// 窓の大きさ display#size と design の縦横比が、余りの出るほど違うか（幅と高さの比で 0.5% より大きく違う時）。
    pub def isLetterboxed(display: Display.Display, design: Vec2.Vec2): Bool =
        if (display#size#x <= 0.0 or display#size#y <= 0.0 or design#x <= 0.0 or design#y <= 0.0) false
        else {
            let window = display#size#x / display#size#y;
            let wanted = design#x / design#y;
            Float64.abs(window - wanted) > wanted * 0.005
        }

    /// Pass の計画を、本編より先に今の描き先へ描く（実機の毎コマと同じ道: resolvePassReads → 倍率 → drawShaders → renderCommands）。
    /// known = これまでに作ったターゲットの名前（コマをまたいで増える。実機の TileCache#passTargets と同じ役）。返すのは次の known。
    /// 実機の外で GL に描く所（VideoOut の GPU の道）が、App を持たずに同じ道を通るための口。
    /// warnOnce = 計画の問題・同じ z の並び・Param の渡し忘れの知らせ（毎コマ呼ばれるので、同じ字を 1 回にまとめるのは渡す側）。
    pub def drawPassPlan(warnOnce: String -> Unit \ ef, design: Vec2.Vec2, known: Set[String], plan: Render.PassPlan):
            Set[String] \ (ef + Platform.Rendering + RenderTarget.Target) =
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

    /// 確定した camera（中心と zoom）を World から 1 回だけ導く: zoom-only の正規化
    /// （zoomedCenter）→ cameraBounds クランプ。主 view と静的レイヤーがこの同じ値から
    /// 派生するので、動的な絵と静的な絵の視点が必ず一致する（1px もずれない）。
    pub def resolvedCamera(r: App.Rec[w, ef], world: w, design: Vec2.Vec2): (Option[Vec2.Vec2], Float64) \ ef =
        let z = match r#zoom {
            case None    => 1.0
            case Some(f) => f(world)
        };
        let center0 = match r#camera {
            case Some(f) => Some(f(world))
            case None    => None
        };
        let center = match (zoomedCenter(center0, z, design), r#cameraBounds) {
            case (Some(c), Some(fb)) =>
                let seen = Vec2.div(design, CameraRig.safeZoom(z));
                Some(CameraRig.clampCenter(bounds = fb(world), seen = seen, c))
            case (c, _) => c
        };
        // 画素の升目に吸着させる（静的な絵と動く絵が同じ値を見るので、両者はずれない）。
        let snap = (r#pixelSnap)(world);
        // 画面の画素に載せたいので、zoom を掛けた後の値で丸める（world 座標で丸めるだけでは
        // zoom が整数でないときに半画素ずれが残る）。
        let unit = snap * CameraRig.safeZoom(z);
        let snapped = if (not Float64.isFinite(unit) or unit <= 0.0) center
                      else Option.map(c -> { x = Float64.round(c#x * CameraRig.safeZoom(z)) / CameraRig.safeZoom(z),
                                             y = Float64.round(c#y * CameraRig.safeZoom(z)) / CameraRig.safeZoom(z) }, center);
        (snapped, z)
}
