// Render.Internal.Extract — Item を描画命令（Drawable / PolygonRenderCmd）へ写す所: draw / drawWith の走査・clip 矩形の重ね・葉ごとの Drawable 作り・Shader 面をテクスチャ 1 枚の sprite に落とす判定。
// ゲームからは呼ばない（Render の中身）。
pub mod Render.Internal.Extract {
    /// draw / drawWith の共通トラバーサル。Clipped を剥がして有効な clip 矩形（入れ子は交差）を決め、
    /// 葉を Drawable / PolygonRenderCmd へ振り分けてから clip 矩形を刻む。振り分けの分岐を 1 本に
    /// しておかないと、Clipped の扱いが 2 経路で割れる。
    /// 2 列は 1 回の走査で同時に積む。列ごとに走査を分けると、描く物 1 個につき
    /// Clipped の剥がしと葉の振り分けが 2 度ずつ走る（物量の多い画面では、その 2 度目が
    /// そのままフレーム時間に乗る）。積むのは逆順の cons で、最後に一度ずつ戻す。
    pub def drawInto(toDs: (Render.Item, Vec2.Vec2) -> List[GameEngine.Drawable] \ ef,
                 items: List[Render.PlacedItem]): (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd]) \ ef =
        let (dsRev, psRev) = items |> List.foldLeft((acc, placed) -> {
            let (ds, ps) = acc;
            let (leaf, clip) = Render.unwrapClip(placed#item, None);
            // clip 矩形が無いときは刻まない。作りたての Drawable / 描画命令は clip = None なので、
            // ここで None を書き直すと、同じ値を入れ直すためだけにフィールドの
            // 抜き差しが描く物の数だけ走る（clip 矩形を使う画面はごく一部）。
            match (leaf, clip) {
                case (Render.Item.Poly(p), None)    => (ds, polyCmd(placed#at, p) :: ps)
                case (Render.Item.Poly(p), Some(_)) => (ds, { clip = clip | polyCmd(placed#at, p) } :: ps)
                case (other, None)                  =>
                    (toDs(other, placed#at)
                        |> List.foldLeft((rest, d) -> d :: rest, ds), ps)
                case (other, Some(_))               =>
                    (toDs(other, placed#at)
                        |> List.foldLeft((rest, d) -> DrawCmd.withClip(clip, d) :: rest, ds), ps)
            }
        }, ((Nil, Nil): (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd])));
        (List.reverse(dsRev), List.reverse(psRev))

    /// Poly を置き場所 pos の描画命令へ（全頂点に pos を加算）。
    def polyCmd(pos: Vec2.Vec2,
                p: { vertices = List[Vec2.Vec2], color = Color, alpha = Float64, zIndex = Int32,
                     blend = DrawCmd.BlendMode, grad = Option[List[DrawCmd.VertexTint]],
                     triangles = Option[Vector[Int32]] }): GameEngine.PolygonRenderCmd =
        { vertices = List.map(v -> Vec2.add(v, pos), p#vertices),
          color = p#color, alpha = p#alpha, zIndex = p#zIndex, clip = None, blend = p#blend,
          grad = p#grad, triangles = p#triangles }

    /// 3D を描けない道で場面の代わりに塗る色。
    pub def scene3dStandIn(): Color = { r = 0.08, g = 0.08, b = 0.1 }

    /// clip 矩形 rect を既存の clip と重ねる（両方あれば交差）。
    pub def mergeClip(rect: Rect2.Rect2, existing: Option[Rect2.Rect2]): Option[Rect2.Rect2] =
        match existing {
            case None    => Some(rect)
            case Some(r) => Some(Rect2.intersect(rect, r))
        }

    /// region atlas 対応の射影（drawWith のため）。textureSize を引いて UV を計算する
    /// （uvOffset = regionPos/texSize, uvScale = regionSize/texSize）。
    /// 非 region スプライト・text・box は pure 経路と同一。
    pub def toDrawablesAtlas(textureInfoOf: String -> Option[GameEngine.TextureInfo] \ ef,
                         item: Render.Item, pos: Vec2.Vec2): List[GameEngine.Drawable] \ ef =
        match item {
            case Render.Item.Sprite(s) =>
                let (uvOff, uvScl) = match s#regionRect {
                    case None       => ({x = 0.0, y = 0.0}, {x = 1.0, y = 1.0})
                    case Some(rect) => match textureInfoOf(s#texture) {
                        case Some(ti) => ({x = rect#position#x / ti#width, y = rect#position#y / ti#height},
                                          {x = rect#size#x / ti#width, y = rect#size#y / ti#height})
                        case None     => ({x = 0.0, y = 0.0}, {x = 1.0, y = 1.0})
                    }
                };
                DrawCmd.fromParts(
                   s#texture, pos,
                   {x = s#scale#x * flipSign(s#flipH), y = s#scale#y * flipSign(s#flipV)},
                   radiansOf(s#rotation), s#tint, s#alpha, s#centered,
                   uvOff, uvScl, s#zIndex, None,
                   None, s#blend, s#maskPolys) :: Nil
            // テクスチャ 1 枚を読むだけの面は、代表色の中間の灰より元の絵の方が近い（GL も ShaderEval も使わない命令だけの経路）。
            // 色の計算（灰色化・明るさ）は落とす — 場を画素ごとに評価するのは GL か ShaderEval の仕事。
            case Render.Item.Shader(s) => match textureReadOf(s#spec, s#t) {
                case Some((name, area)) => match textureInfoOf(name) {
                    case Some(ti) if ti#width > 0.0 and ti#height > 0.0 =>
                        DrawCmd.fromParts(
                           name, pos,
                           { x = s#rect#size#x / (ti#width * area#size#x),
                             y = s#rect#size#y / (ti#height * area#size#y) },
                           0.0, Render.white(), s#alpha, false,
                           area#position, area#size, s#zIndex, None,
                           None, s#blend, s#mask) :: Nil
                    case _ => Render.toDrawables(item, pos)
                }
                case None => Render.toDrawables(item, pos)
            }
            case other => Render.toDrawables(other, pos)
        }

    /// 面の式がテクスチャ 1 枚だけを読み、読む位置が shift（u・v それぞれの 1 次式で決まる平行移動と伸び縮み）だけで
    /// 決まるなら、そのテクスチャの名前と読む範囲（uv 0〜1 の矩形）。範囲は面の左上・右下で shift を評価して出す。
    /// None（矩形 1 枚に写せない）: uv を変えて読む節（ShaderDoc.remappedChild）の下に tex か ref がある
    /// （ref は bindings の値で、どの uv で読んだ物かをここでは辿らない）・shift のずらし量が 1 次式でない
    /// （isAffineIn）・読む所ごとに範囲が食い違う。
    /// Linear で読む Spec も None（sprite に落とすと Nearest で貼られて実機と変わる）。
    def textureReadOf(spec: ShaderDoc.Spec, t: Float64): Option[(String, Rect2.Rect2)] =
        if (ShaderDoc.texReads(spec) |> List.exists(read -> snd(read) == ShaderDoc.FilterMode.Linear)) None
        else match ShaderDoc.texNames(spec) {
            case name :: Nil =>
                let nodes = ShaderDoc.fieldsOf(spec)
                    |> List.flatMap(field -> ShaderDoc.foldField((acc, node) -> node :: acc, Nil, field));
                let shifts = List.filterMap(plainShiftRead, nodes);
                let bends = nodes |> List.exists(node -> match (ShaderDoc.remappedChild(node), plainShiftRead(node)) {
                    case (Some(child), None) => countNodes(isTexOrRef, child :: Nil) > 0
                    case _                   => false
                });
                let bare = if (List.count(isTex, nodes) > List.length(shifts)) Some(wholeArea()) :: Nil else Nil;
                let areas = List.append(bare, shifts |> List.map(sh -> shiftedArea(sh#dx, sh#dy, t)));
                if (bends) None
                else match areas {
                    case Some(first) :: rest if List.forAll(a -> Option.exists(sameArea(first), a), rest) => Some((name, first))
                    case _ => None
                }
            case _ => None
        }

    /// tex をそのまま shift で読む節で、dx が u だけの 1 次式・dy が v だけの 1 次式なら、そのずらし量。
    def plainShiftRead(node: ShaderDoc.Field): Option[{ dx = ShaderDoc.Field, dy = ShaderDoc.Field }] =
        match node {
            case ShaderDoc.Field.Shift(sh) => match sh#of {
                case ShaderDoc.Field.Tex(_) if isAffineIn(ShaderDoc.Axis.U, sh#dx) and isAffineIn(ShaderDoc.Axis.V, sh#dy) => Some({ dx = sh#dx, dy = sh#dy })
                case _ => None
            }
            case _ => None
        }

    /// field が uv の axis の側だけの 1 次式（a × uv + b。a・b は uv を含まない）か。1 次式なら左上・右下の 2 点で
    /// 写す先の矩形が決まる。もう片方の軸の uv（斜めの歪み）・掛け算の両側の uv（曲線）・min / max / step の uv（折れ線）は偽。
    // 許す場を並べる側にするのは、場を足した時に「曲がらない」と黙って扱わないため。
    def isAffineIn(axis: ShaderDoc.Axis, field: ShaderDoc.Field): Bool =
        match field {
            case ShaderDoc.Field.Uv(uv)  => uv#axis == axis
            case ShaderDoc.Field.Bin(bn) => match bn#op {
                case ShaderDoc.BinOp.Add  => isAffineIn(axis, bn#a) and isAffineIn(axis, bn#b)
                case ShaderDoc.BinOp.Sub  => isAffineIn(axis, bn#a) and isAffineIn(axis, bn#b)
                case ShaderDoc.BinOp.Mul  => (isUvFree(bn#a) and isAffineIn(axis, bn#b)) or (isAffineIn(axis, bn#a) and isUvFree(bn#b))
                case ShaderDoc.BinOp.Min  => isUvFree(field)
                case ShaderDoc.BinOp.Max  => isUvFree(field)
                case ShaderDoc.BinOp.Step => isUvFree(field)
                case ShaderDoc.BinOp.Div  => isAffineIn(axis, bn#a) and isUvFree(bn#b)
            }
            case _ => isUvFree(field)
        }

    /// field が uv に依らない（面のどこでも同じ値）か。定数・時間と、その計算だけ。
    def isUvFree(field: ShaderDoc.Field): Bool =
        match field {
            case ShaderDoc.Field.Const(_) => true
            case ShaderDoc.Field.Time(tm) => isUvFree(tm#offset)
            case ShaderDoc.Field.Param(_) => true
            case ShaderDoc.Field.Bin(bn)  => isUvFree(bn#a) and isUvFree(bn#b)
            case ShaderDoc.Field.Un(un)   => isUvFree(un#of)
            case ShaderDoc.Field.Pow(pw)  => isUvFree(pw#of)
            case _                        => false
        }

    def isTex(node: ShaderDoc.Field): Bool = match node {
        case ShaderDoc.Field.Tex(_) => true
        case _                      => false
    }

    def isTexOrRef(node: ShaderDoc.Field): Bool = match node {
        case ShaderDoc.Field.Tex(_) => true
        case ShaderDoc.Field.Ref(_) => true
        case _                      => false
    }

    /// fields の木の節のうち p を満たす物の数。
    def countNodes(p: ShaderDoc.Field -> Bool, fields: List[ShaderDoc.Field]): Int32 =
        fields |> List.foldLeft((acc, field) -> ShaderDoc.foldField((n, node) -> if (p(node)) n + 1 else n, acc, field), 0)

    def sameArea(a: Rect2.Rect2, b: Rect2.Rect2): Bool =
        let near = (x, y) -> Float64.abs(x - y) < areaTolerance();
        near(a#position#x, b#position#x) and near(a#position#y, b#position#y) and
        near(a#size#x, b#size#x) and near(a#size#y, b#size#y)

    /// 2 つの uv を同じと見る差（浮動小数の評価のずれを吸う。4096 px のテクスチャの 1 px より小さい）。
    def areaTolerance(): Float64 = 1.0 / 4096.0

    def wholeArea(): Rect2.Rect2 = { position = { x = 0.0, y = 0.0 }, size = { x = 1.0, y = 1.0 } }

    /// shift が面の左上 (0, 0) と右下 (1, 1) を写す先から作る読む範囲（ずらし量は isAffineIn の 1 次式なので 2 点で決まる）。
    /// 大きさが 0 以下（裏返し・潰れ）は None。
    def shiftedArea(dx: ShaderDoc.Field, dy: ShaderDoc.Field, t: Float64): Option[Rect2.Rect2] =
        let at = (u, v) -> { x = u + ShaderEval.evalField(dx, { x = u, y = v }, t),
                             y = v + ShaderEval.evalField(dy, { x = u, y = v }, t) };
        let lo = at(0.0, 0.0);
        let hi = at(1.0, 1.0);
        let size = { x = hi#x - lo#x, y = hi#y - lo#y };
        if (size#x > 0.0 and size#y > 0.0) Some({ position = lo, size = size }) else None

    pub def spriteDrawable(texture: String, tint: Color, alpha: Float64, scale: Vec2.Vec2,
                       rotation: Float64, centered: Bool, flipH: Bool, flipV: Bool,
                       regionRect: Option[Rect2.Rect2], zIndex: Int32, blend: DrawCmd.BlendMode,
                       maskPolys: List[List[Vec2.Vec2]], pos: Vec2.Vec2): GameEngine.Drawable =
        match regionRect {
            case Some(_) => bug!("Render: region atlas not supported yet (pass regionRect=None)")
            case None    =>
                DrawCmd.fromParts(
                  texture,
                  pos,
                  {x = scale#x * flipSign(flipH), y = scale#y * flipSign(flipV)},
                  radiansOf(rotation),
                  tint,
                  alpha,
                  centered,
                  {x = 0.0, y = 0.0},
                  {x = 1.0, y = 1.0},
                  zIndex,
                  None,
                  None,
                  blend,
                  maskPolys)
        }

    def flipSign(b: Bool): Float64 = if (b) -1.0 else 1.0

    /// 回転数（1 周 = 1.0）→ 描画命令のラジアン。単位の境目はここ 1 か所だけ。
    def radiansOf(turns: Float64): Float64 = Num.tau() * turns

    pub def textDrawables(content: String, fontAtlas: FontAtlas, fontSize: Float64,
                      tint: Color, alpha: Float64, rotation: Float64, zIndex: Int32,
                      wrapWidth: Option[Float64], pos: Vec2.Vec2): List[GameEngine.Drawable] =
        // engine の public 純粋射影に委譲。文字色（SDF 描画では color がそのまま文字色）と
        // zIndex は Text の visual に 1 回だけ書き込む — 出来上がった列を withTintAndZIndex で
        // map し直すと、文字 1 字につき捨てる Drawable が 1 個ずつ増えるため。
        let ds = Text.toDrawables(
            Text.make(content, fontAtlas, fontSize)
                |> Text.setWrapWidth(wrapWidth)
                |> Text.mapVisual(v -> v |> Visual.setColor(tint) |> Visual.setZIndex(zIndex)),
            pos);
        // 濃さは薄めた時だけ字ごとに書き直す（不透明の字は作り直さない）。
        let faded = if (alpha >= 1.0) ds else ds |> List.map(DrawCmd.withAlpha(alpha));
        if (rotation == 0.0) faded
        else faded |> List.map(turnGlyph(rotation, fontAtlas#textureSize, pos))

    /// 文字 1 つぶんの四角を、文字列の置き場所 pivot のまわりに回して置き直す。
    /// 描画側は四角を自分の中心で回すので、中心を公転させたうえで同じ角度を持たせると
    /// 文字列全体が 1 枚の板のように回る。グリフの四角の大きさは
    /// scale × アトラス辺長（Text.toDrawables がそう組んでいる）。
    def turnGlyph(t: Float64, textureSize: Float64, pivot: Vec2.Vec2,
                  d: GameEngine.Drawable): GameEngine.Drawable =
        let DrawCmd.Drawable.Drawable(_tex, px, py, sx, sy, _rot,
                                      _cr, _cg, _cb, _a, _cen,
                                      _uox, _uoy, _usx, _usy, _z,
                                      _style, _clip, _blend, _mask) = d;
        let size = { x = sx * textureSize, y = sy * textureSize };
        let half = Vec2.div(size, 2.0);
        let moved = Render.rotAbout(t, pivot, Vec2.add({x = px, y = py}, half));
        DrawCmd.withPositionAndRotation(Vec2.sub(moved, half), radiansOf(t), d)

    pub def boxDrawable(size: Vec2.Vec2, color: Color, alpha: Float64, rotation: Float64,
                    style: Option[GameEngine.BoxStyle], zIndex: Int32, blend: DrawCmd.BlendMode,
                    pos: Vec2.Vec2): GameEngine.Drawable =
        // texture=""・centered=false・position=左上・scale=ピクセルサイズ・style=Some で単色塗り。
        DrawCmd.fromParts(
          "",
          pos,
          size,
          radiansOf(rotation),
          color,
          alpha,
          false,
          {x = 0.0, y = 0.0},
          {x = 1.0, y = 1.0},
          zIndex,
          style,
          None,
          blend,
          Nil)
}
