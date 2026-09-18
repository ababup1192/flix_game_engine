// SceneRender — ゲーム画面を画面なしで PNG に生成する（スナップショット比較・目視批評用）。
// 実行: make render-all → gallery/title.png .. gallery/s7_bar.png
//       make render SHOT=s1_drift → debug/s1_drift.png（1 枚だけ）
// すべて決定的な場面（時計 t は場面ごとに固定値を入れる — 実時間も乱数も見ない）。
// World を直接組み、実機と同じ描画経路（View.frame → Render.draw → HeadlessRender.renderPng）で生成する。
mod SceneRender {
    import java.io.File
    import java.lang.System

    def design(): Vec2.Vec2 = { x = 240.0, y = 360.0 }

    def ttf(): String = "assets/Xolonium-Regular.ttf"

    def cfgOf(outDir: String, atlas: FontAtlas, bg: Color): HeadlessRender.RenderConfig =
        { design = design(), scale = 2, background = bg,
          fontTtf = ttf(), fontAtlas = atlas,
          // 縁のつまみは既定のまま。ドット絵（車・椰子・コーン）は PxSpriteAtlas に
          // まとめてテクスチャとして貼るので、面の縁のつまみは元から届かない。
          // 届くのは疑似遠近の路面（行ごとに小数位置が変わる台形）だけで、そこは
          // 画素の格子に乗らない絵 — 切っても宣言した色数には収まらず（実測 6952 → 3146 色）、
          // 縁石と路肩が粗い階段になるだけになる。
          outDir = outDir, frameW = 480, frameH = 720 | HeadlessRender.defaults() }

    def loadWorld(): World.World \ IO =
        run { World.initial(Controls.loadDocs()) } with Fs.FileRead.runWithIO

    pub def all(): Unit \ IO =
        discard allShots()

    /// 描き出せる場面の名前。make render の使い方も SHOT の当たり判定も、この並びが source of truth。
    /// 場面の題と一言（Studio のギャラリーに出るラベル）は assets/*.scenes.json 側で、
    /// name をここの名前とそろえる。ラベルを足しても描き出す場面は増えない。
    pub def shotNames(): List[String] =
        "title" :: "s1_drift" :: "s2_nitro" :: "s3_crash" :: "s4_uturn"
            :: "s5_gate" :: "s6_rail" :: "s7_bar" :: Nil

    /// 名前 → その場面の World。shotNames と対で保つ。名前で引く形にしてあるので、
    /// SHOT で 1 枚だけ生成するときに残りの場面は組まない。
    def sceneOf(name: String, w0: World.World): Option[World.World] =
        match name {
            // title: ジャンルカードの顔（Title 画面）。Studio が reference/title.png を /genesis/title で
            // 読み、「レース」のジャンルカードのサムネイルにする（各 starter 共通の規約）。
            case "title"    => Some({ t = 2.2 | w0 })
            // s1: S 字をドリフト中（タイヤ痕・白煙・ゲージ半分）。この絵が遊びの顔。
            case "s1_drift" => Some(driftScene(w0))
            // s2: 直線でニトロ発動中（炎とスピード感・前方にライバル 1 台）。
            case "s2_nitro" => Some(nitroScene(w0))
            // s3: 障害物に当たった直後（スピン中・閃光と火花）。
            case "s3_crash" => Some(crashScene(w0))
            // s4: 左の U 字の入口（道が巻き込んで画面の外へ消える所）。急カーブの絵の顔。
            case "s4_uturn" => Some(uturnScene(w0))
            // s5: 登りの頂上ぎわで土管ゲートへ差し掛かる所（坂とゲートの絵の顔）。
            case "s5_gate"  => Some(gateScene(w0))
            // s6: 左 U 字の外側のガードレールに擦り付けて曲がっている所（火花が散る）。
            case "s6_rail"  => Some(railScene(w0))
            // s7: 長い直線の振り子バーが左へ振れきる手前（残った右の隙間を抜けに行く所）。
            case "s7_bar"   => Some(barScene(w0))
            case _          => None
        }

    /// SceneRender.all の中身。生成した PNG のパス列を返す — 走行中のゲームへの POST /render も呼ぶ。
    /// 効果音も同じ入口で生成する（絵と音を別の手順にしない）。返すのは目で見る物だけなので
    /// WAV はパス列に載せない。1 枚だけ描き出す one() では鳴らす物は作り直さない。
    pub def allShots(): List[String] \ IO =
        run { SfxRender.renderAll() } with Fs.FileRead.runWithIO;
        shotsInto("gallery", _ -> true)

    /// SHOT で指した場面だけを debug/ へ生成する（スナップショットを汚さない）。
    /// 実行: make render SHOT=s1_drift
    pub def one(): Unit \ IO =
        let wanted = envOr("SHOT", "") |> String.splitOn(substr = " ")
            |> List.map(String.trim) |> List.filter(n -> not String.isEmpty(n));
        let known = List.toSet(shotNames());
        let unknown = wanted |> List.filter(n -> not Set.memberOf(n, known));
        if (List.isEmpty(wanted) or not List.isEmpty(unknown)) {
            println("[render] 描けない名前です: ${List.join(" ", unknown)}");
            println("[render] SHOT=<場面> に使えるのは: ${List.join(" ", shotNames())}");
            System.exit(1)
        } else {
            let picked = List.toSet(wanted);
            discard shotsInto("debug", n -> Set.memberOf(n, picked))
        }

    /// keep が真を返す場面だけを outDir へ生成し、そのファイルパス列を返す。
    def shotsInto(outDir: String, keep: String -> Bool): List[String] \ IO =
        discard (new File(outDir)).mkdirs();
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let w0 = loadWorld();
        // 実機が GPU へ上げるのと同じアトラス画素を PNG に落とし、regionRect 付き Sprite を
        // 解決できる texInfo を組む（生成は PNG からしか絵を読めない）。
        let images = PxSpriteAtlas.asImages(
            { texture = World.atlasName(), baked = w0#atlas } :: Nil);
        let cfg = { texturePath = HeadlessRender.imagePngs("debug", images)
                    | cfgOf(outDir, atlas, ThemeDoc.rec(w0#theme)#grass) };
        let texInfo = HeadlessRender.imageTextureInfo(images);
        let ctx = App.viewCtxOf(atlas, design());
        shotNames() |> List.filter(keep) |> List.filterMap(name ->
            sceneOf(name, w0) |> Option.map(w -> shoot(cfg, texInfo, ctx, w, name)))

    def envOr(key: String, fallback: String): String \ IO =
        let value = System.getenv(key);
        if (Object.isNull(value)) fallback else value

    // ── 決定的な場面の脚本（乱数を回さず World を直接組む） ──
    // 立ち位置は「道の中心からの横ずれ（px）」で書く。区間表を差し替えても、
    // 車は道の上の同じ所に乗ったままになる。

    /// 右への切り込み（通し行 22〜24）をドリフト中: 道の中心より外側で車が傾き、
    /// 後ろへタイヤ痕が伸び、白煙が続けて膨らんでいる。ゲージは半分強（貯まっていく途中の絵）。
    def driftScene(w0: World.World): World.World =
        let started = World.startGame(w0);
        let dist = World.rowPitch() * 22.5;
        let pd = dist + World.playerAheadPx();
        let off = 0.0 - 16.0;
        // ライバル 2 台を前方 60px / 130px の道の中心に。残りは後方（抜いた扱い）。
        let rivals = started#rivals |> List.zipWithIndex |> List.map(entry -> {
            let (i, r) = entry;
            if (i == 0)      { progress = pd + 60.0, off = 6.0 | r }
            else if (i == 1) { progress = pd + 130.0, off = 0.0 - 8.0 | r }
            else             { progress = pd - 70.0, off = 0.0, passed = true | r }
        });
        // タイヤ痕: 4px 刻みで後ろへ、外側へ少しずつ流れた跡。
        let skids = List.range(0, 8) |> List.map(i -> {
            let k = Int32.toFloat64(i);
            ({ dist = pd - 4.0 * k, off = off - 1.2 * k, turn = 0.06 }: World.Skid)
        });
        // 白煙: World と同じ 0.09 秒間隔で焚かれた続き物。数を実機の湧き方に合わせないと、
        // ギャラリーの絵だけ煙が薄い（滑っている絵に見えない）。
        let sceneT = 1.7;
        let bursts = List.range(0, 9) |> List.map(i -> {
            let k = Int32.toFloat64(i);
            Fx.burst(w0#fx#smoke, i + 1, { x = off - 5.0 - 1.1 * k, y = pd - 12.0 - 6.0 * k },
                     sceneT - 0.09 * k)
        });
        { phase = World.Phase.Racing, t = sceneT, distance = dist, playerOff = off,
          speed = RulesDoc.rec(w0#rules)#forwardSpeed, drifting = true, steerDir = 1.0,
          nitro = 0.55, rank = 2, score = 300,
          rivals = rivals, skids = skids, bursts = bursts, fxSeq = 10 | started }

    /// 長い直線（区間 17・通し行 31〜34）でニトロ発動中: 発動から 0.05 秒（衝撃が車から
    /// 離れきる前の一番濃い瞬間）。前方にライバル 1 台。
    /// 炎（loop の fx）は View が nitroLeft を見て毎フレーム描くので bursts には積まない。
    def nitroScene(w0: World.World): World.World =
        let started = World.startGame(w0);
        let dist = World.rowPitch() * 33.4;
        let pd = dist + World.playerAheadPx();
        let rivals = started#rivals |> List.zipWithIndex |> List.map(entry -> {
            let (i, r) = entry;
            if (i == 0) { progress = pd + 70.0, off = 14.0 | r }
            else        { progress = pd - 60.0 - 30.0 * Int32.toFloat64(i), off = 0.0,
                          passed = true | r }
        });
        { phase = World.Phase.Racing, t = 3.4, distance = dist, playerOff = 0.0,
          speed = RulesDoc.rec(w0#rules)#forwardSpeed * RulesDoc.rec(w0#rules)#nitroBoost,
          nitroLeft = RulesDoc.rec(w0#rules)#nitroDuration - 0.05, nitro = 0.0, rank = 2, score = 600,
          rivals = rivals | started }

    /// U 字の手前（通し行 9）でコーンに当たった直後: スピンの残り 0.55 秒。
    /// 閃光と火花が散り、その先には U 字の巻き込みが見えている
    /// （「イン側を攻めて失敗した」が 1 枚で読める場所を選ぶ）。
    def crashScene(w0: World.World): World.World =
        let started = World.startGame(w0);
        let dist = World.rowPitch() * 8.6;
        let pd = dist + World.playerAheadPx();
        let off = 0.0 - 20.0;
        let rivals = started#rivals |> List.zipWithIndex |> List.map(entry -> {
            let (i, r) = entry;
            if (i == 0) { progress = pd - 50.0, off = 0.0, passed = true | r }
            else        { progress = pd + 40.0 + 50.0 * Int32.toFloat64(i), off = 0.0 | r }
        });
        let sceneT = 0.9;
        let bursts =
               Fx.burst(w0#fx#crash, 7, { x = off, y = pd }, sceneT - 0.12)
            :: Fx.burst(w0#fx#spark, 8, { x = off - 6.0, y = pd - 6.0 }, sceneT - 0.10)
            :: Nil;
        { phase = World.Phase.Racing, t = sceneT, distance = dist, playerOff = off,
          speed = RulesDoc.rec(w0#rules)#forwardSpeed * RulesDoc.rec(w0#rules)#spinSlow,
          spinLeft = 0.55, rank = 3, score = 300,
          rivals = rivals, bursts = bursts, fxSeq = 9 | started }

    /// 左の U 字（区間 6・通し行 11〜15）へ入っていく所: 幅の絞られた入口を
    /// イン側（左）に付けてドリフト中。道は 2 行先から巻き込んで画面の外へ消える。
    def uturnScene(w0: World.World): World.World =
        let started = World.startGame(w0);
        let dist = World.rowPitch() * 9.4;
        let pd = dist + World.playerAheadPx();
        let off = 0.0 - 18.0;
        let rivals = started#rivals |> List.zipWithIndex |> List.map(entry -> {
            let (i, r) = entry;
            if (i == 0) { progress = pd + 55.0, off = 12.0 | r }
            else        { progress = pd - 40.0 - 40.0 * Int32.toFloat64(i), off = 0.0,
                          passed = true | r }
        });
        let sceneT = 2.6;
        let skids = List.range(0, 8) |> List.map(i -> {
            let k = Int32.toFloat64(i);
            ({ dist = pd - 4.0 * k, off = off + 1.4 * k, turn = 0.0 - 0.06 }: World.Skid)
        });
        let bursts = List.range(0, 9) |> List.map(i -> {
            let k = Int32.toFloat64(i);
            Fx.burst(w0#fx#smoke, i + 1, { x = off + 5.0 + 1.1 * k, y = pd - 12.0 - 6.0 * k },
                     sceneT - 0.09 * k)
        });
        { phase = World.Phase.Racing, t = sceneT, distance = dist, playerOff = off,
          speed = RulesDoc.rec(w0#rules)#forwardSpeed, drifting = true, steerDir = 0.0 - 1.0,
          nitro = 0.8, rank = 2, score = 900,
          rivals = rivals, skids = skids, bursts = bursts, fxSeq = 20 | started }

    /// 登りの頂上ぎわ（通し行 7）から土管ゲート（通し行 8）へ差し掛かる所。
    /// 道が坂で持ち上がり、その先に隙間 3 レーンのゲートが立っている。
    def gateScene(w0: World.World): World.World =
        let started = World.startGame(w0);
        let dist = World.rowPitch() * 6.2;
        let pd = dist + World.playerAheadPx();
        let rivals = started#rivals |> List.zipWithIndex |> List.map(entry -> {
            let (i, r) = entry;
            if (i == 0) { progress = pd + 85.0, off = 18.0 | r }
            else        { progress = pd - 55.0 - 45.0 * Int32.toFloat64(i), off = 0.0,
                          passed = true | r }
        });
        { phase = World.Phase.Racing, t = 4.1, distance = dist, playerOff = 16.0,
          speed = RulesDoc.rec(w0#rules)#forwardSpeed, nitro = 0.35, rank = 2, score = 300,
          rivals = rivals | started }

    /// 左 U 字（通し行 12）の外側のガードレールに擦り付けて曲がっている所。
    /// 壁に押し付けたまま曲がると遅いが確実 — その代わり火花が散り、ゲージが貯まる。
    def railScene(w0: World.World): World.World =
        let started = World.startGame(w0);
        let dist = World.rowPitch() * 11.6;
        let pd = dist + World.playerAheadPx();
        let row = World.playerRowOf(dist);
        let off = World.halfWidthAt(row, w0#course);
        let rivals = started#rivals |> List.zipWithIndex |> List.map(entry -> {
            let (i, r) = entry;
            if (i == 0) { progress = pd + 50.0, off = 0.0 - 10.0 | r }
            else        { progress = pd - 45.0 - 45.0 * Int32.toFloat64(i), off = 0.0,
                          passed = true | r }
        });
        let sceneT = 3.3;
        // 火花は World と同じ 0.07 秒間隔で焚かれた続き物（擦っている実感は数で出る）。
        let bursts = List.range(0, 6) |> List.map(i -> {
            let k = Int32.toFloat64(i);
            Fx.burst(w0#fx#spark, i + 30, { x = off, y = pd - 5.0 * k }, sceneT - 0.07 * k)
        });
        { phase = World.Phase.Racing, t = sceneT, distance = dist, playerOff = off,
          speed = RulesDoc.rec(w0#rules)#forwardSpeed * RulesDoc.rec(w0#rules)#railScrapeSlow,
          nitro = 0.62, rank = 2, score = 600,
          rivals = rivals, bursts = bursts, fxSeq = 40 | started }

    /// 長い直線（通し行 32）の振り子バーへ差し掛かる所: バーは道の左寄りへ振れていて、
    /// 右に隙間が残っている。自機はその右へ動かしている（避け先が絵で読めるかを見る場面）。
    def barScene(w0: World.World): World.World =
        let started = World.startGame(w0);
        let dist = World.rowPitch() * 30.6;
        let pd = dist + World.playerAheadPx();
        let rivals = started#rivals |> List.zipWithIndex |> List.map(entry -> {
            let (i, r) = entry;
            if (i == 0) { progress = pd + 95.0, off = 0.0 - 6.0 | r }
            else        { progress = pd - 50.0 - 40.0 * Int32.toFloat64(i), off = 0.0,
                          passed = true | r }
        });
        { phase = World.Phase.Racing, t = 2.63, distance = dist, playerOff = 24.0,
          speed = RulesDoc.rec(w0#rules)#forwardSpeed, nitro = 0.42, rank = 2, score = 750,
          rivals = rivals | started }

    /// 1 場面を PNG に生成し、生成したファイルパスを返す。hud の合流は実機と同じ
    /// App.composeScene を通す（カメラ無しなので center = None・等倍）。
    def shoot(cfg: HeadlessRender.RenderConfig, texInfo: String -> Option[GameEngine.TextureInfo],
              ctx: App.ViewCtx, w: World.World, name: String): String \ IO =
        let items = App.composeScene(None, 1.0, cfg#design,
            { world = View.frame(ctx, w), hud = View.hud(ctx, w) });
        let (drawables, polygons) = Render.drawWith(texInfo, items);
        HeadlessRender.renderPng(cfg, drawables, polygons, name);
        let path = "${cfg#outDir}/${name}.png";
        println("rendered: ${path}");
        path
}
