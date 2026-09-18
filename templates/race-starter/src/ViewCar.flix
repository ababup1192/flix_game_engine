// ViewCar — 車（自機・ライバル）と、車から出る物（影・残像・炎・煙などの粒）を描く層。
// あわせて「実数倍率つきドット絵描画」を 2 系統ここに置く — PxSprite.draw / drawQuad は
// 整数倍しかできないが、遠近では 1.35 倍や 0.6 倍が要る。
//   pxScaled     … 矩形列（runs）を自前で縮める（コーン・アイテム・車の本体が使う）。
//   pxQuadScaled … アトラス 1 クアッドに実数 scale を掛ける（遠景のヤシ・ニトロ残像が使う）。
mod ViewCar {

    /// 演出（煙・炎・閃光）を立ち物 z-index の範囲（20..76）の上へ持ち上げる量。
    /// fx.json の zIndex は 9〜22 なので +60 で 69〜82 — クラッシュ閃光が最前面、
    /// 炎の裾は車の少し下に来る（fx.json 側の並び順をそのまま活かす）。
    def fxLift(): Int32 = 60

    // ── 実数倍率つきドット絵描画 ──

    /// pxScaled の引数一式。at は絵（文字格子）の中心が来る画面座標。
    /// f は実数倍率、turn は傾き（1 周 = 1.0）。
    pub type alias PxScaled = { doc = PxSpriteDoc.Doc, sprite = String, at = Vec2.Vec2,
                                flipX = Bool, f = Float64, turn = Float64, z = Int32 }

    /// ドット絵を実数倍率 f で描く。runs の矩形 1 個ずつを「格子中心からのずれ × f」の
    /// 位置に置き直す。傾きは「ずれを回してから置く + 矩形自身も回す」の群回転
    /// （矩形どうしの継ぎ目は回転でわずかに開くが、この解像度では見えない近似で足りる）。
    pub def pxScaled(resolver: String -> Color, spec: PxScaled): List[Render.PlacedItem] =
        pxGridAt(resolver, pxGridOf(spec#doc, spec#sprite, spec#flipX),
                 { at = spec#at, f = spec#f, turn = spec#turn, z = spec#z })

    /// ほどいた格子（矩形の並びと、絵の中心から anchor へのずれ）。
    pub type alias PxGrid = { rects = List[PxSprite.Run], anchor = Vec2.Vec2 }

    /// 格子を 1 回だけほどく。ほどく処理は文字の並びを 1 行ずつ読み直すので、
    /// 同じ絵を何十個も置く層（遠景のヤシ）で 1 個ごとに引き直すと、
    /// 置いた数ぶんだけ同じ読み取りが積み上がる。
    pub def pxGridOf(doc: PxSpriteDoc.Doc, sprite: String, flipX: Bool): PxGrid =
        { rects = PxSprite.runs(doc, sprite, "base", { x = 0.0, y = 0.0 }, flipX, 1),
          anchor = PxSprite.anchorOffsetOf(doc, sprite, "base", 1) }

    /// ほどき済みの格子を実数倍率 f で置く。
    pub def pxGridAt(resolver: String -> Color, grid: PxGrid,
                     spec: { at = Vec2.Vec2, f = Float64, turn = Float64,
                             z = Int32 }): List[Render.PlacedItem] =
        if (spec#f <= 0.0) Nil
        else {
            let a = grid#anchor;
            let still = Float64.abs(spec#turn) < 0.0001;
            let atX = spec#at#x;
            let atY = spec#at#y;
            let f = spec#f;
            grid#rects |> List.map(r -> {
                // 矩形の中心の「格子中心からのずれ」。ほどいた矩形は anchor 基準なので
                // 中心→anchor のベクトル（anchor）を足して中心基準へ写す。
                let off = { x = r#x + r#w / 2.0 + a#x, y = r#y + r#h / 2.0 + a#y };
                let spun = if (still) off
                           else Render.rotated(spec#turn, off :: Nil)
                               |> List.head |> Option.getWithDefault(off);
                let boxed = RawDraw.boxAt(
                    { x = atX + spun#x * f, y = atY + spun#y * f },
                    { x = r#w * f, y = r#h * f },
                    resolver(r#key), spec#z);
                if (still) boxed else boxed |> Render.overItem(Render.turned(spec#turn))
            })
        }

    // ── アトラス 1 クアッドの実数倍率版 ──
    // WhyNot: エンジンの PxSprite.drawQuad は整数倍率のみ。整数倍でない縮小は box 列と
    // アトラスで画素の割れ方が違い、バイト一致の保証（drawQuad の規約）を満たせないため、
    // 実数倍率版はエンジンへ入れず race 側に置く（2 本目の使い手が現れたら昇格を相談する）。

    /// pxQuadScaled の引数一式。置き場所の規約は PxSprite.drawQuad と同一
    /// （anchor セルの左上 = at・flipX は絵の中で鏡にするだけで枠は動かない）。
    /// turn は絵の中心を軸に傾ける（pxScaled の群回転と同じ軸）。
    /// tint はアトラス生成時に入れた色へ掛ける（白 = そのまま。遠景の霞の近似に使う）。
    pub type alias PxQuad = { doc = PxSpriteDoc.Doc, baked = PxSpriteAtlas.Baked,
                              texture = String, sprite = String, frame = String,
                              at = Vec2.Vec2, flipX = Bool, scale = Float64,
                              turn = Float64, tint = Color, z = Int32 }

    /// ドット絵 1 コマを「アトラス 1 クアッド」で実数倍率 scale で描く。
    /// 実戦の使い手: 遠景のヤシ（ViewScene.palmDraw — 1 本 = 矩形 75 枚が 1 枚に）と
    /// ニトロ残像（nitroTrail — 車 4 枚 ≒ 800 矩形が 4 枚に）。
    pub def pxQuadScaled(spec: PxQuad): List[Render.PlacedItem] =
        if (spec#scale <= 0.0 or spec#baked#side <= 0) Nil
        else match (Map.get(spec#sprite, spec#doc#sprites),
                    PxSpriteAtlas.regionOf(spec#baked, spec#sprite, spec#frame)) {
            case (Some(sp), Some(rect)) => {
                let s = spec#scale;
                let sideF = Int32.toFloat64(spec#baked#side);
                let ax = sp#anchor#x;
                let ay = sp#anchor#y;
                let pos: Vec2.Vec2 = { x = spec#at#x - ax * s, y = spec#at#y - ay * s };
                let quad = Render.Item.Sprite({
                    texture = spec#texture,
                    tint = spec#tint,
                    alpha = 1.0,
                    // Drawable の表示寸法 = テクスチャ全寸 × scale なので、
                    // 「コマ px × 実数 scale」になるよう辺長で割り戻す。
                    scale = { x = s * rect#size#x / sideF, y = s * rect#size#y / sideF },
                    rotation = 0.0, centered = false,
                    flipH = spec#flipX, flipV = false,
                    regionRect = Some(rect), zIndex = spec#z,
                    blend = DrawCmd.BlendMode.Normal, maskPolys = Nil });
                { at = pos,
                  item = if (Float64.abs(spec#turn) < 0.0001) quad
                         else Render.turned(spec#turn, quad) } :: Nil
            }
            case _ => Nil
        }

    /// 絵の真ん中を at に置く版（pxScaled と同じ置き方の関数 — 乗せ換え元と座標系を合わせる）。
    pub def pxQuadScaledCentered(spec: PxQuad): List[Render.PlacedItem] =
        let a = PxSprite.anchorOffsetOf(spec#doc, spec#sprite, spec#frame, 1);
        pxQuadScaled({ at = { x = spec#at#x + a#x * spec#scale,
                              y = spec#at#y + a#y * spec#scale } | spec })

    /// 車の意味色: body 系 3 キーだけ車体色から導き、残りはパレット表に任せる。
    /// 格子は 1 枚を全員で共有し、塗り分けはこの関数の差し替えで行う。
    /// 導出の式は PaletteDoc.carInk が正（アトラス焼きと同じ表を見る）。
    def carColor(palette: PaletteDoc.Doc, bodyColor: Color, key: String): Color =
        PaletteDoc.carInk(palette, bodyColor, key)

    // ── ライバル ──

    /// ライバル各台。世界の progress を u に写して遠近で置く。
    /// 後ろ（u < -0.5）と地平線の向こう（u > 14）は描かない。
    pub def rivals(cam: Proj.Cam, w: World.World): List[Render.PlacedItem] =
        w#rivals |> List.zipWithIndex |> List.flatMap(entry -> {
            let (i, r) = entry;
            let u = Proj.uOf(w, r#progress);
            if (u < -0.5 or u > 14.0) Nil
            else {
                let theirRow = Num.floorInt(r#progress / World.rowPitch());
                // カーブ追従の軽い傾き。道が右へ曲がるなら車体は右（負の turn は見た目の左右と
                // 逆にならないよう符号をここで固定する）。
                let turn = World.curveAt(theirRow, w#course) * -0.006;
                carAt(w, { x = Proj.screenX(cam, r#off, u), y = Proj.yAt(cam, u) },
                      { f = Proj.scaleOf(u) * 1.05, turn = turn,
                        color = rivalColorOf(w#theme, i), z = Proj.zOf(u) })
            }
        })

    /// ライバルの車体色は index 順に A→B→C。台数が色数を超えたら A にする（fail-open）。
    def rivalColorOf(theme: ThemeDoc.Doc, i: Int32): Color =
        match i {
            case 0 => ThemeDoc.rec(theme)#rivalA
            case 1 => ThemeDoc.rec(theme)#rivalB
            case 2 => ThemeDoc.rec(theme)#rivalC
            case _ => ThemeDoc.rec(theme)#rivalA
        }

    // ── 自機 ──

    /// 自機。u は常に Proj.playerU（World.playerAheadPx と対 — 絵と当たりの物差しを分けない）。
    /// 傾きは World.driftTurnOf（普段はわずか・ドリフトは深く・スピンは 2 回転）。
    pub def player(cam: Proj.Cam, w: World.World): List[Render.PlacedItem] =
        let u = Proj.playerU();
        let at = { x = Proj.screenX(cam, w#playerOff, u), y = Proj.yAt(cam, u) };
        let f = Proj.scaleOf(u) * 1.05;
        carAt(w, at, { f = f, turn = World.driftTurnOf(w),
                       color = ThemeDoc.rec(w#theme)#player, z = Proj.zOf(u) })
            ::: nitroTrail(w, at, f)
            ::: driftHeat(w, at, f)

    /// 車 1 台 = 足元の楕円影 + ドット絵。影を絵と別に敷くのは、路面の色がどう変わっても
    /// 車が浮いて見えないようにするため（主役の分離は影の仕事 — 暗がりで誤魔化さない）。
    def carAt(w: World.World, at: Vec2.Vec2,
              look: { f = Float64, turn = Float64, color = Color, z = Int32 }): List[Render.PlacedItem] =
        let shadow = ViewRoad.shadowUnder({
                at = { x = at#x + 2.0, y = at#y + 3.0 },
                radii = { x = 17.0 * look#f * 0.55 / 2.0, y = 27.0 * look#f * 0.55 / 2.0 },
                segs = 32, alpha = 0.28, z = look#z });
        shadow :: pxGridAt(carColor(w#palette, look#color), carGrid(w),
            { at = at, f = look#f, turn = look#turn, z = look#z })

    /// 車の格子。1 台ぶんの格子を自機とライバル全台で使い回す
    /// （1 台ごとにほどくと、同じ絵の読み取りが台数だけ走る）。
    def carGrid(w: World.World): PxGrid =
        pxGridOf(w#sprites, "car", false)

    /// ニトロ中だけの付け足し: 後端の噴射炎（loop の fx を時計で回す）、発動の瞬間に一度
    /// 広がる衝撃の輪、車の残像 4 枚。
    /// 衝撃の輪は「発動からの経過秒」（残り時間の裏返し）で引く — 発火した時刻を World に
    /// 覚えさせずに、一度だけ広がって消える絵になる。
    /// 残像を後ろ（画面の下）へ置くのは「速すぎて絵が置いていかれる」見せ方 — 速度は線と
    /// 残像で語り、車そのものの形は変えない。
    def nitroTrail(w: World.World, at: Vec2.Vec2, f: Float64): List[Render.PlacedItem] =
        if (w#nitroLeft <= 0.0) Nil
        else {
            let rear = { x = at#x, y = at#y + 13.0 * f };
            let flame = Fx.sampleAt(w#fx#flame, 0i64, Num.wrapTo(10.0, w#t), rear);
            let since = RulesDoc.rec(w#rules)#nitroDuration - w#nitroLeft;
            let shock = Fx.sampleAt(w#fx#shock, 0i64, since, at);
            let ghostTurn = World.driftTurnOf(w);
            let ghostZ = Proj.zOf(Proj.playerU()) - 1;
            // 残像は 1 枚 = 1 クアッド。box 列で描くと 1 枚 ≒ 200 矩形 × 4 枚が
            // 毎フレーム積まれる。車体色はアトラスに焼き込み済み（PaletteDoc.carInk）。
            let ghost = spec -> {
                let (dy, alpha) = spec;
                pxQuadScaledCentered({
                    doc = w#sprites, baked = w#atlas, texture = World.atlasName(),
                    sprite = "car", frame = "base",
                    at = { x = at#x, y = at#y + dy * f },
                    flipX = false, scale = f, turn = ghostTurn,
                    tint = Color.rgb(1.0, 1.0, 1.0), z = ghostZ })
                    |> Render.fadeAll(alpha)
            };
            let ghosts = (10.0, 0.42) :: (20.0, 0.28) :: (32.0, 0.17)
                :: (46.0, 0.09) :: Nil;
            Render.zShiftedAll(fxLift(), flame ::: shock)
                ::: shockRing(w, at, f, since)
                ::: List.flatMap(ghost, ghosts)
        }

    /// 衝撃の広がりが消え切るまでの秒数。長く残すと、押した瞬間の手応えではなく
    /// 「画面に置かれた図形」として観察されてしまう（4 コマぶんで消し切る）。
    def shockLife(): Float64 = 0.26

    /// ニトロ発動の衝撃。粒を撒くだけだと方向が乱数で選ばれて紙吹雪に散るので、
    /// 形は View 側で組む。線 1 本の輪郭にはしない — 細い楕円の線は照準の枠に見える。
    /// 熱の面・厚みのある輪・外へ走る筋の 3 つを重ね、車の後ろへ押し出された形にする。
    def shockRing(w: World.World, at: Vec2.Vec2, f: Float64,
                  since: Float64): List[Render.PlacedItem] =
        let p = Num.clamp01(since / shockLife());
        if (p <= 0.0 or p >= 1.0) Nil
        else {
            // 発動の瞬間が一番速く、あとは空気に食われて止まる。
            let ease = 1.0 - Float64.pow(base = 1.0 - p, 3.0);
            let r = (14.0 + 78.0 * ease) * f;
            // 波は車の後ろから押し出されるので、広がるほど中心が後ろ（画面の下）へ流れる。
            let c = { x = at#x, y = at#y + (5.0 + 18.0 * ease) * f };
            // 路面を走る波なので車と残像より下。上に置くと車体に輪が巻き付いて、
            // 地面ではなく空中に立った枠に見える。
            let z = Proj.zOf(Proj.playerU()) - 2;
            shockHeat(w, c, r, p, z) ::: shockRingFill(w, c, r, p, z) ::: shockRays(w, c, r, p, z)
        }

    /// その向きがどれだけ「真後ろ（画面の下）」寄りか（0 = 前方, 1 = 真後ろ）。
    def shockRear(a: Float64): Float64 =
        0.5 + 0.5 * Vec2.sin(a)

    /// 向き a での広がりの倍率。後ろを厚く、前を薄くし、3 と 5 の凹凸を足して縁を荒らす
    /// （左右対称のきれいな楕円は、爆発ではなく描かれた円として読まれる）。
    def shockSwell(a: Float64): Float64 =
        (0.74 + 0.40 * shockRear(a))
            * (1.0 + 0.14 * Vec2.cos(3.0 * a + 0.7) + 0.09 * Vec2.cos(5.0 * a + 2.3))

    /// 輪の 1 点。縦につぶすのは路面に沿って寝た波だから（k は半径の倍率）。
    def shockPt(c: Vec2.Vec2, r: Float64, a: Float64, k: Float64): Vec2.Vec2 =
        let rr = r * k * shockSwell(a);
        { x = c#x + rr * Vec2.cos(a), y = c#y + rr * 0.42 * Vec2.sin(a) }

    /// 衝撃の輪の中身。輪を線ではなく面で持つ — 扇形の四角を 1 周ぶん並べ、外周ぎわ（midK）を
    /// 一番濃く、そこから中心へも外へも薄れさせる。中心まで塗るのは、中を抜くと
    /// 「路面に貼られた枠」に見えるため。Add で重ねるので、濃い所ほど白熱する。
    def shockRingFill(w: World.World, c: Vec2.Vec2, r: Float64, p: Float64,
                      z: Int32): List[Render.PlacedItem] =
        let n = 26;
        let inK = 0.10 + 0.16 * p;
        let midK = 0.84 + 0.10 * p;
        let cIn = Color.mix(ThemeDoc.flameHot(w#theme), ThemeDoc.rec(w#theme)#flame, p);
        let cMid = Color.mix(ThemeDoc.rec(w#theme)#flame, ThemeDoc.flameDeep(w#theme), p);
        let cOut = ThemeDoc.flameDeep(w#theme);
        let base = 1.45 * Float64.pow(base = 1.0 - p, 1.1);
        let al = a -> Num.clamp01(base * (0.22 + 0.78 * shockRear(a)));
        List.range(0, n) |> List.flatMap(i -> {
            let a0 = 2.0 * Vec2.pi() * Int32.toFloat64(i) / Int32.toFloat64(n);
            let a1 = 2.0 * Vec2.pi() * Int32.toFloat64(i + 1) / Int32.toFloat64(n);
            let quad = s ->
                { at = { x = 0.0, y = 0.0 },
                  item = Render.gradPolygon(
                         { pos = shockPt(c, r, a0, s#k0), color = s#c0, alpha = s#f0 * al(a0) }
                      :: { pos = shockPt(c, r, a1, s#k0), color = s#c0, alpha = s#f0 * al(a1) }
                      :: { pos = shockPt(c, r, a1, s#k1), color = s#c1, alpha = s#f1 * al(a1) }
                      :: { pos = shockPt(c, r, a0, s#k1), color = s#c1, alpha = s#f1 * al(a0) }
                      :: Nil, z)
                      |> Render.blended(DrawCmd.BlendMode.Add) };
            quad({ k0 = inK,  c0 = cIn,  f0 = 0.20, k1 = midK, c1 = cMid, f1 = 1.0 })
                :: quad({ k0 = midK, c0 = cMid, f0 = 1.0,  k1 = 1.0, c1 = cOut, f1 = 0.0 })
                :: Nil
        })

    /// 衝撃の輪から外へ走る筋。輪だけで見せると単独の図形に見えるので、押し出された空気の
    /// 筋を後ろ側ほど長く伸ばす。長さと太さを Hash01 で不揃いにして定規の線から外す。
    def shockRays(w: World.World, c: Vec2.Vec2, r: Float64, p: Float64,
                  z: Int32): List[Render.PlacedItem] =
        let n = 13;
        let color = Color.mix(ThemeDoc.flameHot(w#theme), ThemeDoc.rec(w#theme)#flame, p);
        let base = 0.45 * Float64.pow(base = 1.0 - p, 1.6);
        List.range(0, n) |> List.map(i -> {
            let a = 2.0 * Vec2.pi() * (Int32.toFloat64(i) + 0.35) / Int32.toFloat64(n);
            let rear = shockRear(a);
            let k0 = 0.50 + 0.18 * Hash01.at(i, 3);
            let k1 = 1.02 + (0.08 + 0.22 * rear) * (0.5 + Hash01.at(i, 4));
            RawDraw.lineSeg(shockPt(c, r, a, k0), shockPt(c, r, a, k1),
                    Float64.max(1.0, (1.8 - 0.8 * p) * (0.6 + 0.7 * Hash01.at(i, 5))),
                    color, z)
                |> Render.overItem(item -> item
                    |> Render.fade(
                           Num.clamp01(base * (0.22 + 0.78 * rear)))
                    |> Render.blended(DrawCmd.BlendMode.Add))
        })

    /// 輪の内側の熱。中が素の路面のままだと、輪が路面に貼られた枠に見える。
    def shockHeat(w: World.World, c: Vec2.Vec2, r: Float64, p: Float64,
                  z: Int32): List[Render.PlacedItem] =
        let a = Float64.pow(base = 1.0 - p, 2.0);
        Render.glowAt(c, r * 0.55, ThemeDoc.rec(w#theme)#flame,
                { alpha = 0.30 * a, blend = DrawCmd.BlendMode.Add }, z)
            ::: (RawDraw.ellipseAt(c, { x = r * 0.52, y = r * 0.52 * 0.42 },
                        ThemeDoc.rec(w#theme)#flame, z)
                    |> Render.overItem(item -> item
                        |> Render.fade(0.16 * a)
                        |> Render.blended(DrawCmd.BlendMode.Add))
                :: Nil)

    /// ドリフト中の後輪の熱（火花）。左右の車輪から短い周期で焚き直し、ニトロゲージが
    /// 貯まっているほど濃く出す — 危険な走りが溜まっていることを、数字だけでなく車の絵で返す。
    /// 周期を fx の duration より短く取るのは、粒が全部消えてから次が湧くと点滅して見えるため。
    /// 位相をずらした 2 発を重ねるのは、1 発だけだと粒が湧いた直後と消える直前で密度が
    /// 半分になり、火花が息継ぎして見えるため。
    def driftHeat(w: World.World, at: Vec2.Vec2, f: Float64): List[Render.PlacedItem] =
        if (not w#drifting) Nil
        else {
            let heat = 0.55 + 0.45 * Num.clamp01(w#nitro);
            let wheel = dx -> phase ->
                Fx.sampleAt(w#fx#spark, 0i64, Num.wrapTo(0.24, w#t + dx * 0.004 + phase),
                        { x = at#x + dx * f, y = at#y + 8.0 * f })
                    |> Render.fadeAll(heat);
            // 車体幅より少し外へ出すのは、後輪の真下だと白煙の芯に入って
            // Add ブレンドの火花が白に溶けるため。
            let both = phase -> wheel(-11.0)(phase) ::: wheel(11.0)(phase);
            // 煙より上へ持ち上げる。同じ z の範囲だと、後から積まれる白煙（bursts）に
            // 火花が全部埋もれて「滑っている熱」が見えなくなる。
            Render.zShiftedAll(fxLift() + 8, both(0.0) ::: both(0.12))
        }

    // ── 速さの手応え（画面の揺れ） ──

    /// 高速時・ニトロ中の細かい画面揺れ（世界の層だけを動かす。HUD と幕は揺らさない）。
    /// 振幅は 2px で頭打ち — これ以上振ると道の縞と喧嘩して画面が読めなくなる。
    pub def shakeOf(w: World.World): Vec2.Vec2 =
        let over = Float64.max(0.0, w#speed / RulesDoc.rec(w#rules)#forwardSpeed - 1.0);
        let nitroKick = if (w#nitroLeft > 0.0) 0.9 else 0.0;
        let amp = Float64.min(2.0, over * 1.5 + nitroKick);
        if (amp <= 0.0) Vec2.zero()
        else { x = amp * Sway.wave(w#t, 0.0, 23.0),
               y = amp * 0.7 * Sway.wave(w#t, 0.37, 31.0) }

    // ── 煙・火花・クラッシュ（World が焚いた粒を毎フレーム投影して描く） ──

    /// 進行中の粒の効果。at は世界座標（x = 左右, y = 前進距離）で持たれているので、
    /// ここで毎フレーム投影する — 車が進んでも煙はその場に残り、後ろへ流れて見える。
    pub def bursts(cam: Proj.Cam, w: World.World): List[Render.PlacedItem] =
        w#bursts |> List.flatMap(b -> {
            let p = Proj.projectPoint(cam, w, b#at);
            Fx.sampleAt(b#spec, b#seed, Lifetime.elapsedOf(w#t, b#life), { x = p#x, y = p#y })
        }) |> Render.zShiftedAll(fxLift())
}
