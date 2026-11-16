// GameE2e — このゲームだけの flow の問い（e2e/<名前>.flow の until・expect と、移行の記録に載せる値）。
// テンプレートの E2e.table が自分の問いの後ろに並べる。名前はテンプレートの問いと重ねない（重ねると TestTape が落ちる）。
// ゲームの持ち物（テンプレートの追随では上書きしない）。下の 2 つは作例の問い（シナリオの変数を真偽で読む）なので、
// ゲームの問いに書き替えてよい（シナリオの変数は移行の記録にはどれも $名前 で載るので、ここに並べなくてよい）。
mod GameE2e {
    use fge::{Flow, Resources}

    type alias AppState = Resources.With[Res.Res, World.World]

    /// ゲームの問い（{ name, doc, read }。read は Flow.Probe.Num・Text・Flag のどれか）。
    pub def probes(): List[Flow.ProbeRow[AppState]] =
        { name = "ownPace", doc = "シナリオの変数 $own_pace（最初の手紙で歩調を伝えた）", read = Flow.Probe.Flag(flagOf("$own_pace")) } ::
        { name = "sharedTiredness", doc = "シナリオの変数 $shared_tiredness（2 通目で休む日を伝えた）", read = Flow.Probe.Flag(flagOf("$shared_tiredness")) } :: Nil

    /// シナリオの真偽の変数 name が真か。
    def flagOf(name: String): AppState -> Bool = Resources.read((_, w) -> World.variableOf(name, w) == "True")
}
