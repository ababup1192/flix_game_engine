// エントリーポイント。Doc は App を組む前に読み、その値から描く元（Res）を作る
// （壊れていても defaults で必ず起動する）。App の w は描く元と遊びの状態（World）の組
// （Resources.With）で、系・絵・問いは Resources の口で両方を受ける。App の中でファイルを読むのは F1 の reloadOn と
// 保存検知（watchFile）だけ。外の世界に触れる処理（effect）は隠さず with で並べる。
//
// ── ゲームループの全体像（App.game の 1 レコード）──
// ここを読めば「何から始まり・毎フレームどう進み・どう絵になり・保存で何を読み直すか」が掴める。
//   init    = 出発点の組（描く元 Res と初期の World）。
//   update  = 毎フレームの更新（入力 → 次の World）。1 本の合成関数で渡す決まり —
//             複数のシステムは `w |> step(f, res) |> …` と中で繋いでから渡す（繋ぎが Controls.step に見える）。
//   view    = (Res, World) → 「何をどこに描くか」。どちらも読むだけで変えない。
//   reloads = Nil（保存即反映・F1・表示中の名乗りは App.withDocTable が Doc の一覧表から配線する）。
// 場面（表紙・クリア等）が増えたら World.Screen の enum に case を足し、その場面だけの値を payload に持たせて
// step / frame を match で分ける（手本は templates/tidepool-starter）。Doc を足すなら Res に欄を足す（World には置かない）。
// App.game の外側で足す設定（reloadOn・終了の確認・静的な層・注釈の文脈・withDebug）は戻り値の App に後ろから pipe で足す。
// 音も同じ形で足す: 起きた音 = App.withAudio + Sfx.collect・続く音 = withSustained + Loop.collect
// （一発と鳴り続ける音を別の enum で型に分ける。実例は templates/race-starter/src/Sounds.flix）、
// バスの音量やダッキング = withMixer + mixer.json（engine の docs/audio.md の「音の通り道」）。
// 複数システムの明示的な列挙が要る高度なゲームは、make から始める従来のビルダー（addSystem / withView / …）へ降りる。

use fge::{App, GameEngine, LwjglLayer, Resources}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else {
        run {
            App.game({
                init = Resources.of(Res.build(Controls.loadDocs()), World.initial()),
                // 入力を読み World.step で次の状態へ。系は純粋（ファイルに書く物は App の口が実機でだけ書く）。
                update = Resources.system(Controls.step),
                view = Resources.view(View.frame),
                // 保存即反映・F1 の一括読み直し・Studio への「表示中」の名乗りは、下の App.withDocTable が
                // Doc の一覧表 1 枚から配線する（ここでは足さない）。
                reloads = Nil
            })
                // 以下は App.game の外側の高度な口（戻り値の App に後ろから pipe で足す）。
                |> App.withDocTable(Controls.docTable())
                // ドット絵を作った 1 枚を GPU へ上げる（View はこの名前で 1 コマ 1 クアッドを貼る）。
                // 鍵が同じ間は上げ直さないので、毎フレームの費用はゼロ。
                |> App.withSpriteAtlases(Resources.read((res, _) ->
                    { texture = Res.atlasName(), key = res#atlasKey, baked = res#atlas } :: Nil))
                // 動かない絵（画面の縁の枠）は 1 度だけ GPU に作り、鍵が変わるまで使い回す。
                |> App.withStaticLayer(Resources.read((res, _) -> View.staticKey(res#theme)),
                                       Resources.read((res, _) -> View.frameBorder(res#theme)))
                // 窓の閉じるボタンも Esc と同じ確認へ回し、はいを選んだら終わる（quitWhen を差し替えると
                // 既定の「Esc ですぐ終了」は外れる。Esc は Controls.step が確認へ回す）。
                |> App.withCloseRequest(Resources.mapWorld((_, w) -> World.askQuit(w)))
                |> App.quitWhen((_, h) -> Resources.read((_, w) -> World.isQuitting(w), h))
                // F8 で書き出す注釈チケットに、その瞬間の文脈と z の層の名前を添える（層の表は ZOrder）。
                |> App.withAnnotationContext(Resources.read((_, w) ->
                    { facts = ("主人公", heroFact(w)) :: ("終了の確認", "${w#quit}") :: Nil,
                      // HUD（App.withHudView）を足したら、HUD の層の enum を ZOrder に作ってその列を渡す。
                      layers = ZOrder.layers(), hudLayers = (Nil: List[ZOrder.Layer]) }))
                // 走行中の POST /render（Studio の「生成して」）は SceneRender.all と同じ実体を呼ぶ。
                |> App.onRenderRequest(SceneRender.allShots)
                |> App.withDebug(App.debugFromEnv())
                |> App.launch
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
    }

/// 注釈チケットに添える主人公の位置（主人公が出ていない画面では "-"）。
def heroFact(w: World.World): String =
    World.heroAt(w) |> Option.map(p -> "x=${p#x} y=${p#y}") |> Option.getWithDefault("-")
