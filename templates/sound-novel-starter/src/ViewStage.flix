// ViewStage — 舞台の world の層（背景・背景に付く絵・立ち絵と小物・粒・ゲームの絵・覆い）を、層の数で並べて描く（純粋）。
// 物はグループ（Group）ごとに「層の数」を持ち、層の数の小さい順（同じ数なら 絵 → 粒 → GameView → 覆い）に並べてから、
// グループの順番 × View.zWorldStride + グループの中の z（0..View.zWorldStride-1）を z にする。カメラ（camera.*）と揺れ（camera.shake）はこの層にだけ掛ける。
// 層の数の既定: 背景 0・背景に付く絵 100・人物 500・小物 600（novel.cast.json の layer）・粒（novel.effects.json の layer・既定 700）・覆い（novel.kind.json の overlayLayer）・
// GameView は自分で決める。文字の枠と HUD は View.hud（world より必ず手前）。
mod ViewStage {
    use fge::{Clock, Color, DrawCmd, Fx, Num, RawDraw, Rect2, Render, ShaderDoc, Sort}

    /// 背景 1 枚にゲームが描く絵（GameView.backdrop と同じ形: 描く元・舞台・背景の名前・塗る矩形 → 絵か None）。
    pub type alias BackdropPainter = (View.Env, Stage.Stage, String, Rect2.Rect2) -> Option[List[Render.PlacedItem]]

    /// 背景 1 枚の絵: ゲームが描いた物か、テンプレートの写真の Spec。
    enum Picture {
        case Painted(List[Render.PlacedItem])
        case Still(ShaderDoc.Spec)
    }

    /// world の層の物 1 グループ: layer = 層の数、order = 同じ層の数の中の順（絵 0・粒 1・GameView 2・覆い 3）、items = 物（中の z は 0..View.zWorldStride-1）。
    type alias Group = { layer = Int32, order = Int32, items = List[Render.PlacedItem] }

    /// 実際の画面の world の層: 層の数で並べ、カメラを掛け、揺れの分だけずらす。withProps = 小物もここで描くか（頁の幕がある間は View が幕の上に描く）。
    pub def frame(env: View.Env, stage: Stage.Stage, withProps: Bool): List[Render.PlacedItem] =
        let (dx, dy) = Stage.shakeOffset(env#storyNow, Stage.ShakeTarget.Screen, stage);
        layered(env, photoRect(env#fit), stage, withProps) |> withCamera(env, stage) |> Render.movedAll({ x = dx, y = dy })

    /// タイトル画面の world の層: frame に、novel.backdrops.json の title（広げる倍率と漂い）を掛ける（無ければ frame のまま）。
    pub def titleFrame(env: View.Env, stage: Stage.Stage): List[Render.PlacedItem] =
        let items = frame(env, stage, true);
        match BackdropDoc.titleOf(env#res#backdrops) {
            case None    => items
            case Some(t) =>
                let s = View.realSeconds(env);
                let d = t#drift;
                let drift = { x = Num.sin(s * d#rate#x + d#phase#x) * d#amp#x, y = Num.sin(s * d#rate#y + d#phase#y) * d#amp#y };
                items |> Render.scaledAllAround(t#scale, { x = Layout.width(env#fit) * 0.5, y = Layout.height(env#fit) * 0.5 }) |> Render.movedAll(drift)
        }

    /// サムネの world の層: 画面ちょうどに塗り（揺れは掛けない）、z を 0..View.zThumbHudUnder()-1（0..8）に詰める
    /// （その上の 9 にゲームの hud の UnderWindow、字は z 10 から重ねる）。段が足りない時は奥の段から重ねて詰める（手前の覆い・小物・人物の前後は崩さない）。
    // WhyNot: 背景を揺れの分はみ出す backdropRect で塗らない —— 写真の面（Shader）は切り抜き（clippedAll）が効かず、枠の外へはみ出す。
    pub def thumbnail(env: View.Env, stage: Stage.Stage, withProps: Bool): List[Render.PlacedItem] =
        let items = layered(env, _ -> Layout.screen(env#fit), stage, withProps) |> withCamera(env, stage);
        let zs = items |> List.map(p -> zOf(p#item)) |> List.toSet |> Set.toList;
        let room = View.zThumbHudUnder();
        let skip = Int32.max(0, List.length(zs) - room);
        let ranks = zs |> List.zipWithIndex |> List.map(match (i, z) -> (z, Int32.max(0, i - skip))) |> List.toMap;
        items |> List.map(Render.overItem(mapZ(z -> Map.get(z, ranks) |> Option.getWithDefault(room - 1))))

    /// world の層の物を、層の数で並べて z を振った列（カメラと揺れの前）。areaOf = 写真の横÷縦（None は 16:9）→ 背景を塗る矩形。
    def layered(env: View.Env, areaOf: Option[Float64] -> Rect2.Rect2, stage: Stage.Stage, withProps: Bool): List[Render.PlacedItem] =
        let keep = (kind, entry) -> CastDoc.isAttachedToBackdrop(entry) or withProps or kind == CastDoc.Kind.Character;
        let actors = Cast.groupsWhere(castEnv(env, stage), keep, stage#cast, 0) |> List.map(match (n, items) -> { layer = n, order = 0, items = items });
        let game = GameView.draw(env, stage) |> List.map(match (n, item) -> { layer = n, order = 2, items = item :: Nil });
        let groups = { layer = 0, order = 0, items = backdropsIn(areaOf, env, stage) } :: actors :::
                     List.append(particleGroups(env, stage), overlayGroup(env, stage) :: blackoutGroup(env, stage) :: game);
        stacked(groups)

    // WhyNot: docs/z-bands.md の「z の付け替えをしない・ZStack で積む」に従わない — 立ち絵・粒・背景はグループの中の z（0..7）を数で持って描いてあり、
    //   GameView も (層の数, 物) で返すので、グループの順番から z の幅を割り当てる方が 1 か所で済む。グループの中の z が幅を超えた物は幅の端に丸める。
    /// グループを層の数の順に並べ、順番ごとに z の幅を割り当てる（並んだ同じ層の数と順のグループは同じ幅を使う）。
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
        let color = PropertyTween.nameAt(env#storyNow, Stage.overlayColorKey(), stage#props) |> Option.flatMap(Stage.overlayColorOf)
            |> Option.getWithDefault({ r = 0.0, g = 0.0, b = 0.0 });
        let onScreen = PropertyTween.nameAt(env#storyNow, Stage.overlayLayerKey(), stage#props) == Some("screen");
        if (alpha <= 0.0) None else Some((color, Float64.min(1.0, alpha), onScreen))

    /// 覆いの置き場が stage の時の world のグループ（揺れても端が覗かないよう背景と同じ矩形）。
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
    pub def zOf(item: Render.Item): Int32 = match item {
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

    /// 写真を敷く矩形（実際の画面）: aspect（横÷縦）を書いた写真は、揺れの分だけ大きい画面を覆うように比を保って真ん中に置く
    /// （はみ出しは捨てる。縦に長い still を横の画面でも縦の画面でも真ん中で切り抜く）。書いていない写真は backdropRect。
    // WhyNot: aspect の無い写真も覆う形にしない — 横の画面の 16:9 の写真が今の敷き方（画面に合わせて少し伸ばす）とずれ、描き出しの基準が全部替わる。
    pub def photoRect(fit: Layout.Fit): Option[Float64] -> Rect2.Rect2 = aspect -> match aspect {
        case None    => backdropRect(fit)
        case Some(a) =>
            let w = Layout.width(fit);
            let h = Layout.height(fit);
            let cw = w + 24.0;
            let ch = h + 24.0;
            let (rw, rh) = if (cw / ch > a) (cw, cw / a) else (ch * a, ch);
            { position = { x = (w - rw) / 2.0, y = (h - rh) / 2.0 }, size = { x = rw, y = rh } }
    }

    /// 背景を塗る（実際の画面は揺れの分だけはみ出す photoRect、サムネは画面ちょうど）。描く背景は Stage.shownShot（背景が無い間は initial）。
    pub def backdropsIn(areaOf: Option[Float64] -> Rect2.Rect2, env: View.Env, stage: Stage.Stage): List[Render.PlacedItem] =
        backdropsUsing(GameView.backdrop, areaOf, env, stage)

    /// backdropsIn の、ゲームの絵を paint から引く形（テストが差し替える）。
    /// 切り替えの間は、替え方（Stage の switch）ごとに前の背景（under）と今の背景を重ねる・送る・塗り替える。
    /// ゲームが持つ切り替え（switch#game）の間は重ねず、今の背景をそのまま描く（ゲームが under と進みから歩く絵を出す）。
    pub def backdropsUsing(paint: BackdropPainter, areaOf: Option[Float64] -> Rect2.Rect2, env: View.Env, stage: Stage.Stage): List[Render.PlacedItem] =
        let base = areaOf(None);
        let ground = View.at(base#position#x, base#position#y, RawDraw.box(base#size, Backdrop.groundOf(env#res#backdrops), 0));
        let p = Stage.fadeProgress(env#storyNow, stage);
        let photo = (shot: Option[Stage.Shot], dx: Float64, progress, z) -> shot
            |> Option.flatMap(s -> pictureOf(paint, env, stage, s, areaOf)) |> Option.map(match (picture, area) -> placed(picture, area, dx, progress, z))
            |> Option.getWithDefault(Nil);
        let current = Stage.shownShot(env#res#backdrops, stage);
        let under = if (p >= 1.0) None else stage#under;
        let shift = shiftOf(env, areaOf, stage);
        let width = shownWidth(env, areaOf, stage);
        let moved = match stage#switch#transition {
            case _ if Option.nonEmpty(stage#switch#game) and p < 1.0 => photo(current, 0.0, 1.0, View.zBackdropShot())
            case BackdropDoc.Transition.Black => if (p < 0.5 and not isFromDark(env, stage)) photo(under, 0.0, 1.0, View.zBackdropUnder()) else photo(current, 0.0, 1.0, View.zBackdropShot())
            case BackdropDoc.Transition.Slide => List.append(photo(under, shift - slideGap(env, areaOf, under, current, width), 1.0, View.zBackdropUnder()), photo(current, shift, 1.0, View.zBackdropShot()))
            case BackdropDoc.Transition.Pan   => List.append(photo(under, shift - width * panShare(), 1.0, View.zBackdropUnder()), photo(current, shift, p, View.zBackdropShot()))
            case BackdropDoc.Transition.Wipe  => List.append(photo(under, 0.0, 1.0, View.zBackdropUnder()), wiped(paint, env, areaOf, stage, current, p))
            case _                            => List.append(photo(under, 0.0, 1.0, View.zBackdropUnder()), photo(current, 0.0, p, View.zBackdropShot()))
        };
        ground :: moved

    /// 背景 shot の絵と塗る矩形: ゲームが描けばその絵、描かなければ写真（まだ届いていない・絵を持たない写真は None で、下の暗い地が見える）。
    def pictureOf(paint: BackdropPainter, env: View.Env, stage: Stage.Stage, shot: Stage.Shot, areaOf: Option[Float64] -> Rect2.Rect2): Option[(Picture, Rect2.Rect2)] =
        let area = areaOf(BackdropDoc.aspectOf(shot#photo, env#res#backdrops));
        match paint(env, stage, shot#photo, area) {
            case Some(items) => Some((Picture.Painted(items), area))
            case None        => if (BackdropDoc.isBlank(shot#photo, env#res#backdrops)) None else specOf(shot, env) |> Option.map(spec -> (Picture.Still(spec), area))
        }

    /// 絵を dx だけ横へずらし、濃さ progress で、z の幅 z..z+2 に置く。
    def placed(picture: Picture, area: Rect2.Rect2, dx: Float64, progress: Float64, z: Int32): List[Render.PlacedItem] = match picture {
        case Picture.Still(spec)    => Backdrop.surface(spec, { position = { x = area#position#x + dx, y = area#position#y } | area }, progress, z) :: Nil
        case Picture.Painted(items) =>
            let faded = if (progress >= 1.0) items else items |> List.map(Render.overItem(Render.fade(Float64.max(0.0, progress))));
            faded |> Render.movedAll({ x = dx, y = 0.0 }) |> List.map(Render.overItem(mapZ(n -> z + Int32.max(0, Int32.min(2, n)))))
    }

    /// 前の背景（stage#under。切り替えの間だけ持つ）が絵を持たないか: 無い・novel.backdrops.json で blank の写真。
    /// black の切り替えは、この時は前半の暗くなる側を飛ばし、暗い所から全部の秒で明ける。
    // WhyNot: GameView.backdrop が blank の写真に絵を描くかまでは見ない — blackoutGroup は描く元（paint）を持たず、
    //   blank の写真に絵を描くゲームは blank を外せば前半の暗転が戻る。
    def isFromDark(env: View.Env, stage: Stage.Stage): Bool =
        stage#under |> Option.forAll(s -> BackdropDoc.isBlank(s#photo, env#res#backdrops))

    /// transition=black の暗転のグループ: 前半は暗くなり、後半は明ける（前の背景が絵を持たない時は、暗い所から全部の秒で明ける）。
    /// 背景だけでなく人物・粒・GameView も暗くするので、覆いと同じ層の数に置く。
    // WhyNot: 前の背景が絵を持たない時も半分の秒を暗くなる側に使わない — 暗い地がもっと暗くなるだけで、秒の半分は何も変わらない画面になる。
    def blackoutGroup(env: View.Env, stage: Stage.Stage): Group =
        let p = Stage.fadeProgress(env#storyNow, stage);
        let dark = if (isFromDark(env, stage)) 1.0 - p else if (p < 0.5) 2.0 * p else 2.0 * (1.0 - p);
        let items = if (stage#switch#transition != BackdropDoc.Transition.Black or p >= 1.0 or dark <= 0.0) Nil
                    else {
                        let r = backdropRect(env#fit);
                        View.at(r#position#x, r#position#y, RawDraw.box(r#size, Backdrop.groundOf(env#res#backdrops), 1) |> Render.fade(Float64.min(1.0, dark))) :: Nil
                    };
        { layer = View.kindOf(env)#overlayLayer, order = 3, items = items }

    /// 背景 shot を塗る矩形（areaOf に写真の aspect を渡した物）。
    def areaOfShot(env: View.Env, areaOf: Option[Float64] -> Rect2.Rect2, shot: Option[Stage.Shot]): Option[Rect2.Rect2] =
        shot |> Option.map(s -> areaOf(BackdropDoc.aspectOf(s#photo, env#res#backdrops)))

    /// 今の背景を塗る矩形の幅（背景が無ければ aspect の無い写真の幅）。
    def shownWidth(env: View.Env, areaOf: Option[Float64] -> Rect2.Rect2, stage: Stage.Stage): Float64 =
        areaOfShot(env, areaOf, Stage.shownShot(env#res#backdrops, stage)) |> Option.getWithDefault(areaOf(None)) |> (r -> r#size#x)

    /// slide で前の写真を今の写真より左へ置く距離: 前の写真の右の縁が今の写真の左の縁に接する（どちらかが無ければ width）。
    def slideGap(env: View.Env, areaOf: Option[Float64] -> Rect2.Rect2, under: Option[Stage.Shot], current: Option[Stage.Shot], width: Float64): Float64 =
        let gap = forM (u <- areaOfShot(env, areaOf, under); c <- areaOfShot(env, areaOf, current)) yield u#position#x + u#size#x - c#position#x;
        Option.getWithDefault(width, gap)

    /// pan で写真が流れる距離（背景の幅に対する割合）。
    // WhyNot: 写真を幅いっぱい流さない — 流しながら重ねるので、幅いっぱいだと前の写真が半分見えたまま新しい写真が透けて二重に見える。
    def panShare(): Float64 = 0.25

    /// 今の写真が横へずれている量（px）: slide は右から今の写真の幅いっぱい、pan は panShare だけ寄ってくる。ほかは 0。
    // WhyNot: 距離を aspect の無い写真の矩形（backdropRect）の幅で決めない — 縦の画面のそれは 16:9 で画面の 3 倍ほど広く、
    //   aspect を書いた縦長の写真（画面の幅ほど）は送りの大半を画面の外で過ごし、暗い地が見える。
    def shiftOf(env: View.Env, areaOf: Option[Float64] -> Rect2.Rect2, stage: Stage.Stage): Float64 =
        let p = Stage.fadeProgress(env#storyNow, stage);
        let width = shownWidth(env, areaOf, stage);
        match stage#switch#transition {
            case BackdropDoc.Transition.Slide => (1.0 - p) * width
            case BackdropDoc.Transition.Pan   => (1.0 - p) * width * panShare()
            case _                            => 0.0
        }

    /// 今の背景を左から p の割合まで塗る（wipe）。ゲームが描いた絵は塗り分けられないので、濃さ p で重ねる。
    def wiped(paint: BackdropPainter, env: View.Env, areaOf: Option[Float64] -> Rect2.Rect2, stage: Stage.Stage, shot: Option[Stage.Shot], p: Float64): List[Render.PlacedItem] =
        shot |> Option.flatMap(s -> pictureOf(paint, env, stage, s, areaOf)) |> Option.map(match (picture, area) -> wipedPicture(picture, area, p))
            |> Option.getWithDefault(Nil)

    /// 背景 1 枚を左から p の割合まで塗る（ゲームが描いた絵は塗り分けられないので、濃さ p で重ねる）。
    def wipedPicture(picture: Picture, area: Rect2.Rect2, p: Float64): List[Render.PlacedItem] = match picture {
        case Picture.Still(spec) =>
            let edge = area#position#x + area#size#x * p;
            let x0 = area#position#x;
            let y0 = area#position#y;
            let y1 = area#position#y + area#size#y;
            Render.shaderFillMasked(spec, area, ({ x = x0, y = y0 } :: { x = edge, y = y0 } :: { x = edge, y = y1 } :: { x = x0, y = y1 } :: Nil) :: Nil, 1.0, View.zBackdropShot()) :: Nil
        case Picture.Painted(_)  => placed(picture, area, 0.0, p, View.zBackdropShot())
    }

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
                and propsOnPage(env, r#stage)
        case _ => false
    }

    /// 小物を頁の幕の上に描く舞台か: 頁に幕があり、文字の枠を消す絵（novel.cast.json の hideWindow）が出ていない。
    // WhyNot: 文字の枠を消す絵が出ている間も頁に描かない — 枠と一緒に頁の小物まで消え、hideWindow の小物そのものが見えなくなる。
    pub def propsOnPage(env: View.Env, stage: Stage.Stage): Bool = hasPageVeil(env, stage) and not Cast.hidesWindow(env#res#cast, stage#cast)

    /// 頁に幕がある（横の NVL・縦の画面は NVL も ADV も頁）。
    pub def hasPageVeil(env: View.Env, stage: Stage.Stage): Bool = Layout.isPortrait(env#fit) or Stage.kindOf(env#res#theme, stage) == ThemeDoc.WindowKind.Nvl

    /// tap の当たる物（novel.prompts.json の targets）の名前 → 画面の矩形。写真に載る物は背景を塗る矩形、絵に載る物は出ている絵の置き場から引く。
    pub def targetRectOf(env: View.Env, stage: Stage.Stage): String -> Option[Rect2.Rect2] =
        let photo = Stage.shownShot(env#res#backdrops, stage) |> Option.map(s -> (s#photo, photoRect(env#fit)(BackdropDoc.aspectOf(s#photo, env#res#backdrops))));
        let placed = Cast.placedOf(castEnv(env, stage), stage#cast) |> List.map(p -> (p#figure#name, p#rect)) |> List.toMap;
        name -> Hint.targetRect(env#res#prompts, photo, a -> Map.get(a, placed), name)

    /// 立ち絵と小物の描く元。掛ける色は背景の時間帯の cast の欄（無い時間帯・背景が無い時は絵のまま）を、背景の重ねと同じ進みで替える。
    pub def castEnv(env: View.Env, stage: Stage.Stage): Cast.Env =
        let toneOf = (shot: Option[Stage.Shot]) -> shot
            |> Option.flatMap(s -> BackdropDoc.gradeOf(s#grade, env#res#backdrops) |> Option.flatMap(g -> g#cast) |> Option.map(Cast.toneOf(s#grade)))
            |> Option.getWithDefault(Cast.plainTone());
        let progress = Stage.fadeProgress(env#storyNow, stage);
        let shown = Stage.shownShot(env#res#backdrops, stage);
        let light = if (progress >= 1.0) Cast.steadyLight(toneOf(shown)) else { previous = toneOf(stage#under), current = toneOf(shown), progress = progress };
        { doc = env#res#cast, fit = env#fit, storyNow = env#storyNow, realNow = env#realNow, missing = env#res#missing, light = light,
          props = stage#props, photo = shown |> Option.map(s -> s#photo), backdropShift = shiftOf(env, photoRect(env#fit), stage) }

    // ── パーティクル（蛍・雪） ──

    /// 粒の演出のグループ: 止めるまで出ている物（<<fx 名>>）と、一度だけ出ている物（<<fx 名 once=true>>。だんだん薄くなる）。
    /// 層の数と描き方は novel.effects.json。点（「絵.点」）から出す粒は、その絵が出ていなければ描かない。
    def particleGroups(env: View.Env, stage: Stage.Stage): List[Group] =
        let doc = env#res#effects;
        let at = key -> PropertyTween.nameAt(env#storyNow, key, stage#props);
        let steadyAt = at(Stage.particlesAtKey());
        let steady = Stage.particlesOf(env#storyNow, stage) |> Option.flatMap(n -> EffectsDoc.particleOf(n, doc))
            |> Option.map(p -> { layer = p#layer, order = 1, items = particlesOf(env, stage, steadyAt, None, p#look) }) |> Option.toList;
        let fading = (name, p: EffectsDoc.Particle) -> PropertyTween.triggerSpanAt(env#storyNow, Stage.fxOnceKey(name), stage#props)
            |> Option.map(match (since, seconds) -> {
                let left = if (seconds <= 0.0) 0.0 else 1.0 - since / seconds;
                { layer = p#layer, order = 1, items = particlesOf(env, stage, at(Stage.fxOnceAtKey(name)), Some(since), p#look) |> List.map(Render.overItem(Render.fade(left))) }
            });
        let once = EffectsDoc.rec(doc)#particles |> Map.toList |> List.filterMap(match (name, p) -> fading(name, p));
        List.append(steady, once)

    /// 描き方 look の粒。point = 出す点（「絵.点」）、since = 一度だけ出す物の始まってからの秒（止めるまで出す物は None で実時間）。
    def particlesOf(env: View.Env, stage: Stage.Stage, point: Option[String], since: Option[Float64], look: EffectsDoc.Look): List[Render.PlacedItem] = match look {
        case EffectsDoc.Look.Fireflies => fireflies(env)
        case EffectsDoc.Look.Snow      => snow(env, stage)
        case EffectsDoc.Look.Puff(k)   =>
            originOf(env, stage, point) |> Option.map(o -> puff(env, k, o, since)) |> Option.getWithDefault(Nil)
    }

    /// 粒を出す点の画面の位置: 「絵.点」ならその絵の markers の点（絵が出ていなければ None）、None なら画面の真ん中。
    def originOf(env: View.Env, stage: Stage.Stage, point: Option[String]): Option[{ x = Float64, y = Float64 }] = match point {
        case None    => Some({ x = Layout.width(env#fit) / 2.0, y = Layout.height(env#fit) / 2.0 })
        case Some(p) => markerOriginOf(env, stage, p)
    }

    def markerOriginOf(env: View.Env, stage: Stage.Stage, point: String): Option[{ x = Float64, y = Float64 }] = match String.splitOn(substr = ".", point) {
        case name :: dot :: Nil => Cast.markerPointOf(castEnv(env, stage), stage#cast, name, dot)
        case _                  => None
    }

    /// 立ちのぼる粒: 点から 1 粒ずつ時をずらしてのぼり、横に少し揺れながら life 秒で薄れて消える。番号と時刻だけから位置を導く（保存しない）。
    /// 一度だけ出す物は始まってからの秒で、まだ出ていない粒（時をずらした分）は描かない。
    def puff(env: View.Env, k: EffectsDoc.Puff, origin: { x = Float64, y = Float64 }, since: Option[Float64]): List[Render.PlacedItem] =
        let ink = Color.lighten(View.theme(env)#ink, 0.4);
        let t = since |> Option.getWithDefault(View.realSeconds(env));
        Fx.derive(k#count, t, (_i, rand, now) -> {
            let delay = rand(0) * k#life;
            let raw = now - delay;
            let age = if (Option.isEmpty(since)) raw - k#life * Float64.floor(raw / k#life) else raw;
            let x = origin#x + (rand(1) - 0.5) * k#spread + Num.sin(now * (2.0 + rand(2) * 2.0) + rand(3) * 6.28) * k#spread * 0.2;
            { x = x, y = origin#y - age * k#rise, r = k#size * (0.6 + rand(4) * 0.8), a = if (age < 0.0 or age > k#life) 0.0 else 1.0 - age / k#life }
        }) |> List.filter(b -> b#a > 0.01) |> List.flatMap(b ->
            Render.glowAt({ x = b#x, y = b#y }, b#r * 3.0, ink, { alpha = 0.35 * b#a, blend = DrawCmd.BlendMode.Add }, 3)
            |> List.append(RawDraw.circleAt({ x = b#x, y = b#y }, b#r, ink, 4) |> Render.overItem(item -> Render.fade(b#a, item)) :: Nil))

    /// 蛍: 番号と実時間だけから位置と明滅を導く（どこにも保存しない = 巻き戻しても同じ絵）。
    /// 草むらの高さ（画面の下 6 割）をゆっくり漂い、息をするように明滅する。
    def fireflies(env: View.Env): List[Render.PlacedItem] =
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
