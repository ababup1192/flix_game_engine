// Persistence — 値をディスクに保存し、また読み戻すための汎用のしくみ。
// 「JSON と相互変換できる型なら保存できる」という取り決め（Saveable trait）だけ満たせば、
// セーブデータでも設定でもインベントリでも同じ save / load で永続化できる。
// 利用例: セーブデータをファイルに書く / 設定を読み込む / ハイスコアを保存する。
// 注意: I/O とエンコードは分離し、Saveable の実装は各型の責任（trait に既定実装は置かない）。
//   形式不一致は握り潰さず `None` / `Err(message)` で伝える。
pub trait Saveable[a] {

    /// 値を `Util.Json.Json` へ変換する。エンコードは全域関数を想定し
    /// 失敗を返さない（ドメイン上常に成功するため）。
    pub def toJson(value: a): Util.Json.Json

    /// `Util.Json.Json` から値を復元する。形式不一致は `None`。
    /// パース後のスキーマ検証もここで完結させる。
    pub def fromJson(element: Util.Json.Json): Option[a]
}

pub mod Persistence {

    /// `Saveable` を実装した値を `path` へ JSON で書き出す。
    /// 親ディレクトリは事前に作成されている前提
    /// （`Fs.WriteFile` は親ディレクトリを自動作成しない）。
    /// 失敗時は `Err(message)` を返す。
    pub def save(path: String, value: a): Result[String, Unit] \ Fs.FileWrite with Saveable[a] =
        let json = Saveable.toJson(value);
        let pretty = Util.Json.toPrettyString(2, json);
        let result = run {
            Fs.WriteFile.write({str = pretty}, path)
        } with Fs.WriteFile.runWithFileWrite;
        match result {
            case Ok(_)      => Ok(())
            case Err(error) => Err("save write failed: ${error}")
        }

    /// `Saveable` を実装した型を `path` から読み出す。
    /// ファイル不在・パース失敗・形式不一致は `None`。
    pub def load(path: String): Option[a] \ Fs.FileRead with Saveable[a] =
        let readResult = run {
            Fs.ReadFile.read(path)
        } with Fs.ReadFile.runWithFileRead;
        readResult
            |> Result.toOption
            |> Option.flatMap(DocJson.parse)
            |> Option.flatMap(Saveable.fromJson)
}
