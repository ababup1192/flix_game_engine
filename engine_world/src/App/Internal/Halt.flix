// App.Internal.Halt — F8 で止めた画面の 1 コマ（時間スクラブ・ズームとパン・矩形の注釈の書き出し）と、止めた画面の描き方。
// ゲームからは呼ばない（App の中身。ゲームの src・test で App.Internal. を書くと lint が止める）。
pub mod App.Internal.Halt {

    /// 一時停止中に扱う 1 フレームぶんの描画チャンネル（エンジンへそのまま渡せる形）。
    type alias DebugChannels = {
        drawables = List[GameEngine.Drawable],
        tileMaps = List[GameEngine.TileMapRenderCmd],
        polygons = List[GameEngine.PolygonRenderCmd]
    }

    /// 一時停止中の 1 フレーム。← → の時間スクラブで表示する瞬間を選び、マウスを読んで
    /// ズーム・パン・ドラッグを進め、矩形が確定したら「表示中の瞬間」の注釈一式を書き出し、
    /// その World の絵に見え方とドラッグ中の矩形を重ねて描く。
    /// World には一切触れない（凍結中の絵は選んだ World から毎フレーム投影し直す）。
    /// view のゲームは走っている間と同じ renderFrame で描く（見え方だけが pausedLook）。
    /// debugView（生チャンネル投影）のゲームは描画命令へ見え方を掛ける（renderPaused）。
    /// 塗ったコマを画面へ出す（presentFrame）のは呼ぶ側。saveAnnotation は注釈を書き出す開発の道具（書いたフォルダ。持たなければ None）。
    pub def pausedStep(app: App[w, ef], saveAnnotation: GameEngine.AnnotationRequest -> Option[String] \ efTools, warnOnce: String -> Unit, design: Vec2.Vec2, world: w, history: List[w], frame: App.Frame,
                       anno: Annotate.State, painted: App.Internal.Paint.Painted):
            (Annotate.State, Option[String], App.Internal.Paint.Painted) \ (ef + Platform.Input + Platform.Rendering + RenderTarget.Target + efTools + IO) =
        let r = App.rec(app);
        let historyLen = Int32.max(1, List.length(history));
        let scrubbed = Annotate.scrubStep(
            { back = App.isDown(GameEngine.Key.Left, frame),
              backEdge = App.justPressed(GameEngine.Key.Left, frame),
              fwd = App.isDown(GameEngine.Key.Right, frame),
              fwdEdge = App.justPressed(GameEngine.Key.Right, frame) },
            historyLen, anno);
        let displayed = App.worldAt(history, scrubbed#scrub, world);
        // WhyNot: マウスを frame から取らない — frame は pollEvents の前に組むので 1 コマ古く、止めたコマの frame#cursor はキャプチャした時の位置で止まっている。
        let input = { cursor = Platform.Input.getMousePosition(),
                      leftDown = Platform.Input.isMouseButtonPressed(GameEngine.MouseButton.Left),
                      middleDown = Platform.Input.isMouseButtonPressed(GameEngine.MouseButton.Middle),
                      spaceDown = App.isDown(GameEngine.Key.Space, frame),
                      // ホイールは loop が Frame へ埋め込んだ後なので、二度読みせず frame から引く
                      scroll = frame#wheel,
                      design = design };
        let (next, emitted) = Annotate.step(input, scrubbed);
        // 注釈のフレーム番号は「表示中の瞬間」のもの（スクラブぶんを引く）
        let shownFrame = next#frame - Int32.toInt64(next#scrub);
        // 矩形が確定した瞬間だけ、表示中の World をゲームのダンプ関数でテキスト化する
        // （world.json としてチケットに同梱。繋がれていなければ空 = 同梱しない）
        let dumpText = match (emitted, r#worldDump) {
            case (Some(rect), Some(f)) => f(rect, displayed)
            case _                     => ""
        };
        let context = match (emitted, r#annotationContext) {
            case (Some(_), Some(f)) => f(displayed)
            case _                  => Annotate.noContext()
        };
        let dump = { text = dumpText, context = context };
        match r#view {
            case Some(toItems) =>
                // 注釈に残す物（等倍の描画命令・当たり）は、矩形が確定したフレームだけ組む。
                // 絵は displayed（スクラブで表示中の瞬間）から導く — 注釈の hits も同じ items を使う。
                // 止めている間も本編と同じ renderFrame で 1 コマ全部を描く（シェーダー面・レンダーターゲット・
                // 字の用意も同じ規則）。ズーム・パンは描く前の絵に掛ける（pausedLook）。
                let paint = (look, p) -> {
                    let (cache, seen, warned) = App.Internal.Paint.renderFrame(app, warnOnce, frame#diagnostics, design, displayed, look,
                                                            p#tileCache, p#glyphSeen, p#budgetWarned);
                    { tileCache = cache, glyphSeen = seen, budgetWarned = warned }
                };
                // 矩形が確定したフレームは、等倍・重ね物無しのコマを先に塗ってからスクリーンショットを撮る
                // （saveAnnotation は直前に塗ったコマを撮る）。当たりは同じ瞬間の絵から等倍で数える。
                let (saved, afterShot) = match emitted {
                    case Some(rect) =>
                        let shotPainted = paint(App.Internal.Paint.plainLook(Nil), painted);
                        let atlas = Platform.GpuResources.getFontAtlas("default");
                        let items = List.append(App.Internal.Paint.tilePausedItems(app, design, displayed),
                                    List.append(App.sceneItems(app, design, atlas, warnOnce, frame#diagnostics, displayed, toItems),
                                                App.Internal.Paint.staticPausedItems(app, design, displayed)));
                        let hitList = Annotate.hits(name -> Platform.GpuResources.getTextureInfo(name), rect, items);
                        (saveAnnotation(buildAnnotationRequest(design, rect, shownFrame, dump, hitList)), shotPainted)
                    case None => (None, painted)
                };
                let shown = toastAfter(emitted, saved, next);
                (shown, saved, paint(pausedLook(design, input#cursor, historyLen, shown), afterShot))
            case None => match r#debugView {
                case Some((fontName, toChannels)) =>
                    let atlas = Platform.GpuResources.getFontAtlas(fontName);
                    let (drawables, tileMaps, polygons) = toChannels(displayed);
                    let hitList = match emitted {
                        case Some(rect) =>
                            Annotate.hitsFromDrawables(name -> Platform.GpuResources.getTextureInfo(name), rect, drawables)
                        case None => Nil
                    };
                    let (shown, saved) = finishPaused(saveAnnotation, { design = design, cursor = input#cursor, atlas = atlas,
                                                         historyLen = historyLen, shownFrame = shownFrame },
                                                       next, emitted, dump,
                                                       { drawables = drawables, tileMaps = tileMaps, polygons = polygons }, hitList);
                    (shown, saved, painted)
                case None => (next, None, painted)
            }
        }

    /// 注釈を書き出したフレームは保存先のトーストを出し、それ以外はトーストの残りを 1 フレーム減らす。
    def toastAfter(emitted: Option[Rect2.Rect2], saved: Option[String], anno: Annotate.State): Annotate.State =
        match (emitted, saved) {
            case (Some(_), Some(path)) => Annotate.showToast("Saved debug file\n${path}", anno)
            case (Some(_), None)       => anno
            case (None, _)             => Annotate.tickToast(anno)
        }

    /// 止めている間の見え方: ズーム・パン（anno の zoom と pan）と、ドラッグ中の矩形（見え方と一緒に動く）・
    /// 保存のトーストとスクラブの位置（見え方の後に重ね、ズーム中も画面に固定）。
    /// デバッグの小物の字は組み込みフォント — ゲームのフォントは出た字から順に用意するので、
    /// 用意の無い字が欠けうる。組み込みフォントは常に全部そろっている。
    def pausedLook(design: Vec2.Vec2, cursor: Vec2.Vec2, historyLen: Int32, anno: Annotate.State): App.Internal.Paint.Look =
        let view = Annotate.viewOf(design, anno);
        let debugAtlas = BootFont.atlas();
        let debugSize = debugAtlas#fontSize;
        let toast = match anno#toast {
            case Some(t) => Annotate.toastItems(debugAtlas, debugSize, t#message)
            case None    => Nil
        };
        let scrub = if (anno#scrub > 0 and anno#scrubShow > 0)
                        Annotate.scrubIndicatorItems(debugAtlas, debugSize, design, anno#scrub, historyLen)
                    else Nil;
        { view = view,
          inspected = match anno#dragStart {
              case Some(start) => Annotate.overlayItems(start, Annotate.toDesign(view, cursor))
              case None        => Nil
          },
          fixed = List.append(toast, scrub) }

    /// debugView のゲームの一時停止フレームの締め: 矩形が確定していれば注釈を書き出してトーストを出し、凍結画面を描く。
    /// 返すのは次の停止の状態と、書き出したチケットのフォルダ（遊んだ記録の写しを入れる所）。
    def finishPaused(saveAnnotation: GameEngine.AnnotationRequest -> Option[String] \ efTools, ctx: { design = Vec2.Vec2, cursor = Vec2.Vec2, atlas = FontAtlas,
                            historyLen = Int32, shownFrame = Int64 },
                     anno: Annotate.State, emitted: Option[Rect2.Rect2],
                     dump: { text = String, context = Annotate.Table },
                     channels: DebugChannels, hitList: List[Annotate.Hit]): (Annotate.State, Option[String]) \ (Platform.Draw2d + efTools) =
        // saveAnnotation は直前に塗ったコマを撮るので、等倍・重ね物無しのコマを先に塗る。
        let saved = match emitted {
            case Some(rect) =>
                Platform.Draw2d.renderCommands(channels#drawables, channels#tileMaps, channels#polygons, None);
                saveAnnotation(buildAnnotationRequest(ctx#design, rect, ctx#shownFrame, dump, hitList))
            case None => None
        };
        let shown = toastAfter(emitted, saved, anno);
        renderPaused(ctx, shown, channels);
        (shown, saved)

    /// 確定した矩形の注釈一式（JSON・README の要約）を、開発の道具の saveAnnotation へ渡す依頼に組む。
    /// ファイルへの書き出しとスクリーンショット撮影・シャッター音は道具（デスクトップは Platform.Annotation の handler）が引き受ける。
    def buildAnnotationRequest(design: Vec2.Vec2, rect: Rect2.Rect2, frameNo: Int64,
                               dump: { text = String, context = Annotate.Table },
                               hitList: List[Annotate.Hit]): GameEngine.AnnotationRequest =
        let dumpText = dump#text;
        let body = Annotate.readmeBodyWith(dump#context, { frame = frameNo, rect = rect }, hitList);
        {
            frame = frameNo, rect = rect,
            json = Annotate.annotationJsonWith(dump#context, { frame = frameNo, design = design, rect = rect }, hitList),
            readmeBody = if (dumpText == "") body else body + "\n- シム状態のダンプ: world.json",
            worldDump = dumpText }

    /// debugView のゲームの凍結中の絵を描く: ドラッグ中の矩形を重ね、ズーム・パンを適用して描画命令にする。
    /// 保存完了メッセージとスクラブ位置は見え方の適用後に重ねるので、ズーム中も画面に固定される。
    /// 等倍・ずらし無し・表示物無しのときは通常描画と同じ命令列になる。
    def renderPaused(ctx: { design = Vec2.Vec2, cursor = Vec2.Vec2, atlas = FontAtlas,
                            historyLen = Int32, shownFrame = Int64 },
                     anno: Annotate.State, channels: DebugChannels): Unit \ Platform.Draw2d =
        let view = Annotate.viewOf(ctx#design, anno);
        let overlay = match anno#dragStart {
            case Some(start) => Annotate.overlayItems(start, Annotate.toDesign(view, ctx#cursor))
            case None        => Nil
        };
        let (overlaySprites, overlayPolygons) = Render.draw(overlay);
        // デバッグの小物はゲームのフォントを使わない。ゲームのフォントは「出た字から順に用意する」
        // ので、まだ用意されていない字は出せず、しかもこの停止中の経路は追加で作ることを頼まない。
        // 組み込みフォント（常に全部そろっているドット絵の字）を決め打ちで使う。
        let debugAtlas = BootFont.atlas();
        let debugSize = debugAtlas#fontSize;
        let toastPlaced = match anno#toast {
            case Some(t) => Annotate.toastItems(debugAtlas, debugSize, t#message)
            case None    => Nil
        };
        let scrubPlaced = if (anno#scrub > 0 and anno#scrubShow > 0)
                              Annotate.scrubIndicatorItems(debugAtlas, debugSize, ctx#design,
                                                           anno#scrub, ctx#historyLen)
                          else Nil;
        let (fixedSprites, fixedPolygons) = Render.draw(List.append(toastPlaced, scrubPlaced));
        // debugView のゲームは静的レイヤー（withStaticLayer）を持たないので、retained の静的依頼は無し（None）。
        Platform.Draw2d.renderCommands(
            List.append(Annotate.applyInspect(view, List.append(channels#drawables, overlaySprites)), fixedSprites),
            Annotate.applyInspectTiles(view, channels#tileMaps),
            List.append(Annotate.applyInspectPoly(view, List.append(channels#polygons, overlayPolygons)), fixedPolygons),
            None)
}
