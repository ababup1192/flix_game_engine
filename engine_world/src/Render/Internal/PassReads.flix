// Render.Internal.PassReads — Pass の items が読む名前（面の tex / blur・sprite と billboard の texture）を集めて書き換える所。resolvePassReads の中身。
// ゲームからは呼ばない（Render の中身）。
pub mod Render.Internal.PassReads {
    import java.lang.{Object => JObject}
    import java.util.IdentityHashMap

    /// 読んではいけない名前の置き換え先（必ず存在しない名前 — 面は黒・sprite は貼らない）。
    pub def missingName(name: String): String = "@missing:" + name

    /// items が読む名前（面の tex / blur と sprite の texture）を初出順・重複なしで。面の名前は texNamesOf に覚える。
    pub def passReadNames(texNamesOf: IdentityHashMap[JObject, JObject], items: List[Render.PlacedItem]): List[String] \ IO =
        items |> List.flatMap(placed -> {
            let (leaf, _clip) = Render.unwrapClip(placed#item, None);
            match leaf {
                case Render.Item.Sprite(sp)  => sp#texture :: Nil
                case Render.Item.Shader(sh)  => Render.cachedBySpec(texNamesOf, ShaderDoc.texNames, sh#spec)
                case Render.Item.Scene3d(sc) => sc#billboards |> List.map(b -> Scene3d.billboardFieldsOf(b)#texture)
                case _                       => Nil
            }
        }) |> List.distinct

    /// 読む名前 names が f で 1 つも変わらないなら spec そのもの（同じ物）を、変わるなら書き換えた Spec を返す。
    /// WhyNot: 変わらない時も renameTex を通さない — 木を丸ごと作り直すので、毎コマ別の物になって
    /// program の当たり（ShaderGen.eqSpec の参照の早抜け）が外れ、構造の比べに戻る。
    pub def renameKeepingSame(f: String -> String, names: List[String], spec: ShaderDoc.Spec): ShaderDoc.Spec =
        if (List.forAll(name -> f(name) == name, names)) spec
        else ShaderDoc.renameTex(f, spec)

    /// 面の tex / blur（renameSpec）と sprite の texture（f）の名前を替える（Clipped の中まで）。
    pub def renameReads(f: String -> String, renameSpec: ShaderDoc.Spec -> ShaderDoc.Spec \ IO, item: Render.Item): Render.Item \ IO =
        onLeafIO(leaf -> match leaf {
            case Render.Item.Sprite(sp)  => Render.Item.Sprite({ texture = f(sp#texture) | sp })
            case Render.Item.Shader(sh)  => Render.Item.Shader({ spec = renameSpec(sh#spec) | sh })
            case Render.Item.Scene3d(sc) => Render.Item.Scene3d({ billboards = List.map(renameBillboard(f), sc#billboards) | sc })
            case other            => other
        }, item)

    /// ビルボードの貼る絵の名前だけを f で替える（ほかの欄はそのまま）。
    // WhyNot: Scene3d に名前を替える口を足さない — engine の閉じた型を増やさずに、公開の作る関数で組み直せる。
    def renameBillboard(f: String -> String, b: Scene3d.Billboard3d): Scene3d.Billboard3d =
        let r = Scene3d.billboardFieldsOf(b);
        let renamed = f(r#texture);
        if (renamed == r#texture) b
        else {
            let base = Scene3d.billboard(renamed, r#regionRect, r#position, r#size)
                |> Scene3d.withAnchor(r#anchor)
                |> Scene3d.withBillboardTint(r#tint);
            if (r#lit) base else Scene3d.unlit(base)
        }

    /// onLeaf の、葉の書き換えに効果のある形。
    def onLeafIO(f: Render.Item -> Render.Item \ IO, item: Render.Item): Render.Item \ IO =
        match item {
            case Render.Item.Clipped(c) => Render.Item.Clipped({ inner = onLeafIO(f, c#inner) | c })
            case leaf                   => f(leaf)
        }
}
