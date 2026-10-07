// PxSprite — PxSpriteDoc(文字格子)を PlacedItem の列に描く(第一段: box 列)。
// 1 文字 = scale×scale の矩形。横に連続する同色キーの文字は 1 つの矩形へ結合して
// 数を減らす(被覆する面積と最終色は結合前と同一 — 格子はセル重なりを持たないので、
// どう矩形に分けても画素は変わらない)。
// 規約:
//   - legend に無い文字は透明(fail-open)。スプライト名・コマ名が無ければ何も描かない。
//   - anchor: 格子内の基準セル。draw の at がこのセルの左上に来る。
//   - flipX: コマの枠の中で列を左右入れ替える。枠は動かないので、覆う矩形は反転の有無で同じ。
//     anchor を軸に鏡にすると、anchor が端にある絵（既定の (0,0) がそれ）は反転で幅ぶん
//     横へ飛び、呼び手全員が幅を足し戻す羽目になる。握るところを追いたい呼び手は
//     anchorOffsetOf と、反転後の anchor 列（cols-1-anchor#x）から自分で組む。
//   - scale は整数のみ(NEAREST 前提)。0 以下は何も描かない。
//   - 色は resolver(意味色キー → 実色)が解決する。テーマ替え・個体差(体色)は
//     resolver の差し替えで行い、格子は共有する。
pub mod PxSprite {

    /// 結合済みの矩形 1 個(セル単位を px へ展開済み・key は未解決の意味色キー)。
    pub type alias Run = { x = Float64, y = Float64, w = Float64, h = Float64, key = String }

    /// コマを描く。出力は box(軸に平行な矩形)の列 — 呼び手の z にすべて載る。
    /// 多角形ではなく box で出すのが要点: 走る画素は必ず軸に平行な矩形なので、
    /// 多角形として出すと描画部が毎フレーム三角形へ割り直すことになる。
    /// 1 体で数十、草を撒けば数千の矩形が出るので、この差がそのまま 1 秒あたりのコマ数に効く。
    pub def draw(doc: PxSpriteDoc.Doc, sprite: String, frame: String, at: Vec2.Vec2,
                 flipX: Bool, scale: Int32, resolver: String -> Color, z: Int32): List[Render.PlacedItem] =
        runs(doc, sprite, frame, at, flipX, scale)
            |> List.map(r ->
                { at = { x = r#x, y = r#y },
                  item = RawDraw.box({ x = r#w, y = r#h }, resolver(r#key), z) })

    /// コマを「アトラス 1 クアッド」で描く(opt-in の GL 実行時最適化)。
    /// baked(PxSpriteAtlas.bake 済み)の regionRect を貼った Item.Sprite 1 個を返す —
    /// box 列(draw)と同じ画素を被覆する(NEAREST・整数 scale・色は argbOf で同一丸め)。
    /// texture はアトラスを登録した論理名(GL は TextureRegistry、SoftRaster は texturePath の鍵)。
    /// 注意: regionRect 付き Sprite は Render.drawWith(textureInfoOf)経路でだけ解決される。
    /// 既定の box 列と違い tint/blend は持たない最小形 — 必要なら呼び手がパイプ修飾で足す。
    pub def drawQuad(doc: PxSpriteDoc.Doc, baked: PxSpriteAtlas.Baked, texture: String,
                     sprite: String, frame: String, at: Vec2.Vec2,
                     flipX: Bool, scale: Int32, z: Int32): List[Render.PlacedItem] =
        if (scale <= 0 or baked#side <= 0) Nil
        else match (Map.get(sprite, doc#sprites), PxSpriteAtlas.regionOf(baked, sprite, frame)) {
            case (Some(sp), Some(rect)) => {
                let s = Int32.toFloat64(scale);
                let sideF = Int32.toFloat64(baked#side);
                let ax = sp#anchor#x;
                let ay = sp#anchor#y;
                // 置き場所の規約は draw(box 列)と同一: 「anchor セルの左上 = at」。
                // flipX は Item.Sprite の flipH(scale 符号)で行うが、レンダラは覆う矩形を
                // pos から正の向きへ伸ばすので、反転してもここは同じ式でよい。
                let pos: Vec2.Vec2 = { x = at#x - ax * s, y = at#y - ay * s };
                { at = pos,
                  item = Render.Item.Sprite({
                      texture = texture,
                      tint = { r = 1.0, g = 1.0, b = 1.0 },
                      alpha = 1.0,
                      // Drawable の表示寸法 = テクスチャ全寸 × scale なので、
                      // 「コマ px × 整数 scale」になるよう辺長で割り戻す。
                      scale = { x = s * rect#size#x / sideF, y = s * rect#size#y / sideF },
                      rotation = 0.0, centered = false,
                      flipH = flipX, flipV = false,
                      regionRect = Some(rect), zIndex = z,
                      blend = DrawCmd.BlendMode.Normal, maskPolys = Nil }) } :: Nil
            }
            case _ => Nil
        }

    /// draw の座標計算だけ(テストと当たり判定用)。矩形は行ごと・左から右の順。
    pub def runs(doc: PxSpriteDoc.Doc, sprite: String, frame: String, at: Vec2.Vec2,
                 flipX: Bool, scale: Int32): List[Run] =
        if (scale <= 0) Nil
        else match Map.get(sprite, doc#sprites) {
            case None     => Nil
            case Some(sp) => match Map.get(frame, sp#frames) {
                case None       => Nil
                case Some(rows) => {
                    let s = Int32.toFloat64(scale);
                    let ax = sp#anchor#x;
                    let ay = sp#anchor#y;
                    // 鏡の軸はコマの枠（一番長い行の幅）。行ごとの長さで測ると、右が空いた
                    // 短い行だけ別の量だけ動いて絵が割れる。
                    let cols = Int32.toFloat64(Grid.dimsOfRows(rows)#cols);
                    rows |> List.zipWithIndex |> List.flatMap(entry -> {
                        let (r, row) = entry;
                        let y = at#y + (Int32.toFloat64(r) - ay) * s;
                        rowRuns(doc#legend, row) |> List.map(rn -> {
                            let (c0, n, key) = rn;
                            let x = if (flipX)
                                    at#x + (cols - Int32.toFloat64(c0 + n) - ax) * s
                                else at#x + (Int32.toFloat64(c0) - ax) * s;
                            ({ x = x, y = y, w = Int32.toFloat64(n) * s, h = s, key = key }: Run)
                        })
                    })
                }
            }
        }

    /// 絵の真ん中から anchor（握るところ）へ向かうベクトル（px）。
    /// コマを描いたときの大きさ（px）。そのスプライト・そのコマが無ければ None。
    /// 当たり判定・置き場所・並べる間隔を絵に追随させたいときの唯一の入口 —
    /// 固定値で持つと、絵を描き替えたときに絵と当たりが静かにズレる。
    pub def sizeOf(doc: PxSpriteDoc.Doc, sprite: String, frame: String,
                   scale: Int32): Option[Vec2.Vec2] =
        PxSpriteDoc.gridSizeOf(doc, sprite, frame)
            |> Option.map(g -> {
                let s = Int32.toFloat64(scale);
                ({ x = Int32.toFloat64(g#cols) * s, y = Int32.toFloat64(g#rows) * s }: Vec2.Vec2)
            })

    /// 置き方の規約（anchor セルの左上 = at）はここが唯一の持ち主 — 呼び側で同じ計算を
    /// 書き直すと、規約を直したときに気付かないまま食い違う。
    /// 反転しても枠は動かないので、この値は flipX に依らない。
    pub def anchorOffsetOf(doc: PxSpriteDoc.Doc, sprite: String, frame: String,
                           scale: Int32): Vec2.Vec2 =
        match Map.get(sprite, doc#sprites) {
            case None     => Vec2.zero()
            case Some(sp) => {
                let rows = Map.get(frame, sp#frames) |> Option.getWithDefault(Nil);
                let s = Int32.toFloat64(scale);
                let dims = Grid.dimsOfRows(rows);
                let cols = Int32.toFloat64(dims#cols);
                let height = Int32.toFloat64(dims#rows);
                { x = sp#anchor#x * s - cols * s / 2.0,
                  y = sp#anchor#y * s - height * s / 2.0 }
            }
        }

    /// anchor（握るところ）を軸に turn（1 周 = 1.0）だけ回して、アトラスの 1 クアッドで描く。
    ///
    /// 絵は「自分の真ん中」で回るので、anchor が真ん中でない絵をそのまま回すと anchor が
    /// 指した点から離れていく（振り上げた道具が手から飛んでいく）。そこで「回したあとに
    /// anchor がちょうど at へ来る」置き場所を先に逆算する: 真ん中から anchor へのベクトルを
    /// 回した差ぶんだけ、置き場所をずらせばよい。
    pub def drawQuadTurned(spec: { doc = PxSpriteDoc.Doc, baked = PxSpriteAtlas.Baked,
                                   texture = String, sprite = String, frame = String,
                                   at = Vec2.Vec2, flipX = Bool, scale = Int32,
                                   turn = Float64, z = Int32 }): List[Render.PlacedItem] =
        let quad = at -> drawQuad(spec#doc, spec#baked, spec#texture, spec#sprite, spec#frame,
                                  at, spec#flipX, spec#scale, spec#z);
        if (Float64.abs(spec#turn) < 0.0001) quad(spec#at)
        else {
            let a = anchorOffsetOf(spec#doc, spec#sprite, spec#frame, spec#scale);
            let spun = Render.rotated(spec#turn, a :: Nil) |> List.head |> Option.getWithDefault(a);
            quad(Vec2.add(spec#at, Vec2.sub(a, spun)))
                |> List.map(p -> { item = Render.turned(spec#turn, p#item) | p })
        }

    /// 文字格子の左上を at に置いて、アトラスの 1 クアッドで描く。
    /// anchor がどこにあっても左上でそろうので、道具のアイコンや一覧のように「枠に並べる」用途に向く。
    pub def drawQuadTopLeft(spec: { doc = PxSpriteDoc.Doc, baked = PxSpriteAtlas.Baked,
                                    texture = String, sprite = String, frame = String,
                                    at = Vec2.Vec2, scale = Int32,
                                    z = Int32 }): List[Render.PlacedItem] =
        let anchor = Map.get(spec#sprite, spec#doc#sprites)
            |> Option.map(sp -> sp#anchor)
            |> Option.getWithDefault(Vec2.zero());
        let s = Int32.toFloat64(spec#scale);
        drawQuad(spec#doc, spec#baked, spec#texture, spec#sprite, spec#frame,
                 { x = spec#at#x + anchor#x * s, y = spec#at#y + anchor#y * s },
                 false, spec#scale, spec#z)

    /// 1 行を (開始列, 長さ, 色キー) の rn 列へ。legend に無い文字は透明で rn を切る。
    def rowRuns(legend: Map[Char, String], row: String): List[(Int32, Int32, String)] =
        let cells = String.toList(row) |> List.zipWithIndex
            |> List.map(entry -> { let (i, ch) = entry; (i, Map.get(ch, legend)) });
        let step = (acc: (List[(Int32, Int32, String)], Option[(Int32, Int32, String)]),
                    cell: (Int32, Option[String])) -> {
            let (done, cur) = acc;
            let (i, keyOpt) = cell;
            match (cur, keyOpt) {
                case (None, None)           => (done, None)
                case (None, Some(k))        => (done, Some((i, 1, k)))
                case (Some(rn), None)      => (rn :: done, None)
                case (Some(rn), Some(k))   => {
                    let (c0, n, k0) = rn;
                    if (k == k0) (done, Some((c0, n + 1, k0)))
                    else (rn :: done, Some((i, 1, k)))
                }
            }
        };
        let (done, cur) = List.foldLeft(step, (Nil, None), cells);
        let all = match cur { case Some(rn) => rn :: done case None => done };
        List.reverse(all)
}
