// UiHierarchy — UI entity の親子ツリー走査（完全純粋）
//
// UI ツリーは parents（子→親）と order（兄弟内の並び順）だけで表現される。
// このモジュールは「ある親の子一覧」「部分木の全 entity」「継承済み可視性」を導出する。

pub mod UiHierarchy {

    /// parent を親に持つ entity を order 昇順で返す。
    /// order 未登録の entity は 0 扱い。
    pub def childrenOf(parent: EntityId, parents: Map[EntityId, EntityId], order: Map[EntityId, Int32]): List[EntityId] =
        parents
            |> Map.foldLeftWithKey((acc, id, p) -> if (p == parent) id :: acc else acc, Nil)
            |> List.sortBy(id -> Option.getWithDefault(0, Map.get(id, order)))

    /// entity の階層深さ（root=0）。parents をたどった回数。
    pub def depthOf(id: EntityId, parents: Map[EntityId, EntityId]): Int32 =
        match Map.get(id, parents) {
            case None    => 0
            case Some(p) => 1 + depthOf(p, parents)
        }

    /// root とその全子孫を集めた集合（root 自身を含む）。
    pub def descendants(root: EntityId, parents: Map[EntityId, EntityId]): Set[EntityId] =
        descendantsRec(root :: Nil, parents, Set#{})

    /// フロンティアを 1 件ずつ処理し、未訪問なら子を積んで集合へ加える。
    def descendantsRec(frontier: List[EntityId], parents: Map[EntityId, EntityId], acc: Set[EntityId]): Set[EntityId] =
        match frontier {
            case Nil => acc
            case id :: rest =>
                if (Set.memberOf(id, acc)) descendantsRec(rest, parents, acc)
                else {
                    let kids = parents |> Map.foldLeftWithKey((a, kid, p) -> if (p == id) kid :: a else a, Nil);
                    descendantsRec(List.append(kids, rest), parents, Set.insert(id, acc))
                }
        }

    /// 「親 → 子の一覧（order 昇順）」の索引。childrenOf を全ノードで呼ぶ代わりに 1 回だけ作る。
    /// 子を持たない親は載らない（引く側は空リスト扱いにする）。
    def buildChildIndex(parents: Map[EntityId, EntityId], order: Map[EntityId, Int32]): Map[EntityId, List[EntityId]] =
        parents
            |> Map.foldLeftWithKey((acc, id, p) -> Map.insertWith((_, kids) -> id :: kids, p, id :: Nil, acc), Map.empty())
            |> Map.map(kids -> List.sortBy(id -> Option.getWithDefault(0, Map.get(id, order)), kids))

    /// 親を隠すと子も隠れる、を反映した各要素の実際の表示可否。
    /// 表示可否が未登録の entity は表示扱い。root から下へ「親が見えるか」を掛け合わせて伝える。
    pub def resolveInherited(visible: Map[EntityId, Bool], parents: Map[EntityId, EntityId],
                             root: EntityId, order: Map[EntityId, Int32]): Map[EntityId, Bool] =
        resolveInheritedRec(root, true, visible, buildChildIndex(parents, order), Map.empty())

    /// id の実効可視性 = 親の実効可視性 AND 自分の設定可視性。子孫へ再帰する。
    def resolveInheritedRec(id: EntityId, parentVisible: Bool, visible: Map[EntityId, Bool],
                            kids: Map[EntityId, List[EntityId]],
                            acc: Map[EntityId, Bool]): Map[EntityId, Bool] =
        let selfVisible = Option.getWithDefault(true, Map.get(id, visible));
        let effective = parentVisible and selfVisible;
        let acc1 = Map.insert(id, effective, acc);
        Option.getWithDefault(Nil, Map.get(id, kids))
            |> List.foldLeft((a, child) -> resolveInheritedRec(child, effective, visible, kids, a), acc1)
}
