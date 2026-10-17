// エントリーポイント。Doc は App を組む前に読み、その値から初期 World を作る
// （壊れていても defaults で必ず起動する）。App の中でファイルを読むのは F1 の reloadOn と
// 保存検知（watchFile）だけ。外の世界に触れる処理（effect）は隠さず with で並べる。
//
// ── ゲームループの全体像（App.game の 1 レコード）──
// ここを読めば「何から始まり・毎フレームどう進み・どう絵になり・保存で何を読み直すか」が掴める。
//   init    = 出発点の World（初期状態）。
//   update  = 毎フレームの更新（入力 → 次の状態）。1 本の合成関数で渡す決まり —
//             複数のシステムは `w |> step(f) |> …` と中で繋いでから渡す（繋ぎが Main に見える）。
//   view    = World → 「何をどこに描くか」。World は読むだけで変えない。
//   reloads = 保存で読み直す Doc（各 1 本の watchFile に展開される）。
// 場面（表紙・クリア等）が増えたら World にフェーズを持たせ、step / frame を分岐させる。
// App.game の外側で足す設定（reloadOn・終了の確認・静的な層・注釈の文脈・withDebug）は戻り値の App に後ろから pipe で足す。
// 音も同じ形で足す: 起きた音 = App.withAudio・続く音 = withSustained（実例は templates/race-starter/src/Main.flix）、
// バスの音量やダッキング = withMixer + mixer.json（engine の docs/audio.md の「音の通り道」）。
// 複数システムの明示的な列挙が要る高度なゲームは、make から始める従来のビルダー（addSystem / withView / …）へ降りる。

use flix_game_engine::{ActiveDocs, App, GameEngine, LwjglLayer, PxSpriteDoc}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else {
        run {
            let doc = SampleDoc.load(SampleDoc.path());
            let keys = KeysDoc.load(KeysDoc.path());
            let theme = ThemeDoc.load(ThemeDoc.path());
            let sprites = PxSpriteDoc.load(World.spritePath());
            let shader = Controls.loadShader();
            App.game({
                init = World.initial(doc, keys, theme, sprites, shader),
                // 入力を読み World.step で次の状態へ → 表示中の Doc を名乗る。
                // ActiveDocs.step だけ Fs.FileWrite を使うので、純粋な部品は checked_ecast で
                // 同じ効果行へそろえる（部品側の ef は {} のまま保つ）。ActiveDocs は Studio の
                // 「表示中」バッジ用の補助で、ゲーム進行には関与しない（一覧が変わった瞬間だけ書く）。
                update = (f, w) ->
                    checked_ecast(Controls.step(f, w))
                        |> (w1 -> ActiveDocs.step(Controls.activeDocs(w1), w1)),
                view = (ctx, w) -> checked_ecast(View.frame(ctx, w)),
                reloads = Controls.reloads()
            })
                // 以下は App.game の外側の高度な口（戻り値の App に後ろから pipe で足す）。
                // ドット絵を作った 1 枚を GPU へ上げる（View はこの名前で 1 コマ 1 クアッドを貼る）。
                // 鍵が同じ間は上げ直さないので、毎フレームの費用はゼロ。
                |> App.withSpriteAtlases(w ->
                    { texture = World.atlasName(), key = w#atlasKey, baked = w#atlas } :: Nil)
                // 動かない絵（画面の縁の枠）は 1 度だけ GPU に作り、鍵が変わるまで使い回す。
                |> App.withStaticLayer(View.staticKey, View.frameBorder)
                // 窓の閉じるボタンも Esc と同じ確認へ回し、はいを選んだら終わる（quitWhen を差し替えると
                // 既定の「Esc ですぐ終了」は外れる。Esc は Controls.step が確認へ回す）。
                |> App.withCloseRequest(w -> checked_ecast(World.askQuit(w)))
                |> App.quitWhen((_, w) -> checked_ecast(World.isQuitting(w)))
                // F8 で書き出す注釈チケットに、その瞬間の文脈と z の層の名前を添える（層の表は ZOrder）。
                |> App.withAnnotationContext(w -> checked_ecast(
                    { facts = ("主人公", "x=${w#x} y=${w#y}") :: ("終了の確認", "${w#quit}") :: Nil,
                      // HUD（App.withHudView）を足したら、HUD の層の enum を ZOrder に作ってその列を渡す。
                      layers = ZOrder.layers(), hudLayers = (Nil: List[ZOrder.Layer]) }))
                |> App.reloadOn(GameEngine.Key.F1, Controls.reloadAll)
                // 走行中の POST /render（Studio の「生成して」）は SceneRender.all と同じ実体を呼ぶ。
                |> App.onRenderRequest(SceneRender.allShots)
                |> App.withDebug(App.debugFromEnv())
                |> App.launch
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
    }
