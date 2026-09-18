// SfxTuneDoc — race.sfxtune.json（効果音のつまみ）の宣言ドキュメント層。
// 音の中身（どんな波を重ねるか）は src/render/SfxRender.flix のデザインで、ここはそれに掛ける
// 3 つのつまみ（音量・高さ・長さ）だけを持つ。どの出来事で鳴らすかは Sfx.flix。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
//
// つまみは WAV を生成するときに効く（make render-all → 起動し直す）。engine の高さの振れ幅
// （enginePitchLow / enginePitchHigh）だけは鳴らしながら掛ける値なので保存で即反映される。
mod SfxTuneDoc {
    use Util.Json.Json

    /// 音 1 つぶんのつまみ。volume = 音量（0..1）、pitch = 高さの倍率、
    /// speed = 鳴りの速さの倍率（大きいほど短く鋭い）。
    pub type alias Knobs = { volume = Float64, pitch = Float64, speed = Float64 }

    /// 効果音 13 種のつまみ。名前は project.json の sounds の name と同じ
    /// （Studio の音の絵はこの名前で生成した WAV を探す）。
    pub type alias Rec = {
        version = Int32,
        enginePitchLow = Float64,   // 止まっているときのエンジン音の高さ
        enginePitchHigh = Float64,  // 最高速のときのエンジン音の高さ
        engine = Knobs,          // 走っている間ずっと続く唸り
        skid = Knobs,            // ドリフト中の擦れ（滑っている間ずっと続く）
        scrape = Knobs,          // ガードレールを擦っている間の金属音（擦っている間ずっと続く）
        grip = Knobs,            // ドリフトの終わり（食いついた）
        nitro = Knobs,           // ニトロ発動
        crash = Knobs,           // 直撃・草落ちのスピン
        bump = Knobs,            // ライバルとの押し合い
        item = Knobs,            // アイテム取得
        overtake = Knobs,        // ライバルを 1 台抜いた
        lap = Knobs,             // 1 周した
        win = Knobs,             // 完走（最下位以外）
        lose = Knobs,            // 完走（最下位）
        start = Knobs            // 決定（開始・仕切り直し）
    }

    // 型検査が record を展開しないため、World が持つ公開の型は enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/race.sfxtune.json"

    /// つまみを触っていない状態（音量だけは音ごとの釣り合いを持つ）。
    def plain(volume: Float64): Knobs = { volume = volume, pitch = 1.0, speed = 1.0 }

    /// コード側の既定値（assets/race.sfxtune.json と同じ値から出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          enginePitchLow = 0.7,
          enginePitchHigh = 1.9,
          engine = plain(0.32),
          skid = plain(0.45),
          scrape = plain(0.4),
          grip = plain(0.4),
          nitro = plain(1.0),
          crash = plain(0.9),
          bump = plain(0.45),
          item = plain(0.7),
          overtake = plain(0.55),
          lap = plain(0.7),
          win = plain(0.9),
          lose = plain(0.8),
          start = plain(0.6) })

    /// テキストから Doc へ（fail-open）。JSON でない・形が違うフィールドは既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          enginePitchLow = JsonCodec.floatOr("enginePitchLow", d#enginePitchLow, root),
          enginePitchHigh = JsonCodec.floatOr("enginePitchHigh", d#enginePitchHigh, root),
          engine = knobsOr("engine", d#engine, root),
          skid = knobsOr("skid", d#skid, root),
          scrape = knobsOr("scrape", d#scrape, root),
          grip = knobsOr("grip", d#grip, root),
          nitro = knobsOr("nitro", d#nitro, root),
          crash = knobsOr("crash", d#crash, root),
          bump = knobsOr("bump", d#bump, root),
          item = knobsOr("item", d#item, root),
          overtake = knobsOr("overtake", d#overtake, root),
          lap = knobsOr("lap", d#lap, root),
          win = knobsOr("win", d#win, root),
          lose = knobsOr("lose", d#lose, root),
          start = knobsOr("start", d#start, root) })

    /// 音 1 つぶんの入れ子の節を読む。節ごと無い・object でないときは既定のつまみ。
    /// 倍率は 0 以下だと長さ 0 の無音や逆再生になるので、下限で受け止める。
    def knobsOr(key: String, d: Knobs, root: Map[String, Json]): Knobs =
        match Map.get(key, root) |> Option.flatMap(JsonCodec.expectObject) {
            case None      => d
            case Some(obj) =>
                { volume = Num.clamp01(JsonCodec.floatOr("volume", d#volume, obj)),
                  pitch = Float64.max(0.1, JsonCodec.floatOr("pitch", d#pitch, obj)),
                  speed = Float64.max(0.1, JsonCodec.floatOr("speed", d#speed, obj)) }
        }

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
