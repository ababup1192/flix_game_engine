// Resources — 描く元の束（Doc・アトラス・シェーダーなど。読むだけで、Doc の読み直しの時だけ替わる）と、
// 遊びの状態 World の組。名前は Bevy の Resource（World の外にある、系が読む入れ物）にならう。
// App の w にこの組を渡し、App の型引数は増やさない。系・入力・絵の口は mapWorld / system / view / read を通すので、
// 描く元はそのまま次のフレームへ渡る。組を作るのは of、描く元を替えるのは読み直しの行（reloadRow / reloadUnnamedRow）だけ。
pub mod Resources {

    /// 描く元 res と、遊びの状態 w の組。
    /// WhyNot: enum で包まない。App.withAudio の前後（ws#before#world）など、読む側は欄を直に読む。
    /// 外で組を作る・欄を書き替えるのは forbid の pair-construct が止める。
    pub type alias With[res, w] = { resources = res, world = w }

    /// 組を作る（起動の時・テスト・描き出し）。
    pub def of(res: res, w: w): With[res, w] = { resources = res, world = w }

    /// 描く元を読み、World だけを返す関数を、組を受けて組を返す関数にする（描く元はそのまま渡る）。
    pub def mapWorld(f: (res, w) -> w \ ef, h: With[res, w]): With[res, w] \ ef = { world = f(h#resources, h#world) | h }

    def mapWorldResult(f: (res, w) -> Result[e, w] \ ef, h: With[res, w]): Result[e, With[res, w]] \ ef =
        f(h#resources, h#world) |> Result.map(w -> { world = w | h })

    /// 系: (Frame, res, w) -> w を App の系にする。
    pub def system(f: (App.Frame, res, w) -> w \ ef, frame: App.Frame, h: With[res, w]): With[res, w] \ ef =
        mapWorld((res, w) -> f(frame, res, w), h)

    /// 絵: ViewCtx・描く元・World から絵を組む。
    pub def view(f: (App.ViewCtx, res, w) -> List[Render.PlacedItem] \ ef, ctx: App.ViewCtx, h: With[res, w]): List[Render.PlacedItem] \ ef =
        f(ctx, h#resources, h#world)

    /// 読むだけの口（組を受けて値を返す App の口）へ渡す包み。
    pub def read(f: (res, w) -> a \ ef, h: With[res, w]): a \ ef = f(h#resources, h#world)

    def withResources(res: res, h: With[res, w]): With[res, w] = { resources = res | h }

    /// 描く元を替える読み直しの行: reload で描く元を読み直し、settle で替わった描く元に World を収める
    /// （収める物が無い行は settle に (_, w) -> w を渡す）。
    /// WhyNot: settle に Fs.FileRead を許さない。ファイルを読むのは reload の仕事で、settle は新しい描く元から World を直すだけ。
    pub def reloadRow(docId: String, path: String, reload: res -> res \ Fs.FileRead, settle: (res, w) -> w): DocTable.Entry[With[res, w]] =
        DocTable.row(docId, path, reloadThenSettle(reload, settle))

    /// reloadRow の、Studio に名乗らない行（Doc の編集口を持たないファイル）。
    pub def reloadUnnamedRow(path: String, reload: res -> res \ Fs.FileRead, settle: (res, w) -> w): DocTable.Entry[With[res, w]] =
        DocTable.unnamedRow(path, reloadThenSettle(reload, settle))

    def reloadThenSettle(reload: res -> res \ Fs.FileRead, settle: (res, w) -> w, h: With[res, w]): With[res, w] \ Fs.FileRead =
        mapWorld(settle, withResources(reload(h#resources), h))

    /// 時計: App.addClock と同じ形（違うのは paceOf が (res, w) を受けることだけ）。時計は World の欄のまま。
    pub def addClock(spec: { clockOf = w -> Clock.Clock[c], withClock = (Clock.Clock[c], w) -> w,
                             paceOf = (res, w) -> Clock.Pace[c, why] },
                     app: App.App[With[res, w], ef]): App.App[With[res, w], ef] =
        App.addClock({ clockOf = h -> spec#clockOf(h#world), withClock = (clock, h) -> { world = spec#withClock(clock, h#world) | h },
                       paceOf = h -> spec#paceOf(h#resources, h#world) }, app)

    /// 始まりの登録簿の 1 行（App.Start の、build が描く元も受ける形）。build は描く元を読んで World を組む。
    pub type alias Start[res, w] = { name = String, doc = String, args = Map[String, String],
                                     build = (res, w, Map[String, String]) -> Result[String, w] }

    /// 始まりの登録簿の 1 行を組の行へ持ち上げる（build は World を組み、描く元はそのまま）。
    pub def liftStart(start: Start[res, w]): App.Start[With[res, w]] =
        { name = start#name, doc = start#doc, args = start#args,
          build = (h, args) -> mapWorldResult((res, w) -> start#build(res, w, args), h) }

    /// 外へ書く出力を組の出力へ持ち上げる（鍵と書く物は World から）。
    pub def liftOutput(output: App.Output[w]): App.Output[With[res, w]] =
        { keyOf = h -> output#keyOf(h#world), write = h -> output#write(h#world), onJump = output#onJump }
}
