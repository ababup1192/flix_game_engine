// Bgm — 曲の名前（マップの Doc の bgm の値と、project.json の sounds の論理名）。
// どの場面でどの曲を鳴らすかは Controls.musicOf。素材は art/bgm.snd.star → assets/bgm。
mod Bgm {

    /// 曲。Title = タイトル / Village = 村（家の中とエンディングも）/ World = ワールドマップ / Mine = 坑道 /
    /// Battle = 戦い / Boss = 逃げられない敵との戦い。
    pub enum Track with Eq, Order, ToString {
        case Title
        case Village
        case World
        case Mine
        case Battle
        case Boss
    }

    /// 全部の曲（project.json の sounds に載っているかのテストが引く）。
    pub def all(): List[Track] =
        Track.Title :: Track.Village :: Track.World :: Track.Mine :: Track.Battle :: Track.Boss :: Nil

    /// Doc の名前 → 曲。知らない名前は None（読む側が既定へ落として 1 行言う）。
    pub def idOf(name: String): Option[Track] = all() |> List.find(t -> nameOf(t) == name)

    /// Doc に書く名前。
    def nameOf(t: Track): String = match t {
        case Track.Title   => "title"
        case Track.Village => "village"
        case Track.World   => "world"
        case Track.Mine    => "mine"
        case Track.Battle  => "battle"
        case Track.Boss    => "boss"
    }

    /// project.json の sounds の論理名（= assets/bgm の WAV の名前）。
    /// WhyNot: "bgm_" + nameOf(t) と組まない — 名前を字のまま書いておくと make lint-audio と grep が project.json と突き合わせられる。
    pub def soundOf(t: Track): String = match t {
        case Track.Title   => "bgm_title"
        case Track.Village => "bgm_village"
        case Track.World   => "bgm_world"
        case Track.Mine    => "bgm_mine"
        case Track.Battle  => "bgm_battle"
        case Track.Boss    => "bgm_boss"
    }
}
