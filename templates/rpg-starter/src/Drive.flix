// Drive — 1 フレームに押しているキーの集まりの列を、実機と同じ道（App.frameOf → App.trace）で 1/60 秒ずつ流す。
// テスト（Fixtures.play）と描き出し（SceneRender）が場面を進める口。時計を進めるのは App だけで、ここは列を渡すだけ。
mod Drive {
    use fge::{App, Dir4, Resources, Vec2}
    use fge::GameEngine.Key

    /// App の w（描く元と World の組）。
    pub type alias Run = Resources.With[Res.Res, World.World]

    /// 1 フレームの秒。
    def frameSeconds(): Float64 = 1.0 / 60.0

    /// keys を 1 フレームずつ流した後（描く元は h のまま）。
    pub def play(keys: List[Set[Key]], h: Run): Run =
        let frames = List.zip(Set.empty() :: keys, keys) |> List.map(pair ->
            App.frameOf({ prev = fst(pair) }, { current = snd(pair) }, frameSeconds(), WindowView.design(),
                        { prevCursor = None, cursor = Vec2.zero() }, { prevDown = false, down = false, wheel = 0.0 }));
        App.trace(Game.appOf(h#resources, None), frames, h) |> List.foldLeft((_, step) -> step#after, h)

    /// dir へ 1 マスずつ tiles マス歩くキーの列（1 マスごとに 1 フレーム押して離し、着くまで待つ）。
    pub def walkKeys(res: Res.Res, dir: Dir4.Dir4, tiles: Int32): List[Set[Key]] =
        let press = KeysDoc.dirKeys(KeysDoc.rec(res#keys), dir) |> List.take(1) |> List.toSet;
        let wait = Float64.ceil(RulesDoc.rec(res#rules)#secondsPerTile / frameSeconds()) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        List.repeat(tiles, press :: List.repeat(wait + 1, Set.empty())) |> List.flatten
}
