// BackgroundLoad — 後回しの素材（project.json の web.deferred）を鍵ごとのグループにまとめ、起動で届いている分だけ読み、
// 残りはループの中で区切って読む（Unity Addressables のグループ・Bevy の AssetServer の読み込み中の表）。
// 毎コマ進めるのは App.withBackgroundLoad。ここは型と、起動の読み・待ちの表の判定を持つ。
//
// デスクトップと画面なしは LoadProgress.localDownloads()（全部 Loaded）なので、start で全部読み、待ちの表は全部 Loaded のまま変わらない。

pub mod BackgroundLoad {

    /// 鍵（場面の名前など）ごとに読む物の組。
    /// name = 起動画面の字とログに出す名前・keys = 全部の鍵（並びが既定の優先順）・pathsOf = 鍵 → 論理の道（1 つの鍵に複数の道）・
    /// read = 鍵の道を読む（読めない時の扱いも r に入れる）・decode = 読んだ物から使う形を作る（並列の仕事の中で回すので IO だけ）・
    /// costMs = 鍵 1 つの read と decode の見込みの ms（解くたびに測った値との平均で置き換わる）。
    /// 目安は glb と jpg の部屋 1 つで PC 100 ms 前後・スマホはその 3〜5 倍。遅い機種（スマホ）の見込みで書く
    /// （上がりすぎた見込みはこの値へ戻すので、小さく書くと Idle(ms) に収まると見て重い鍵を始め、止まりが見えることがある）。
    /// IO を使わない decode は `raw -> checked_ecast(...)` で IO へ広げて渡す。
    // WhyNot: read に IO を足さない — 渡す関数の効果は型と同じでないと通らず、ファイルを読むだけの関数がそのまま渡せなくなる。
    pub type alias Group[r: Type, a: Type] = {
        name = String,
        keys = List[String],
        pathsOf = String -> List[String],
        read = String -> r \ Fs.FileRead,
        decode = r -> Result[String, a] \ IO,
        costMs = Float64
    }

    /// 待ちの表（鍵ごとの状態）。ゲームは resources 側に置く。
    /// group = グループの名前・states = 鍵ごとの状態（Loaded は解いて store した後）・sentPriority = 最後に送った優先順・
    /// costMs = 鍵 1 つの今の見込みの ms・idleSinceMs = Idle の予算で、届いた鍵を見込みが収まらずに始めなかった最初の時刻（待っていなければ負。見込みを初めの値へ戻す時に使う）。
    // WhyNot: 関数（Group や AssetDownloads）を持たせない — World 全体の要約は反射で resources まで辿るので、関数が入ると決定性の門の値がぶれる。
    pub type alias Pending = {
        group = String,
        states = Map[String, LoadProgress.LoadState],
        sentPriority = List[String],
        costMs = Float64,
        idleSinceMs = Float64
    }

    /// 鍵の並びが使えるか（Godot の load_threaded_get_status）。判定するだけで待たない。
    /// Ready = 全部 Loaded・Waiting = まだ届いていない（解いていない）物がある・GaveUp = 取れなかった物があるか、待つ上限を超えた（理由）。
    pub enum Readiness with Eq, ToString {
        case Ready
        case Waiting
        case GaveUp(String)
    }

    /// 起動の読み込み: 道が全部届いている鍵は read を順に・decode を並列に回し、残りは行列の頭へ頼んで待ちの表に載せる。
    /// 返すのは解いた鍵の結果（Err は decode の理由）と待ちの表。後回しの無い機種では全部の鍵が結果に入り、表は全部 Loaded。
    pub def start(group: Group[r, a]): (Map[String, Result[String, a]], Pending) \ {Fs.FileRead, IO, LoadProgress} =
        let downloads = LoadProgress.downloads();
        let (arrived, waiting) = group#keys
            |> List.map(key -> (key, BackgroundLoad.Internal.arrivalOf(downloads, group#pathsOf, key)))
            |> List.partition(entry -> snd(entry) == LoadProgress.LoadState.Downloaded);
        let decoded = arrived
            |> List.map(fst)
            |> LoadProgress.mapWithProgress("reading ${group#name}...", key -> (key, group#read(key)))
            |> LoadProgress.parMapWithProgress("decoding ${group#name}...", entry -> { let (key, raw) = entry; (key, group#decode(raw)) });
        let waitingKeys = List.map(fst, waiting);
        BackgroundLoad.Internal.requestPaths(downloads, group#pathsOf, waitingKeys);
        let states = decoded
            |> List.map(entry -> { let (key, result) = entry; (key, BackgroundLoad.Internal.stateAfterDecode(result)) })
            |> List.append(waiting)
            |> List.toMap;
        BackgroundLoad.Internal.releaseLoaded(downloads, group#pathsOf, states, decoded);
        (List.toMap(decoded), { group = group#name, states = states, sentPriority = waitingKeys, costMs = group#costMs, idleSinceMs = -1.0 })

    /// 鍵 1 つの状態。表に無い鍵は Failed（綴りの誤りを待ち続けにしない）。
    pub def stateOf(key: String, pending: Pending): LoadProgress.LoadState =
        Map.getWithDefault(key, LoadProgress.LoadState.Failed("${key} は ${pending#group} の鍵に無い"), pending#states)

    /// 鍵を解いて使える形になったか。
    pub def isLoaded(key: String, pending: Pending): Bool =
        stateOf(key, pending) == LoadProgress.LoadState.Loaded

    /// keys が使えるか。waited = 待ち始めてからの秒・limit = 待つ上限の秒（超えたらその素材なしで進む）。
    /// Failed の鍵が 1 つでもあれば上限を待たずに GaveUp。
    pub def readiness(keys: List[String], pending: Pending, waited: Float64, limit: Float64): Readiness =
        let states = keys |> List.map(key -> (key, stateOf(key, pending)));
        let failure = states |> List.findMap(entry -> match snd(entry) {
            case LoadProgress.LoadState.Failed(why) => Some("${fst(entry)}: ${why}")
            case _                                  => None
        });
        let waitingKeys = states |> List.filter(entry -> snd(entry) != LoadProgress.LoadState.Loaded) |> List.map(fst);
        match failure {
            case Some(why) => Readiness.GaveUp(why)
            case None      =>
                if (List.isEmpty(waitingKeys)) Readiness.Ready
                else if (waited >= limit) Readiness.GaveUp("${String.intercalate(", ", waitingKeys)} が ${Float64.toString(limit)} 秒待っても届かない")
                else Readiness.Waiting
        }
}
