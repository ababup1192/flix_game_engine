// TownMapDoc — town.map.json（街のタイル盤: rows と legend）の宣言ドキュメント層。
// タイルは名前（town_*.sprite.json のスプライト名）で引く — アトラス内のピクセル座標を
// Doc に書かないのは、sprite Doc の変更でアトラスが再パックされたとき Doc が黙って
// 壊れるため。位置の解決は読み込んだ後に regionOf がやる。
// fail-open — 読めない・壊れているときは defaults() へ落とし、絵は必ず出る。
mod TownMapDoc {
    use Util.Json.Json

    /// 街のタイル盤。legend = rows の 1 文字 → タイル名、rows = 敷き方の文字格子。
    /// legend に無い文字のマスは敷かれない（下の色が見えるだけ — 落ちない）。
    pub type alias Rec = {
        version = Int32,
        legend = Map[Char, String],
        rows = List[String]
    }

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/town.map.json"

    /// コード側の既定値（assets/town.map.json と同じ盤から出発する）。
    /// 中央に石畳の広場と十字の道、周囲に芝、右側に縦の水路、上辺に漆喰壁の帯。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          legend = Map#{'g' => "tile_grass", 'p' => "tile_pave",
                        'w' => "tile_water", '#' => "tile_wall"},
          rows =
                 "####################"
              :: "ggggggggppggggggwwgg"
              :: "ggggggggppggggggwwgg"
              :: "ggggggggppggggggwwgg"
              :: "ggggggggppggggggwwgg"
              :: "ggggggpppppppppgwwgg"
              :: "ggggggpppppppppgwwgg"
              :: "gpppppppppppppppwwgg"
              :: "ggggggpppppppppgwwgg"
              :: "ggggggpppppppppgwwgg"
              :: "ggggggggppggggggwwgg"
              :: "ggggggggppggggggwwgg"
              :: "ggggggggppggggggwwgg"
              :: "ggggggggppggggggwwgg"
              :: "ggggggggppggggggwwgg"
              :: Nil })

    /// rows の 1 文字 → タイル名。legend に無い文字は None（敷かない = fail-open）。
    pub def tileNameOf(doc: Doc, ch: Char): Option[String] =
        Map.get(ch, rec(doc)#legend)

    /// 盤の列数（一番長い行に合わせる。短い行の足りない分は敷かれないだけ）。
    pub def cols(doc: Doc): Int32 =
        rec(doc)#rows |> List.map(String.length) |> List.foldLeft(Int32.max, 0)

    /// 盤の行数。
    pub def rowCount(doc: Doc): Int32 =
        List.length(rec(doc)#rows)

    // ── JSON からの読み込み ──

    /// テキストから Doc へ（fail-open）。JSON でない・形が違うフィールドは既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          legend = legendOf(root) |> Option.getWithDefault(d#legend),
          rows = Map.get("rows", root)
              |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString))
              |> Option.getWithDefault(d#rows) })

    /// legend: {"g": "tile_grass", ...}。キーが 1 文字でない・値が文字列でない項は
    /// 黙って捨てる（その文字のマスが敷かれないだけ）。
    def legendOf(root: Map[String, Json]): Option[Map[Char, String]] =
        Map.get("legend", root)
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(m -> m
                |> Map.toList
                |> List.filterMap(entry -> {
                    let (k, v) = entry;
                    match (String.toList(k), JsonCodec.expectString(v)) {
                        case (ch :: Nil, Some(name)) => Some((ch, name))
                        case _                       => None
                    }
                })
                |> List.toMap)

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
