// App.DevTools — 開発の道具の組（App.DevTools の型）を作る口。Bevy の bevy_dev_tools と同じ考えで、App は渡された組の道具だけを動かし、
// 組が「無し」なら道具のコードへ呼び出しが届かない。中身（ループが呼ぶフックの組）は App.Internal.DevTools。
pub mod App.DevTools {

    /// 道具なしの組。命令口・flow の記録・ゲームの名簿・ヒッチの見張り・Doc の保存検知・F8 の注釈の書き出しのどれも動かさず、
    /// 環境変数も読まない（いつも先頭の始まり）。開発の道具を持たない配る版の起動で `App.launchWithDevTools` へ渡す（ブラウザ版は browser）。
    /// withDebug が真なら F8 で止めて巻き戻せるが、囲んだ注釈は書き出さない。
    pub def none(): App.DevTools[w, {}] =
        App.DevToolsFactory.DevToolsFactory(_ -> App.Internal.DevTools.none())

    /// ブラウザ版の組。道具なし（none）と同じだが、URL のクエリ（鍵と値の並び・デコード済み）を始まりとして読む:
    /// 最初の鍵が始まりの名前、その鍵と値も含めた全部の鍵と値が引数（`?talk=Lair&line=46` → 始まり talk、引数 talk=Lair line=46）。
    /// 頁が使う鍵（pageQueryKeys）は外す。外した後に何も無ければ先頭の始まり。
    /// 始まりを組めない時（知らない名前・引数の誤り）は止めずに先頭の始まりで開き、訳を console へ出す。
    pub def browser(pairs: List[(String, String)]): App.DevTools[w, {}] =
        App.DevToolsFactory.DevToolsFactory(_ -> App.Internal.DevTools.browserOf(startOfQuery(pairs)))

    /// URL のクエリを始まりの名前と引数に変える（browser の読み方）。頁が使う鍵と、名前の無い鍵を外し、残りが無ければ None。
    /// 同じ鍵が 2 つあれば後の値。
    pub def startOfQuery(pairs: List[(String, String)]): Option[(String, Map[String, String])] =
        let pageKeys = pageQueryKeys();
        let kept = List.filter(pair -> { let (key, _) = pair; not String.isEmpty(key) and not Set.memberOf(key, pageKeys) }, pairs);
        List.head(kept) |> Option.map(first -> (fst(first), List.toMap(kept)))

    // WhyNot: fge-web.js の側で外さない — 外す一覧を Flix のテストで確かめられる所に 1 つだけ置く。頁に鍵を足したらここにも足す。
    /// ブラウザ版の頁（fge-web.js）が自分で読む URL の鍵。始まりの引数に混ぜない。
    pub def pageQueryKeys(): Set[String] =
        Set#{"input", "size", "orientation", "glcheck", "loadtime", "capture", "fps"}

    /// デスクトップの道具の組。env は入口の頭で読んだ環境変数の表（ProcessEnv.snapshot()。DEBUG_HTTP_PORT・FLOW_RECORD・START を読む）。
    /// 記録と保存検知は App の withDebug が真の時だけ、命令口とヒッチの見張りはさらに view か debugView がある時だけ動く。START はいつも効く。
    pub def desktop(env: Map[String, String]): App.DevTools[w, Platform.Annotation] =
        App.desktopTools(env, None)
}
