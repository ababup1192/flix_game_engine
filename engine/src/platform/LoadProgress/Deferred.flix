// LoadProgress.Deferred — 後回しの素材を受ける機種の handler の、機種に依らない部品（道の状態の字・道ごとのまとめ・届く前の音の覚え書き）。

/// 後回しの素材を受ける機種の handler の、機種に依らない部品。ゲームからは呼ばない。
pub mod LoadProgress.Deferred {

    /// 機種が返す道の状態の字（"queued" / "downloading" / "downloaded" / "loaded" / "failed:理由"）を LoadState へ。知らない字は Failed。
    pub def loadStateOfText(text: String): LoadProgress.LoadState = match text {
        case "queued"      => LoadProgress.LoadState.Queued
        case "downloading" => LoadProgress.LoadState.Downloading
        case "downloaded"  => LoadProgress.LoadState.Downloaded
        case "loaded"      => LoadProgress.LoadState.Loaded
        case other         => LoadProgress.LoadState.Failed(String.stripPrefix(substr = "failed:", other) |> Option.getWithDefault(other))
    }

    /// items を道ごとにまとめる。道の並びは最初に出た順・道の中は元の順。
    /// 1 本の道を複数の名前で宣言した絵を、同じコマで全部の名前に登録するのに使う。
    pub def groupByPath(pathOf: a -> String, items: List[a]): List[(String, List[a])] =
        let paths = items |> List.map(pathOf) |> List.distinct;
        paths |> List.map(path -> (path, List.filter(item -> pathOf(item) == path, items)))

    /// 届く前の音に言われた事。playing = 鳴らせと言われて止めろと言われていない・ほかは最後に言われた値（言われていなければ None）。
    pub type alias PendingSound = { playing = Bool, looping = Option[Bool], volume = Option[Float64], pitch = Option[Float64] }

    /// 届く前の音への呼び出し（GameEngine.Audio の op のうち、届いた時に当て直す物）。
    pub enum SoundCall with Eq, ToString {
        case Play
        case Stop
        case SetVolume(Float64)
        case SetPitch(Float64)
        case SetLooping(Bool)
    }

    /// 名前 name の音への呼び出しを覚えた表へ合わせる。Stop は忘れる（届いても鳴らさず、音量も当てない）。
    pub def notePendingSound(name: String, call: SoundCall, pending: Map[String, PendingSound]): Map[String, PendingSound] =
        let before = Map.getWithDefault(name, { playing = false, looping = None, volume = None, pitch = None }, pending);
        match call {
            case SoundCall.Stop          => Map.remove(name, pending)
            case SoundCall.Play          => Map.insert(name, { playing = true | before }, pending)
            case SoundCall.SetVolume(v)  => Map.insert(name, { volume = Some(v) | before }, pending)
            case SoundCall.SetPitch(p)   => Map.insert(name, { pitch = Some(p) | before }, pending)
            case SoundCall.SetLooping(l) => Map.insert(name, { looping = Some(l) | before }, pending)
        }

    /// 届いた音を鳴らすか。declaredLooping = 宣言（project.json の looping）でループするか。
    // WhyNot: 届く前の一発の効果音を届いた時に鳴らさない — 鳴らすべき時はもう過ぎている。ループの音（環境音・BGM）は App が最初のコマに 1 回しか playAudio を出さないので、覚えないと鳴らないまま。
    pub def playsOnArrival(sound: PendingSound, declaredLooping: Bool): Bool =
        sound#playing and Option.getWithDefault(declaredLooping, sound#looping)
}
