// Knobs — 描き方の重さのつまみの表（鍵 → 値）。実機は環境変数（Main）・ブラウザは頁の URL の query（WebMain）から作る。
// WhyNot: 環境変数を読む口をここに置かない — ブラウザの組み立てが JVM の System へ届く。
mod Knobs {
    /// つまみの表。
    pub type alias Knobs = Map[String, String]

    /// [鍵, 値, 鍵, 値, …] の平らな列（頁の query）からつまみの表を作る。余った鍵は捨てる。
    pub def ofPairs(flat: List[String]): Knobs = match flat {
        case k :: v :: rest => Map.insert(k, v, ofPairs(rest))
        case _              => Map.empty()
    }

    /// (環境変数の名前, つまみの鍵) の表（Main が環境変数を読む時に引く）。
    pub def envNames(): List[(String, String)] = ("SHADOW_MAP", "shadow") :: ("DOF", "dof") :: ("POST", "post") :: Nil
}
