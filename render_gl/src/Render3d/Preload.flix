// Render3d.Preload — 3D の描き手（Render3d）の、遊びの途中で初めて出る物（形・絵・材質のプログラム）を描く前に GPU へ上げる所。約束は Render3d.flix の頭。
mod Render3d.Preload {
    import fge.gl.GlContext
    use Render3d.{PreloadState, State, TextureRead, TextureSlot, TextureSource, isSkinned, materialTextureNames, meshEntry, programsOf, rebuildStreakLimit,
                  skinnedProgramsOf, warnSceneOnce}
    use Render3d.Batch.{MaterialBatch, PlannedBatch}
    use Render3d.Counts.{Phase, timed}
    use Render3d.Material.{isCoverageCutout, resolveTextureAs, splitByMaterial, textureSlotOf}

    /// 何も上げていない状態。
    pub def empty(): PreloadState =
        { builtKey = None, meshes = Set.empty(), programs = Set.empty(), textures = Set.empty(), rebuilds = Nil }

    /// 宣言 cmd の形と絵と材質のプログラムを上げる。最後に上げた宣言と同じ key なら何もしない（cmd の中身も読まない）。
    pub def upload(gl: GlContext, state: State, gen: Int64, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO,
                   cmd: Scene3d.PreloadCmd): Unit \ IO =
        if (Ref.get(state#preloadRef)#builtKey == Some(cmd#key)) ()
        else {
            let rebuilds = List.take(rebuildStreakLimit(), gen :: Ref.get(state#preloadRef)#rebuilds);
            if (isRebuildingOften(rebuilds)) warnSceneOnce(state, "@preload-key", "scene3d: withPreload3d の key が ${rebuildStreakLimit()} 回、${rebuildWindow()} コマの内に変わった"
                + " — そのたびに組み直している。key には、上げる物の中身を決める入力だけを入れる（時刻やコマの番号を混ぜない）")
            else ();
            let uploaded = timed(state, Phase.Preload, () -> uploadCmd(gl, state, gen, textureOf, cmd));
            Ref.put({ rebuilds = rebuilds | uploaded }, state#preloadRef)
        }

    /// 組み直しの回数を見るコマの幅。
    // WhyNot: uploadStreak のように続いたコマで数えない — key を 2 コマに 1 回変えるだけで続きが切れ、鳴らない。
    def rebuildWindow(): Int64 = 300i64

    /// rebuilds（新しい物が頭）が上限の数まで溜まり、一番古い物まで rebuildWindow() の内か。
    def isRebuildingOften(rebuilds: List[Int64]): Bool =
        List.length(rebuilds) >= rebuildStreakLimit() and (List.head(rebuilds) |> Option.getWithDefault(0i64)) - (List.last(rebuilds) |> Option.getWithDefault(0i64)) < rebuildWindow()

    /// cmd の置いた物を上げ、上げた物の控えを置き換えた状態を返す（前に上げた物は普通の物に戻る）。
    def uploadCmd(gl: GlContext, state: State, gen: Int64, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO,
                  cmd: Scene3d.PreloadCmd): PreloadState \ IO =
        let instances = (cmd#instances)();
        // WhyNot: 頂点の色のプログラムを最初の場面に任せない — 2D のタイトルの後の最初の 3D のコマで組むことになり、そのコマが跳ねる。
        if (List.isEmpty(instances)) () else discard programsOf(gl, state);
        let (plain, materials) = splitByMaterial(gl, state, gen, _ -> true, _ -> true, false, instances);
        let draws = List.append(plain, List.map(d -> d#batch, materials)) |> List.map(b -> b#head);
        if (List.exists(isSkinned, draws)) discard skinnedProgramsOf(gl, state) else ();
        draws |> List.forEach(d -> discard meshEntry(gl, state, gen, d#fields#mesh));
        let allMaterials = List.append(materials, coverageVersions(gl, state, gen, instances));
        let source = { textureOf = textureOf, own = (cmd#textures)() |> List.map(t -> (Texture3d.name(t), t)) |> List.toMap };
        { builtKey = Some(cmd#key), rebuilds = Nil, meshes = draws |> List.map(d -> Mesh3d.contentHash(d#fields#mesh)) |> List.toSet,
          programs = allMaterials |> List.map(d -> d#entry#locs#mesh#program) |> List.toSet,
          textures = allMaterials |> List.flatMap(d -> materialTextureNames(d#entry, d#material, d#batch#head)) |> List.toSet |> Set.toList |> uploadTextures(gl, state, gen, source) }

    /// cutout の材質の alpha to coverage の版を組む。
    // WhyNot: 版を描き先から選ばない — 描き先が標本を持つかは場面ごとに決まり、宣言の時には分からない。
    def coverageVersions(gl: GlContext, state: State, gen: Int64, instances: List[Scene3d.Instance3d]): List[MaterialBatch[PlannedBatch]] \ IO =
        if (not gl.hasAlphaToOne()) Nil
        else snd(splitByMaterial(gl, state, gen, _ -> true, _ -> true, true, List.filter(isCoverageInstance, instances)))

    def isCoverageInstance(i: Scene3d.Instance3d): Bool =
        Scene3d.instanceFieldsOf(i)#material |> Option.exists(m -> isCoverageCutout(true, Scene3d.materialFieldsOf(m)))

    /// reads の絵のうち source にある物を上げ、その置き場の鍵を返す。無い "tex3d:" の絵は名前ごとに 1 回知らせる。
    // WhyNot: 無い絵を resolveTextureAs へ渡さない — 「0 で読む」の知らせを鳴らすが、描くのはまだ先で、その時の場面の textures にはあるかもしれない。
    // WhyNot: 無い全体の登録の名前を知らせない — Pass の絵は、その Pass が初めて走るまで無いのが正常で、誤りに見える。
    def uploadTextures(gl: GlContext, state: State, gen: Int64, source: TextureSource, reads: List[TextureRead]): Set[TextureSlot] \ IO =
        reads |> List.foldLeft((held, read) -> {
            let (label, name, textureUse) = read;
            match textureSlotOf(source, name, textureUse) {
                case Some(slot) =>
                    discard resolveTextureAs(gl, state, gen, source, label, name, textureUse);
                    Set.insert(slot, held)
                case None =>
                    if (String.startsWith(prefix = Texture3d.namePrefix(), name))
                        warnSceneOnce(state, "preload:" + name, "scene3d: 先に上げる物の材質が読む絵 '${name}' が withPreload3d の textures に無い — 上げられない")
                    else ();
                    held
            }
        }, Set.empty())
}
