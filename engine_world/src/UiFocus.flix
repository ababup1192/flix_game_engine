// UiFocus — マウス座標の下にある一番手前の UI 要素を見つけて返す。
// クリックやホバーがどの要素に当たったかを一箇所で判定できるので、各所で当たり判定を書かずに済む。
// 利用例: ボタンのクリック先を決める / ホバー中の項目を知る / メニューを掴んでいるか調べる。
// 注意: 当たった要素を返すだけ。当たった後にどう反応するか（キー入力の宛先など）はゲーム側の仕事。

pub mod UiFocus {

    /// `hitTest` が当たり判定に使う対象シーンの記述。
    /// `rects`: 各 entity の画面矩形。`vis`: 各 entity の可視（未登録は可視扱い）。
    /// `zOf`/`depthOf`: entity → zIndex / 階層深さ（最前面判定に使う）。
    pub type alias HitTestScene = {
        rects   = Map[EntityId, Rect2.Rect2],
        vis     = Map[EntityId, Bool],
        zOf     = EntityId -> Int32,
        depthOf = EntityId -> Int32
    }

    /// point を含む可視 entity のうち最前面のものを返す。
    /// 最前面判定は (zIndex, 階層深さ, id) の大きい方を優先する（z 同値なら深い方、深さも同値なら id 大）。
    /// vis 未登録の entity は可視扱い。当たりが無ければ None。
    pub def hitTest(scene: HitTestScene, point: Vec2.Vec2): Option[EntityId] =
        scene#rects |> Map.foldLeftWithKey((best, id, rect) ->
            if (Rect2.hasPoint(point, rect) and Option.getWithDefault(true, Map.get(id, scene#vis)))
                betterHit(best, id, scene#zOf, scene#depthOf)
            else best,
            None)

    /// UiWorld 全体を design 空間でレイアウトして最前面ヒットを引く（マウスの hover / click の入口）。
    /// 当たるのは面積のある rect だけ — text は実寸を測らず 0 サイズになるので当たらない。
    /// 当たり判定の対象には width/height を Px で持つノード（ボタンのコンテナや図形）を使うこと。
    /// コンテナも rect を持つので当たる（root は画面全面）— 呼び手は meta の有無で選別する。
    pub def hitTestUi(ui: UiStore.UiWorld, design: Vec2.Vec2, point: Vec2.Vec2): Option[EntityId] =
        let rootRect: Rect2.Rect2 = {position = {x = 0.0, y = 0.0}, size = design};
        let roots = UiStore.rootsOf(ui);
        let rects = roots |> List.foldLeft((acc, root) -> Map.union(
            UiLayout.computeLayout(
                {styles = ui#styles, parents = ui#parents, order = ui#order,
                 measures = Map.empty(), visible = ui#visible},
                root, rootRect), acc), Map.empty())
            |> Map.filter(r -> r#size#x > 0.0 and r#size#y > 0.0);
        let vis = roots |> List.foldLeft((acc, root) -> Map.union(
            UiHierarchy.resolveInherited(ui#visible, ui#parents, root, ui#order), acc), Map.empty());
        hitTest({rects = rects, vis = vis,
                 zOf = id -> zIndexOf(id, ui),
                 depthOf = id -> UiHierarchy.depthOf(id, ui#parents)}, point)

    /// entity の描画 zIndex（いずれかの描画コンポーネントの zIndex。描画物なしは 0）。
    def zIndexOf(id: EntityId, ui: UiStore.UiWorld): Int32 =
        let candidates =
               (Map.get(id, ui#boxes)   |> Option.map(c -> c#zIndex))
            :: (Map.get(id, ui#texts)   |> Option.map(c -> c#zIndex))
            :: (Map.get(id, ui#sprites) |> Option.map(c -> c#zIndex))
            :: (Map.get(id, ui#polys)   |> Option.map(c -> c#zIndex))
            :: (Map.get(id, ui#shapes)  |> Option.map(c -> c#zIndex))
            :: Nil;
        candidates |> List.findMap(z -> z) |> Option.getWithDefault(0)

    /// 既存の当たり best と候補 candidate を比べ、(zIndex, 深さ, id) が大きい方を残す。
    def betterHit(best: Option[EntityId], candidate: EntityId,
                  zOf: EntityId -> Int32, depthOf: EntityId -> Int32): Option[EntityId] =
        match best {
            case None => Some(candidate)
            case Some(current) =>
                let currentKey = (zOf(current), depthOf(current), current);
                let candidateKey = (zOf(candidate), depthOf(candidate), candidate);
                if (candidateKey > currentKey) Some(candidate) else Some(current)
        }
}
