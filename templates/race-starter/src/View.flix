// View — World から「(置き場所, 見せたい物) のリスト」への投影（純粋）。
// 疑似遠近の海岸ハイウェイ・車たち・HUD・場面ごとの幕を、World を読むだけで絵にする。
// 投影の数学は Proj、背景と景色は ViewScene、道は ViewRoad、車と粒は ViewCar に分け、
// ここは束ねと HUD/幕だけを持つ。
//
// ── この画面の画風（AGENTS.local.md と同じ宣言）──
// 「真夏の海岸ハイウェイ。空は青く、海は光り、路面は白く灼けている。
//   速さは流れる景色とタイヤ痕で、危険は膨らむ白煙で見せる」。
//   色は 3 つ: コバルトの空 / 灼けたアスファルト / 縁石の赤。
//   やらないこと: 暗がりや霧で誤魔化さない（主役の分離は影の仕事）。
// **これは数ある画風の 1 つでしかない。** 真似してほしいのは「層に分けて、各層に役割を
// 持たせる」組み方の方で、色や効果ではない。別の作り方の例は `.claude/skills/visual-dict`。
//
// ── 画面の層（奥から手前へ。z が大きいほど手前）と「絵の下限」4 性質の受け持ち ──
//    0.. 2  空(ViewScene)       … 面の階調（空のグラデ）・時間（流れる雲）
//    3      遠景の岬(ViewScene) … 層（水平線の向こうの陸）・面の階調（頂は明るく裾は霞む）
//    4.. 5  海(ViewScene)       … 時間（きらめきの明滅）・面の階調（水平線ぎわの輝き）
//    6      地面のセグメント(ViewRoad)・丘の向こうの平野(ViewScene) … 面の階調（明暗の波 + 遠くの霞み）
//    7      草の筋(ViewRoad)・浜(ViewScene) … 面の質感（道に沿う縦の筋）・層（海と地面の継ぎ）
//    8..10  路面・縁石・白線・スタートライン・ガードレール(ViewRoad) … 層（道が地面から分かれる）
//   10      タイヤ痕(ViewRoad)  … 時間（走った軌跡が残る）
//   20..76  立ち物: ヤシ・低木・標識(ViewScene)・障害物/アイテム(ViewRoad)・車(ViewCar)
//                                … 主役の分離（足元の影）。近い物ほど手前（Proj.zOf）
//   69..82  煙・炎・火の玉・閃光(ViewCar) … 時間・危険の表示（fx の z + 60）
//   85      速度線(ViewScene)   … 時間（速さが線になる）
//   90      HUD / 100 幕（この View）
//
// View は fail-open: コースが空でも Doc が既定でも必ず何か描く（プレイヤーの前で白画面にしない）。
mod View {

    def zHud(): Int32 = 90
    def zOverlay(): Int32 = 100

    /// 1 フレームの絵。カメラの注視 x を最初に 1 回だけ決め、全層で共有する
    /// （層ごとに計算すると、丸めの差で道と車が別のカメラを見てしまう）。
    /// HUD と幕は withHudView 側（hud）— 揺れも掛からず、world の z にも隠されない。
    pub def frame(_ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        let cam = Proj.camOf(w);
        let shake = ViewCar.shakeOf(w);
        // 揺れは世界の層だけに掛ける。HUD と幕まで揺らすと、読ませたい文字が読めなくなる。
        // 揺れていないときに掛けないのは、掛けると置き場所を 1 つずつ作り直すため —
        // 走っている画面の描く物は数千個あり、0 を足すためだけに全部を組み直すことになる。
        let moved = items ->
            if (shake#x == 0.0 and shake#y == 0.0) items
            else Render.movedAll(shake, items);
        moved(List.flatten(
               ViewScene.sky(cam, w)
            :: ViewScene.sea(cam, w)
            :: ViewScene.plain(cam, w)
            :: ViewRoad.draw(cam, w)
            :: ViewScene.outfield(cam, w)
            :: ViewScene.palms(cam, w)
            :: ViewCar.rivals(cam, w)
            :: ViewCar.player(cam, w)
            :: ViewCar.bursts(cam, w)
            :: ViewScene.speedLines(cam, w)
            :: Nil))

    /// 画面固定の絵（HUD のチップ・場面ごとの幕）。App.withHudView へ繋ぐ。
    pub def hud(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        hudChips(ctx#atlas, w) ::: overlay(ctx#atlas, w)

    // ── HUD（Racing のときだけ） ──

    def hudChips(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        if (w#phase != World.Phase.Racing) Nil
        else rankChip(atlas, w) ::: statusChips(atlas, w) ::: nitroGauge(atlas, w)

    /// HUD の文字色。白チップの上に濃紺 — 空や路面のどこに重なっても読める組み合わせ。
    def hudInk(w: World.World): Color =
        Color.darken(ThemeDoc.rec(w#theme)#sea, 0.5)

    /// 左上のチップ: 順位（大きく）・周回・スコア。順位が一番大きいのは、
    /// このゲームで刻々変わる一番大事な数だから。
    def rankChip(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let ink = hudInk(w);
        let chip = RawDraw.boxAt({ x = 40.0, y = 28.0 }, { x = 66.0, y = 46.0 },
                ThemeDoc.rec(w#theme)#text, zHud())
            |> Render.overItem(Render.fade(0.9));
        let lapShow = Int32.min(w#lap + 1, RulesDoc.rec(w#rules)#totalLaps);
        chip
            :: { at = { x = 13.0, y = 10.0 },
                 item = Render.textTinted(ordinalOf(w#rank), atlas, 14.0, ink, zHud() + 1) }
            :: { at = { x = 13.0, y = 29.0 },
                 item = Render.textTinted(
                     "LAP ${Int32.toString(lapShow)}/${Int32.toString(RulesDoc.rec(w#rules)#totalLaps)}",
                     atlas, 8.0, ink, zHud() + 1) }
            :: { at = { x = 13.0, y = 40.0 },
                 item = Render.textTinted("SCORE ${Int32.toString(w#score)}",
                     atlas, 8.0, ink, zHud() + 1) }
            :: Nil

    /// 順位の英語表記（1st/2nd/3rd/4th…）。数字だけより「勝負の位置」として読める。
    def ordinalOf(rank: Int32): String =
        match rank {
            case 1 => "1st"
            case 2 => "2nd"
            case 3 => "3rd"
            case _ => "${Int32.toString(rank)}th"
        }

    /// 右上の状態チップ。ドリフト中は赤の「DRIFT!」、スリップストリーム中は青の「SLIP+」。
    /// 同時なら縦に並べる（どちらもゲージが貯まる合図 — 重ねて片方を隠さない）。
    def statusChips(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let drift = if (w#drifting) chipAt(atlas, w, "DRIFT!", ThemeDoc.rec(w#theme)#kerb, 14.0) else Nil;
        let slipY = if (w#drifting) 32.0 else 14.0;
        let slip = if (World.slipActive(w)) chipAt(atlas, w, "SLIP+", ThemeDoc.rec(w#theme)#rivalA, slipY) else Nil;
        drift ::: slip

    /// 白チップ + 色文字の小さなラベル 1 枚。
    def chipAt(atlas: FontAtlas, w: World.World, label: String, ink: Color, y: Float64): List[Render.PlacedItem] =
        let cx = 204.0;
        let back = RawDraw.boxAt({ x = cx, y = y }, { x = 58.0, y = 15.0 }, ThemeDoc.rec(w#theme)#text, zHud())
            |> Render.overItem(Render.fade(0.85));
        back
            :: TextDraw.centered({ text = label, atlas = atlas, size = 10.0, color = ink,
                                   z = zHud() + 1, centerX = cx, y = y - 5.0 })
            :: Nil

    /// 下部中央のニトロゲージ。外枠の白チップ + 中身のバー（貯まるほど炎の芯の色へ寄る）。
    /// 満タンになったら光らせて「Z」を明滅 — ボタンを押して良い瞬間を画面が教える。
    def nitroGauge(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let cy = 337.0;
        let frameChip = RawDraw.boxAt({ x = 120.0, y = cy }, { x = 128.0, y = 13.0 },
                ThemeDoc.rec(w#theme)#text, zHud())
            |> Render.overItem(Render.fade(0.9));
        let barW = 118.0 * Num.clamp01(w#nitro);
        let bar = if (barW < 0.5) Nil
            else RawDraw.boxAt({ x = 61.0 + barW / 2.0, y = cy }, { x = barW, y = 7.0 },
                    Color.mix(ThemeDoc.rec(w#theme)#flame, ThemeDoc.flameCore(w#theme), w#nitro),
                    zHud() + 1) :: Nil;
        let ready = if (w#nitro < 1.0) Nil
            else {
                let pulse = 0.5 + 0.5 * Sway.wave(w#t, 0.0, 1.2);
                Render.glowAt({ x = 120.0, y = cy }, 16.0, ThemeDoc.rec(w#theme)#flame,
                        { alpha = 0.35, blend = DrawCmd.BlendMode.Add }, zHud())
                    ::: (TextDraw.centered({ text = "Z", atlas = atlas, size = 10.0,
                            color = Color.mix(ThemeDoc.rec(w#theme)#text, ThemeDoc.rec(w#theme)#flame, pulse),
                            z = zHud() + 2, centerX = 120.0, y = 318.0 }) :: Nil)
            };
        frameChip :: (bar ::: ready)

    // ── 場面ごとの幕（Title / Win / Lose） ──

    def overlay(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        match w#phase {
            case World.Phase.Racing => Nil
            case World.Phase.Title  => titleOverlay(atlas, w)
            case World.Phase.Win    => winOverlay(atlas, w)
            case World.Phase.Lose   => loseOverlay(atlas, w)
        }

    /// タイトル。幕は薄め（0.25）— 空と海と走る景色がサムネの顔なので、隠しすぎない。
    def titleOverlay(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let pulse = 0.5 + 0.5 * Sway.wave(w#t, 0.0, 0.5);
        let lines =
               centered(atlas, "ARROWS STEER / X DRIFT", 9.0, ThemeDoc.rec(w#theme)#text, 176.0)
            :: centered(atlas, "Z NITRO WHEN FULL", 9.0, ThemeDoc.rec(w#theme)#text, 190.0)
            :: centered(atlas, "PRESS SPACE", 11.0,
                   Color.mix(ThemeDoc.hazeTo(w#theme), ThemeDoc.rec(w#theme)#lane, 0.35 + 0.65 * pulse), 240.0)
            :: Nil;
        curtain(w#theme, 0.25) :: (titleWord(atlas, w, "RACE", 26.0, 116.0) ::: lines)

    /// タイトルの見出し 1 語。落ち影 → 白の縁取り → 車体色の芯の 3 枚重ね。
    /// ベタ塗り 1 枚だと、走る草地の緑と赤が同じ明るさで隣り合って文字が沈む。
    def titleWord(atlas: FontAtlas, w: World.World, s: String, size: Float64,
                  y: Float64): List[Render.PlacedItem] =
        let cx = World.designW() / 2.0;
        let put = color -> z -> off ->
            TextDraw.centered({ text = s, atlas = atlas, size = size, color = color,
                                z = z, centerX = cx + off#dx, y = y + off#dy });
        let ring =
               { dx = -1.7, dy =  0.0 } :: { dx =  1.7, dy =  0.0 }
            :: { dx =  0.0, dy = -1.7 } :: { dx =  0.0, dy =  1.7 }
            :: { dx = -1.2, dy = -1.2 } :: { dx =  1.2, dy = -1.2 }
            :: { dx = -1.2, dy =  1.2 } :: { dx =  1.2, dy =  1.2 }
            :: Nil;
        let shadow = put(Color.darken(ThemeDoc.rec(w#theme)#sea, 0.55))(zOverlay() + 1)({ dx = 2.5, dy = 3.5 });
        let edge = ring |> List.map(put(ThemeDoc.rec(w#theme)#finish)(zOverlay() + 2));
        let core = put(ThemeDoc.rec(w#theme)#player)(zOverlay() + 3)({ dx = 0.0, dy = 0.0 });
        shadow :: (edge ::: (core :: Nil))

    /// 完走（最下位以外）。市松のストリップで「ゴールを切った」ことを形でも祝う。
    def winOverlay(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        curtain(w#theme, 0.45)
            :: checkerStrip(w#theme)
            :: centered(atlas, "FINISH!", 24.0, ThemeDoc.rec(w#theme)#finish, 124.0)
            :: centered(atlas, "RANK ${ordinalOf(w#rank)}", 12.0, ThemeDoc.rec(w#theme)#text, 166.0)
            :: centered(atlas, "SCORE ${Int32.toString(w#score)}", 12.0, ThemeDoc.rec(w#theme)#text, 186.0)
            :: centered(atlas, "PRESS SPACE", 10.0, Color.darken(ThemeDoc.rec(w#theme)#text, 0.25), 226.0)
            :: Nil

    /// 最下位で完走。順位を小さく見せてから LOSE — 責める色（縁石の赤）は 1 語だけに使う。
    def loseOverlay(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        curtain(w#theme, 0.5)
            :: centered(atlas, "${ordinalOf(w#rank)}...", 12.0, ThemeDoc.rec(w#theme)#text, 118.0)
            :: centered(atlas, "LOSE", 24.0, ThemeDoc.rec(w#theme)#kerb, 140.0)
            :: centered(atlas, "SCORE ${Int32.toString(w#score)}", 12.0, ThemeDoc.rec(w#theme)#text, 186.0)
            :: centered(atlas, "PRESS SPACE", 10.0, Color.darken(ThemeDoc.rec(w#theme)#text, 0.25), 226.0)
            :: Nil

    /// ゴールの市松帯（Win の飾り）。白帯に市松の穴を開けるだけで「ゴール」と読める。
    def checkerStrip(theme: ThemeDoc.Doc): Render.PlacedItem =
        { at = { x = 0.0, y = 96.0 },
          item = RawDraw.box({ x = World.designW(), y = 12.0 }, ThemeDoc.rec(theme)#finish, zOverlay() + 1)
              |> Render.checker({ color = Color.darken(ThemeDoc.rec(theme)#sea, 0.4), alpha = 1.0, cell = 6.0 })
              |> Render.fade(0.92) }

    /// 画面全体を覆う紺の幕（幕の上に文字を載せて読みやすくする）。
    /// 黒でなく海の紺を使うのは、幕の下でも真夏の画面のままでいるため。
    def curtain(theme: ThemeDoc.Doc, alpha: Float64): Render.PlacedItem =
        { at = { x = 0.0, y = 0.0 },
          item = RawDraw.box({ x = World.designW(), y = World.designH() },
                     Color.darken(ThemeDoc.rec(theme)#sea, 0.35), zOverlay())
              |> Render.fade(alpha) }

    /// 画面中央に 1 行のテキストを置く（幅はエンジンが実測して中央へ揃える）。
    def centered(atlas: FontAtlas, s: String, size: Float64, color: Color, y: Float64): Render.PlacedItem =
        TextDraw.centered({ text = s, atlas = atlas, size = size, color = color,
                            z = zOverlay() + 2, centerX = World.designW() / 2.0, y = y })
}
