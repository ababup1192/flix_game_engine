// Game — App の組み立て。実機の起動（Main）・flow の入口（E2e）・テスト・描き出しが同じ物を使う。
// Doc と校舎の形は App を組む前に読み（Controls.loadDocs）、その値から描く元（Res）を作る。
// App の w は描く元と遊びの状態（World）の組（Resources.With）で、系・絵・問いは Resources の口で両方を受ける。
//
// ── ゲームループの全体像（App.game の 1 レコード）──
//   init    = 出発点の組（描く元 Res と、1 階の昇降口に立つ World）。
//   update  = 毎フレームの更新（入力 → 次の World。Controls.step）。
//   view    = (Res, World) → 3D の場面 1 枚（View.frame）。部屋の名前・紙のマップ・終了の確認の窓は withHudView。
//   reloads = Nil（保存即反映・F1・表示中の名乗りは App.withDocTable が Doc の一覧表から配線する）。
// 音を足すなら: 起きた音 = App.withAudio・続く音 = App.withSustained・音量 = App.withMixer（engine の docs/audio.md）。
mod Game {
    use fge::{App, PostStack, Resources}

    /// look.json の psx にテレビのにじみがあれば、場面に後がけ（PostStack の CRT のにじみ）を掛ける。値は毎コマ Doc から読む。
    // WhyNot: にじみの無い時も後がけを付けない — 場面を Pass へ描いて写し直す分だけ絵と重さが変わる。付けるかは起動の時の Doc で決める。
    def withCrt(res: Res.Res, app0: App.App[Resources.With[Res.Res, World.World], {}]): App.App[Resources.With[Res.Res, World.World], {}] =
        if (Option.isEmpty(crtStackOf(res))) app0
        else app0 |> App.withPostStack(Resources.read((r, _) -> crtStackOf(r) |> Option.getWithDefault(PostStack.preset(PostStack.Preset.Neutral))))

    /// look.json の psx のテレビのにじみの後がけ（無ければ None）。描き出し（SceneRender・VideoRender）も同じ物を掛ける。
    pub def crtStackOf(res: Res.Res): Option[PostStack.Stack] =
        LookDoc.crtOf(LookDoc.rec(res#look)#psx) |> Option.map(c -> PostStack.preset(PostStack.Preset.Neutral) |> PostStack.withCrt(Some(c)))

    pub def app(docs: Res.Docs): App.App[Resources.With[Res.Res, World.World], {}] =
        let res = Res.build(docs);
        App.game({
            init = Resources.of(res, World.initial(res)),
            update = Resources.system(Controls.step),
            view = Resources.view(View.frame),
            reloads = Nil
        })
            |> App.withHudView(Resources.view(View.hud))
            |> withCrt(res)
            |> App.withDocTable(Controls.docTable())
            // 紙・足音・戸のきしみ（起きた音）と、夜の校舎の空気（続く音）。
            |> App.withAudio(ws -> Sounds.events(ws#after#resources, ws#before#world, ws#after#world))
            |> App.withSustained(Resources.read(Sounds.hums))
            // 音の大きさ（足音が主役）と、戸口・窓からの距離で戸と風の音を小さくする（Doc は sound.kind.json）。
            |> App.withMixer(Resources.read(Sounds.mixer))
            // 好きな場面から起動する・テストと flow が場面を名前で組む（START="at x=-4.5 z=2 yaw=0" など）。
            |> App.withStarts(Starts.all() |> List.map(Resources.liftStart))
            // ギャラリーの場面を実機でも開く（START=shot:corridor。描き出しと同じ World から始まる）。
            |> App.withShots(Resources.shotsOf(Shots.names(), Shots.worldOf))
            // e2e/<名前>.flow の語彙（役・問い）と、記録の再生が比べる指紋。
            |> App.withFlow(E2e.table())
            |> App.withFingerprint(Resources.read(E2e.fingerprint))
            |> App.withStatusLine(Resources.read(E2e.statusLine))
            // クリックでマウスを視点に取り込み、マウスの動き（frame#mouseDelta）で見回す（Esc で放す）。
            |> App.withMouseCapture(Resources.read((_, w) -> World.wantsMouseCapture(w)))
            // ブラウザ版で後から届く校舎の束と人物・持ち物を、届いた物から解いて校舎を組み直す（デスクトップは起動で全部読んであるので何もしない）。
            |> App.withDecodeBudget(Resources.read(Controls.decodeBudget))
            |> Controls.withBackgroundLoads(docs)
            |> App.withLoadGate(Resources.read(Controls.loadGate))
}
