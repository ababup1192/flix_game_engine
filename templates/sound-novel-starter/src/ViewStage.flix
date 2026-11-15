// ViewStage — 舞台の world の層（背景・背景に付く絵・立ち絵と小物・粒・ゲームの絵・覆い）を、層の数で並べて描く（純粋）。
// 物はまとまり（Group）ごとに「層の数」を持ち、層の数の小さい順（同じ数なら 絵 → 粒 → GameView → 覆い）に並べてから、
// まとまりの順番 × View.zWorldStride + まとまりの中の z（0..View.zWorldStride-1）を z にする。カメラ（camera.*）と揺れ（camera.shake）はこの層にだけ掛ける。
// 層の数の既定: 背景 0・背景に付く絵 100・人物 500・小物 600（novel.cast.json の layer）・粒（particleLayer）・覆い（novel.kind.json の overlayLayer）・
// GameView は自分で決める。文字の枠と HUD は View.hud（world より必ず手前）。
mod ViewStage {
    use fge::{Clock, Color, DrawCmd, Fx, Num, RawDraw, Rect2, Render, ShaderDoc, Sort}

    /// world の層の物 1 まとまり: layer = 層の数、order = 同じ層の数の中の順（絵 0・粒 1・GameView 2・覆い 3）、items = 物（中の z は 0..View.zWorldStride-1）。
    type alias Group = { layer = Int32, order = Int32, items = List[Render.PlacedItem] }

    /// 粒（蛍・雪）の層の数。
    // WhyNot: 粒を人物（500）より手前に置かない — 作例の絵は粒を人物の奥に置いて描いてある（reference の絵がそれを見張る）。
    def particleLayer(): Int32 = 400

    /// 実際の画面の world の層: 層の数で並べ、カメラを掛け、揺れの分だけずらす。withProps = 小物もここで描くか（頁の幕がある間は View が幕の上に描く）。
    pub def frame(env: View.Env, stage: Stage.Stage, withProps: Bool): List[Render.PlacedItem] =
        let (dx, dy) = Stage.shakeOffset(env#storyNow, Stage.ShakeTarget.Screen, stage);
        layered(env, backdropRect(env#fit), stage, withProps) |> withCamera(env, stage) |> Render.movedAll({ x = dx, y = dy })

    /// サムネの world の層: 画面ちょうどに塗り（揺れは掛けない）、z を 0..9 に詰める（サムネは字を z 10 から重ねる）。
    // WhyNot: 背景を揺れの分はみ出す backdropRect で塗らない —— 写真の面（Shader）は切り抜き（clippedAll）が効かず、枠の外へはみ出す。
    pub def thumbnail(env: View.Env, stage: Stage.Stage, withProps: Bool): List[Render.PlacedItem] =
        let items = layered(env, Layout.screen(env#fit), stage, withProps) |> withCamera(env, stage);
        let ranks = items |> List.map(p -> zOf(p#item)) |> List.toSet |> Set.toList |> List.zipWithIndex |> List.map(match (i, z) -> (z, Int32.min(i, 9))) |> List.toMap;
        items |> List.map(Render.overItem(mapZ(z -> Map.get(z, ranks) |> Option.getWithDefault(9))))

    /// world の層の物を、層の数で並べて z を振った列（カメラと揺れの前）。area = 背景を塗る矩形。
    def layered(env: View.Env, area: Rect2.Rect2, stage: Stage.Stage, withProps: Bool): List[Render.PlacedItem] =
        let keep = (kind, entry) -> CastDoc.isAttachedToBackdrop(entry) or withProps or kind == CastDoc.Kind.Character;
        let actors = Cast.groupsWhere(castEnv(env, stage), keep, stage#cast, 0) |> List.map(match (n, items) -> { layer = n, order = 0, items = items });
        let game = GameView.draw(env, stage) |> List.map(match (n, item) -> { layer = n, order = 2, items = item :: Nil });
        let groups = { layer = 0, order = 0, items = backdropsIn(area, env, stage) } :: actors :::
                     ({ layer = particleLayer(), order = 1, items = particles(env, stage) } :: overlayGroup(env, stage) :: game);
        stacked(groups)

    /// まとまりを層の数の順に並べ、順番ごとに z の幅を割り当てる（並んだ同じ層の数と順のまとまりは同じ幅を使う）。
    def stacked(groups: List[Group]): List[Render.PlacedItem] =
        let sorted = groups |> List.filter(g -> not List.isEmpty(g#items)) |> Sort.sortStableBy(g -> (g#layer, g#order));
        let step = (acc, g) -> {
            let (rank, last, out) = acc;
            let here = (g#layer, g#order);
            let r = if (Some(here) == last) rank else rank + 1;
            let base = r * View.zWorldStride();
            (r, Some(here), g#items |> List.map(Render.overItem(mapZ(z -> base + Int32.max(0, Int32.min(View.zWorldStride() - 1, z))))) :: out)
        };
        let (_, _, out) = List.foldLeft(step, (-1, None, Nil), sorted);
        List.flatten(List.reverse(out))

    /// カメラ（camera.zoom・.x・.y）を world の層に掛ける: 画面の真ん中を軸に zoom 倍し、見る所のずれの分だけ逆へずらす。
    def withCamera(env: View.Env, stage: Stage.Stage, items: List[Render.PlacedItem]): List[Render.PlacedItem] =
        let zoom = Stage.cameraAt(env#storyNow, Stage.CameraField.Zoom, stage);
        let x = Stage.cameraAt(env#storyNow, Stage.CameraField.X, stage);
        let y = Stage.cameraAt(env#storyNow, Stage.CameraField.Y, stage);
        if (zoom == 1.0 and x == 0.0 and y == 0.0) items
        else {
            let size = Layout.size(env#fit);
            items |> Render.scaledAllAround(zoom, { x = size#x / 2.0, y = size#y / 2.0 }) |> Render.movedAll({ x = 0.0 - x * size#x * zoom, y = 0.0 - y * size#y * zoom })
        }

    // ── 覆い（<<overlay>>） ──

    /// now の覆いの (色, 濃さ, 置き場が screen か)。濃さが 0 なら None。
    def overlayOf(env: View.Env, stage: Stage.Stage): Option[(Color, Float64, Bool)] =
        let k = View.kindOf(env);
        let alpha = PropertyTween.numAt(env#storyNow, Stage.overlayAlphaKey(), k#overlayStart, stage#props);
        let color = PropertyTween.nameAt(env#storyNow, Stage.overlayColorKey(), stage#props) |> Option.flatMap(Commands.colorOfName)
            |> Option.getWithDefault({ r = 0.0, g = 0.0, b = 0.0 });
        let onScreen = PropertyTween.nameAt(env#storyNow, Stage.overlayLayerKey(), stage#props) == Some("screen");
        if (alpha <= 0.0) None else Some((color, Float64.min(1.0, alpha), onScreen))

    /// 覆いの置き場が stage の時の world のまとまり（揺れても端が覗かないよう背景と同じ矩形）。
    def overlayGroup(env: View.Env, stage: Stage.Stage): Group =
        let items = overlayOf(env, stage) |> Option.filter(match (_, _, onScreen) -> not onScreen)
            |> Option.map(match (color, alpha, _) -> {
                let r = backdropRect(env#fit);
                View.at(r#position#x, r#position#y, RawDraw.box(r#size, color, 0) |> Render.fade(alpha)) :: Nil
            }) |> Option.getWithDefault(Nil);
        { layer = View.kindOf(env)#overlayLayer, order = 3, items = items }

    /// 覆いの置き場が screen の時に hud の z に描く物（文字の枠より手前）。
    pub def screenOverlay(env: View.Env, stage: Stage.Stage, z: Int32): List[Render.PlacedItem] =
        overlayOf(env, stage) |> Option.filter(match (_, _, onScreen) -> onScreen)
            |> Option.map(match (color, alpha, _) -> View.at(0.0, 0.0, RawDraw.box(Layout.size(env#fit), color, z) |> Render.fade(alpha)) :: Nil)
            |> Option.getWithDefault(Nil)

    // ── z ──

    /// 絵 1 つの z（Clipped は中身）。
    def zOf(item: Render.Item): Int32 = match item {
        case Render.Item.Sprite(s)  => s#zIndex
        case Render.Item.Text(x)    => x#zIndex
        case Render.Item.Box(b)     => b#zIndex
        case Render.Item.Poly(p)    => p#zIndex
        case Render.Item.Shader(x)  => x#zIndex
        case Render.Item.Scene3d(x) => x#zIndex
        case Render.Item.Clipped(c) => zOf(c#inner)
    }

    /// 絵 1 つの z を f で替える（Clipped は中身）。
    pub def mapZ(f: Int32 -> Int32): Render.Item -> Render.Item = item -> match item {
        case Render.Item.Sprite(s)  => Render.Item.Sprite({ zIndex = f(s#zIndex) | s })
        case Render.Item.Text(x)    => Render.Item.Text({ zIndex = f(x#zIndex) | x })
        case Render.Item.Box(b)     => Render.Item.Box({ zIndex = f(b#zIndex) | b })
        case Render.Item.Poly(p)    => Render.Item.Poly({ zIndex = f(p#zIndex) | p })
        case Render.Item.Shader(x)  => Render.Item.Shader({ zIndex = f(x#zIndex) | x })
        case Render.Item.Scene3d(x) => Render.Item.Scene3d({ zIndex = f(x#zIndex) | x })
        case Render.Item.Clipped(c) => Render.Item.Clipped({ inner = mapZ(f)(c#inner) | c })
    }

    // ── 背景（写真をぼかして時間帯の色に） ──

    /// 揺れても画面の端が覗かないよう、背景は画面より一回り大きく敷く。縦の画面は写真の横長の比のまま高さに合わせ、
    /// 左右のはみ出しを捨てる（真ん中を見せる）。
    // WhyNot: 縦の画面で写真を画面の比に縮めない — 横長の写真が縦に潰れる。
    def backdropRect(fit: Layout.Fit): Rect2.Rect2 =
        let w = Layout.width(fit);
        let h = Layout.height(fit);
        if (Layout.isPortrait(fit)) {
            let tall = h + 24.0;
            let wide = tall * 16.0 / 9.0;
            { position = { x = (w - wide) / 2.0, y = -12.0 }, size = { x = wide, y = tall } }
        } else { position = { x = -12.0, y = -12.0 }, size = { x = w + 24.0, y = h + 24.0 } }

    /// 背景を矩形 area に塗る（実際の画面は揺れの分だけはみ出す backdropRect、サムネは画面ちょうど）。
    pub def backdropsIn(area: Rect2.Rect2, env: View.Env, stage: Stage.Stage): List[Render.PlacedItem] =
        let ground = View.at(area#position#x, area#position#y, RawDraw.box(area#size, Backdrop.groundColor(), 0));
        let layer = (shot: Stage.Shot, progress, z) -> specOf(shot, env)
            |> Option.map(spec -> Backdrop.surface(spec, area, progress, z) :: Nil)
            |> Option.getWithDefault(Nil);
        let under = stage#under |> Option.map(shot -> layer(shot, 1.0, 1)) |> Option.getWithDefault(Nil);
        let top = stage#shot |> Option.map(shot -> layer(shot, Stage.fadeProgress(env#storyNow, stage), 2)) |> Option.getWithDefault(Nil);
        ground :: List.append(under, top)

    /// 写真がまだ届いていなければ None（その層は描かず、下の暗い地が見える）。
    def specOf(shot: Stage.Shot, env: View.Env): Option[ShaderDoc.Spec] =
        forM (photo <- BackdropDoc.photoOf(shot#photo, env#res#backdrops) |> Option.filter(p -> not Set.memberOf(p#texture, env#res#missing));
              grade <- BackdropDoc.gradeOf(shot#grade, env#res#backdrops))
        yield Backdrop.specOf("${shot#photo}_${shot#grade}", photo, grade)

    // ── 立ち絵と小物（Cast） ──

    /// 頁の幕の上・字の下に描く小物（NVL と縦の画面の頁）。
    pub def pageProps(env: View.Env, stage: Stage.Stage): List[Render.PlacedItem] =
        Cast.groupsWhere(castEnv(env, stage), (kind, entry) -> kind == CastDoc.Kind.Prop and not CastDoc.isAttachedToBackdrop(entry), stage#cast, View.zPageProp())
            |> List.flatMap(snd)

    /// 今の画面で、小物を hud の頁（幕の上）が描くか。読んでいる頁を hud が描いていて、その頁に幕がある時（NVL か縦の画面）。
    pub def isPropOnPage(env: View.Env, w: World.World): Bool = match w#scene {
        case World.Scene.Reading(r) =>
            not View.coversScreen(w#panel) and w#panel != World.Panel.Hidden and not Stage.isWindowHidden(env#storyNow, r#stage)
                and hasPageVeil(env, r#stage)
        case _ => false
    }

    /// 頁に幕がある（横の NVL・縦の画面は NVL も ADV も頁）。
    pub def hasPageVeil(env: View.Env, stage: Stage.Stage): Bool = Layout.isPortrait(env#fit) or stage#mode == Stage.Mode.Nvl

    /// 立ち絵と小物の描く元。掛ける色は背景の時間帯の cast の欄（無い時間帯・背景が無い時は絵のまま）を、背景の重ねと同じ進みで替える。
    pub def castEnv(env: View.Env, stage: Stage.Stage): Cast.Env =
        let toneOf = (shot: Option[Stage.Shot]) -> shot
            |> Option.flatMap(s -> BackdropDoc.gradeOf(s#grade, env#res#backdrops) |> Option.flatMap(g -> g#cast) |> Option.map(Cast.toneOf(s#grade)))
            |> Option.getWithDefault(Cast.plainTone());
        let progress = Stage.fadeProgress(env#storyNow, stage);
        let light = if (progress >= 1.0) Cast.steadyLight(toneOf(stage#shot)) else { previous = toneOf(stage#under), current = toneOf(stage#shot), progress = progress };
        { doc = env#res#cast, fit = env#fit, storyNow = env#storyNow, realNow = env#realNow, missing = env#res#missing, light = light,
          props = stage#props, photo = stage#shot |> Option.map(s -> s#photo) }

    // ── パーティクル（蛍・雪） ──

    /// 蛍: 番号と実時間だけから位置と明滅を導く（どこにも保存しない = 巻き戻しても同じ絵）。
    /// 草むらの高さ（画面の下 6 割）をゆっくり漂い、息をするように明滅する。
    def particles(env: View.Env, stage: Stage.Stage): List[Render.PlacedItem] =
        match Stage.particlesOf(env#storyNow, stage) {
            case Some("fireflies") =>
                let color = View.theme(env)#firefly;
                Fx.derive(View.kindOf(env)#fireflies, View.realSeconds(env), (_i, rand, t) -> {
                    let x = rand(0) * Layout.width(env#fit) + Num.sin(t * (0.15 + rand(2) * 0.2) + rand(3) * 6.28) * 40.0;
                    let y = Layout.height(env#fit) * (0.42 + rand(1) * 0.5) + Num.sin(t * (0.3 + rand(4) * 0.3) + rand(5) * 6.28) * 18.0;
                    let pulse = 0.5 + 0.5 * Num.sin(t * (1.2 + rand(6) * 1.6) + rand(7) * 6.28);
                    let a = pulse * pulse;
                    { x = x, y = y, a = a, r = 2.0 + rand(8) * 1.6 }
                }) |> List.flatMap(fly ->
                    if (fly#a < 0.05) Nil
                    else RawDraw.circleAt({ x = fly#x, y = fly#y }, fly#r * 0.5, Color.lighten(color, 0.5), 4)
                             |> Render.overItem(item -> item |> Render.fade(fly#a) |> Render.blended(DrawCmd.BlendMode.Add))
                         :: Render.glowAt({ x = fly#x, y = fly#y }, fly#r * 5.0, color,
                                          { alpha = 0.55 * fly#a, blend = DrawCmd.BlendMode.Add }, 3))
            case Some("snow") => snow(env, stage)
            case _ => Nil
        }

    /// 雪: 蛍と同じく番号と実時間だけから位置を導く。上から下へゆっくり落ち、横に少し揺れ、画面の下で上へ戻る。
    /// 粒子ごとに速さ・大きさ・濃さを散らし、遠い粒子（小さく遅い）ほど薄くして奥行きを出す。
    /// 降り始めは粒子ごとに出る時刻をずらして少しずつ増やす（物語の時計で数えるので、セーブから戻した所は全部そろっている）。
    /// 光は粒子の周りの薄いにじみだけ。手前の大きな粒子と灯りの側の粒子が、粒子ごとにばらつく間で時々にじみを強める。
    def snow(env: View.Env, stage: Stage.Stage): List[Render.PlacedItem] =
        let k = View.kindOf(env)#snow;
        let w = Layout.width(env#fit);
        let h = Layout.height(env#fit);
        let margin = 12.0;
        let span = h + margin * 2.0;
        let ink = Color.lighten(View.theme(env)#ink, 0.6);
        let ramp = Stage.particlesSince(env#storyNow, stage)
            |> Option.map(since -> if (k#fadeIn <= 0.0) 1.0 else Float64.min(1.0, since / k#fadeIn)) |> Option.getWithDefault(1.0);
        let lit = stage#shot |> Option.exists(shot -> List.memberOf(shot#photo, k#warmPhotos));
        Fx.derive(k#count, View.realSeconds(env), (_i, rand, t) -> {
            let depth = rand(2);
            let fall = rand(1) * span + t * k#fallSpeed * (0.6 + depth * 0.8);
            let y = fall - span * Float64.floor(fall / span) - margin;
            let x = rand(0) * w + Num.sin(t * (0.35 + rand(3) * 0.45) + rand(4) * 6.28) * k#sway * (0.5 + depth * 0.5);
            let warmth = if (lit) clamp01((x / w - k#warmFromX) / Float64.max(0.01, 1.0 - k#warmFromX)) else 0.0;
            let catches = Float64.max(warmth, clamp01((depth - 0.6) / 0.4));
            let glint = catches * snowGlint(k, t, rand(5), rand(6), rand(7));
            { x = x, y = y, r = k#size * (0.5 + depth * 0.8), a = (0.45 + depth * 0.5) * clamp01((ramp - rand(8)) * 6.0),
              glint = glint, color = Color.mix(ink, k#warmColor, warmth * k#warmStrength) }
        }) |> List.filter(flake -> flake#a > 0.01) |> List.flatMap(flake ->
            Render.glowAt({ x = flake#x, y = flake#y }, flake#r * k#glowRadius, flake#color,
                          { alpha = k#glow * flake#a * (1.0 + k#twinkleGain * flake#glint), blend = DrawCmd.BlendMode.Add }, 3)
            |> List.append(RawDraw.circleAt({ x = flake#x, y = flake#y }, flake#r, flake#color, 4)
                               |> Render.overItem(item -> Render.fade(Float64.min(1.0, flake#a + 0.1 * flake#glint), item)) :: Nil))

    /// 1 つの粒子が今どれだけ光を拾っているか（0〜1）。間は粒子ごとに twinkleEvery の 0.5〜1.5 倍で、
    /// その間のどこで光るかも回ごとに変えるので、同じ粒子でも規則的には光らない。spread / phase / seed = 粒子ごとの乱数。
    def snowGlint(k: KindDoc.Snow, t: Float64, spread: Float64, phase: Float64, seed: Float64): Float64 =
        let period = Float64.max(k#twinkleSeconds * 2.0, k#twinkleEvery * (0.5 + spread));
        let shifted = t + phase * period;
        let cycle = Float64.floor(shifted / period);
        let roll = fract(Num.sin(cycle * 12.9898 + seed * 78.233) * 43758.5453);
        let u = (shifted - cycle * period - roll * (period - k#twinkleSeconds)) / Float64.max(0.01, k#twinkleSeconds);
        if (u < 0.0 or u >= 1.0) 0.0 else Num.sin(Num.pi() * u)

    def fract(x: Float64): Float64 = x - Float64.floor(x)

    def clamp01(x: Float64): Float64 = Float64.max(0.0, Float64.min(1.0, x))
}
