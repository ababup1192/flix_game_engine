// PropertyTween — 名前の付いた舞台の値と、その値を時間で変える tween の表（純粋）。名前は Godot の Tween.tween_property に合わせた。
// 値は 3 種類で、鍵の型を分けて取り違えを止める:
//   数（NumKey）     origin から target へ ease の曲線で動く（overlay.alpha・camera.zoom など）
//   名前（NameKey）  決めた時刻にすぐ替わる。None は「無い」（audio.ambience・fx.particles など）
//   一度だけの演出（TriggerKey）  始まってから seconds の間だけ「始まってからの秒」を返す（camera.shake など）。settle で消える
// どれも delay で始まりを遅らせられる。同じ鍵に後から書いた物は、それより後に始まる予定の物を捨てて置き換える。
// 鍵は「層.値」。ゲームが足す値は game. で始める。
//
//   let k = PropertyTween.numKey("overlay.alpha");
//   let t = PropertyTween.tween(k, None, 0.6, now, 0.0, 1.5, Curve.Ease.SmoothStep, PropertyTween.empty());
//   PropertyTween.numAt(now, k, 0.0, t)      // View が読む
//   PropertyTween.settle(t)                  // 遅れて始まる物も含め、全部を終わりの値にする
//   PropertyTween.toJson(t) / fromJson(json) // セーブ（終わりの値だけ）
//
// c は値を進める時計の名前（Clock.Time[c]）。
mod PropertyTween {
    use fge::{Clock, Curve, JsonCodec}
    use Util.Json.Json

    enum NumKeyOf(String) with Eq

    enum NameKeyOf(String) with Eq

    enum TriggerKeyOf(String) with Eq

    /// 数の値の鍵。
    pub type alias NumKey = NumKeyOf

    /// 名前の値の鍵。
    pub type alias NameKey = NameKeyOf

    /// 一度だけの演出の鍵。
    pub type alias TriggerKey = TriggerKeyOf

    /// startsAt から seconds かけて origin から target へ。
    type alias NumTrack[c] = { origin = Float64, target = Float64, startsAt = Clock.Time[c], seconds = Float64, ease = Curve.Ease }

    /// startsAt から value。
    type alias NameTrack[c] = { value = Option[String], startsAt = Clock.Time[c] }

    /// startsAt から seconds の間だけ。
    type alias TriggerTrack[c] = { startsAt = Clock.Time[c], seconds = Float64 }

    /// 鍵ごとの予定の列（始まる時刻の順）。列の頭が始まる前は値が無い（読む側の fallback・名前は None）。
    enum TableOf[c]({ nums = Map[String, List[NumTrack[c]]], names = Map[String, List[NameTrack[c]]], triggers = Map[String, List[TriggerTrack[c]]] })

    /// 名前の付いた値の表（外からは tween・setName・trigger だけで書く）。
    pub type alias Table[c] = TableOf[c]

    pub def numKey(name: String): NumKey = NumKeyOf.NumKeyOf(name)

    pub def nameKey(name: String): NameKey = NameKeyOf.NameKeyOf(name)

    pub def triggerKey(name: String): TriggerKey = TriggerKeyOf.TriggerKeyOf(name)

    pub def empty(): Table[c] = TableOf.TableOf({ nums = Map.empty(), names = Map.empty(), triggers = Map.empty() })

    def tracks(t: Table[c]): { nums = Map[String, List[NumTrack[c]]], names = Map[String, List[NameTrack[c]]], triggers = Map[String, List[TriggerTrack[c]]] } =
        let TableOf.TableOf(r) = t;
        r

    def numName(k: NumKey): String = let NumKeyOf.NumKeyOf(s) = k; s

    def nameName(k: NameKey): String = let NameKeyOf.NameKeyOf(s) = k; s

    def triggerName(k: TriggerKey): String = let TriggerKeyOf.TriggerKeyOf(s) = k; s

    // ── 書く ──

    /// k を now + delay から seconds かけて to へ動かす。origin が None なら動き始める時刻の値から（値がまだ無ければ to のまま）。
    pub def tween(k: NumKey, origin: Option[Float64], to: Float64, now: Clock.Time[c], delay: Float64, seconds: Float64,
                  ease: Curve.Ease, t: Table[c]): Table[c] =
        let r = tracks(t);
        let startsAt = Clock.after(Float64.max(0.0, delay), now);
        let kept = Map.getWithDefault(numName(k), Nil, r#nums) |> schedule(now, startsAt, x -> x#startsAt);
        let start = origin |> Option.withDefault(default = numIn(startsAt, kept)) |> Option.getWithDefault(to);
        let track = { origin = start, target = to, startsAt = startsAt, seconds = Float64.max(0.0, seconds), ease = ease };
        TableOf.TableOf({ nums = Map.insert(numName(k), List.append(kept, track :: Nil), r#nums) | r })

    /// k を now + delay にすぐ value へ替える（tween の秒が 0 の物）。
    pub def setNum(k: NumKey, value: Float64, now: Clock.Time[c], delay: Float64, t: Table[c]): Table[c] =
        tween(k, Some(value), value, now, delay, 0.0, Curve.Ease.Linear, t)

    /// k を now + delay に value へ替える（None は「無い」）。
    pub def setName(k: NameKey, value: Option[String], now: Clock.Time[c], delay: Float64, t: Table[c]): Table[c] =
        let r = tracks(t);
        let startsAt = Clock.after(Float64.max(0.0, delay), now);
        let kept = Map.getWithDefault(nameName(k), Nil, r#names) |> schedule(now, startsAt, x -> x#startsAt);
        TableOf.TableOf({ names = Map.insert(nameName(k), List.append(kept, { value = value, startsAt = startsAt } :: Nil), r#names) | r })

    /// k を now + delay から seconds の間だけ起こす（揺れ・刺さる、など）。
    pub def trigger(k: TriggerKey, now: Clock.Time[c], delay: Float64, seconds: Float64, t: Table[c]): Table[c] =
        let r = tracks(t);
        let startsAt = Clock.after(Float64.max(0.0, delay), now);
        let kept = Map.getWithDefault(triggerName(k), Nil, r#triggers)
            |> List.filter(x -> Clock.since(x#startsAt, now) < x#seconds)
            |> List.filter(x -> Clock.since(x#startsAt, startsAt) > 0.0);
        let track = { startsAt = startsAt, seconds = Float64.max(0.0, seconds) };
        TableOf.TableOf({ triggers = Map.insert(triggerName(k), List.append(kept, track :: Nil), r#triggers) | r })

    /// 新しい予定を startsAt に足す前の列: startsAt 以後に始まる予定を捨て、now までに始まった物は最後の 1 つだけ残す（前の物はもう読まれない）。
    def schedule(now: Clock.Time[c], startsAt: Clock.Time[c], startOf: a -> Clock.Time[c], xs: List[a]): List[a] =
        let early = xs |> List.filter(x -> Clock.since(startOf(x), startsAt) > 0.0);
        let started = early |> List.filter(x -> Clock.since(startOf(x), now) >= 0.0);
        let pending = early |> List.filter(x -> Clock.since(startOf(x), now) < 0.0);
        List.append(List.last(started) |> Option.toList, pending)

    // ── 読む ──

    /// k の now の値（始まった予定がまだ無ければ fallback）。
    pub def numAt(now: Clock.Time[c], k: NumKey, fallback: Float64, t: Table[c]): Float64 =
        numIn(now, Map.getWithDefault(numName(k), Nil, tracks(t)#nums)) |> Option.getWithDefault(fallback)

    def numIn(now: Clock.Time[c], xs: List[NumTrack[c]]): Option[Float64] =
        match lastStarted(now, x -> x#startsAt, xs) {
            case Some(x) =>
                let progress = if (x#seconds <= 0.0) 1.0 else Clock.since(x#startsAt, now) / x#seconds;
                Some(x#origin + (x#target - x#origin) * Curve.ease(x#ease, progress))
            case None => None
        }

    /// k の now の値（無い・まだ一度も書いていなければ None）。
    pub def nameAt(now: Clock.Time[c], k: NameKey, t: Table[c]): Option[String] =
        lastStarted(now, x -> x#startsAt, Map.getWithDefault(nameName(k), Nil, tracks(t)#names)) |> Option.flatMap(x -> x#value)

    /// k の now の値に替わってからの秒（まだ一度も書いていなければ None・セーブから戻した値はとても大きな秒）。
    pub def nameSince(now: Clock.Time[c], k: NameKey, t: Table[c]): Option[Float64] =
        lastStarted(now, x -> x#startsAt, Map.getWithDefault(nameName(k), Nil, tracks(t)#names)) |> Option.map(x -> Clock.since(x#startsAt, now))

    /// k が now に起きていれば、始まってからの秒（始まる前・終わった後は None）。
    pub def triggerAt(now: Clock.Time[c], k: TriggerKey, t: Table[c]): Option[Float64] =
        lastStarted(now, x -> x#startsAt, Map.getWithDefault(triggerName(k), Nil, tracks(t)#triggers))
            |> Option.map(x -> (Clock.since(x#startsAt, now), x#seconds))
            |> Option.filter(match (since, seconds) -> since < seconds)
            |> Option.map(fst)

    /// k が now に起きていれば、始まってからの秒と長さ（始まる前・終わった後は None）。だんだん収まる揺れが残りの割合を出すのに使う。
    pub def triggerSpanAt(now: Clock.Time[c], k: TriggerKey, t: Table[c]): Option[(Float64, Float64)] =
        lastStarted(now, x -> x#startsAt, Map.getWithDefault(triggerName(k), Nil, tracks(t)#triggers))
            |> Option.map(x -> (Clock.since(x#startsAt, now), x#seconds))
            |> Option.filter(match (since, seconds) -> since < seconds)

    /// k の予定が全部済んだ後の値（まだ一度も書いていなければ fallback）。
    pub def numEnd(k: NumKey, fallback: Float64, t: Table[c]): Float64 =
        Map.getWithDefault(numName(k), Nil, tracks(t)#nums) |> List.last |> Option.map(x -> x#target) |> Option.getWithDefault(fallback)

    /// k の予定が全部済んだ後の値。
    pub def nameEnd(k: NameKey, t: Table[c]): Option[String] =
        Map.getWithDefault(nameName(k), Nil, tracks(t)#names) |> List.last |> Option.flatMap(x -> x#value)

    def lastStarted(now: Clock.Time[c], startOf: a -> Clock.Time[c], xs: List[a]): Option[a] =
        xs |> List.filter(x -> Clock.since(startOf(x), now) >= 0.0) |> List.last

    // ── 終わらせる・残す ──

    /// 全部を終わりの値にする（遅れて始まる物も）。一度だけの演出は消す。
    pub def settle(t: Table[c]): Table[c] =
        let r = tracks(t);
        let nums = r#nums |> Map.filterMap(xs -> List.last(xs) |> Option.map(x -> settledNum(x#target) :: Nil));
        let names = r#names |> Map.filterMap(xs -> List.last(xs) |> Option.map(x -> settledName(x#value) :: Nil));
        TableOf.TableOf({ nums = nums, names = names, triggers = Map.empty() })

    def settledNum(value: Float64): NumTrack[c] =
        { origin = value, target = value, startsAt = Clock.never(), seconds = 0.0, ease = Curve.Ease.Linear }

    def settledName(value: Option[String]): NameTrack[c] = { value = value, startsAt = Clock.never() }

    /// セーブに書く形: { "nums": { 鍵: 終わりの値 }, "names": { 鍵: 終わりの値か null } }。一度だけの演出は書かない。
    pub def toJson(t: Table[c]): Json =
        let r = settle(t) |> tracks;
        let nums = r#nums |> Map.filterMap(List.head) |> Map.map(x -> Json.JNumber(JsonCodec.floatToBd(x#target)));
        let names = r#names |> Map.filterMap(List.head) |> Map.map(x -> x#value |> Option.map(Json.JString) |> Option.getWithDefault(Json.JNull));
        Json.JObject(Map#{ "nums" => Json.JObject(nums), "names" => Json.JObject(names) })

    /// toJson の形から、終わりの値だけの表へ戻す。欄の型が違えば Err。
    pub def fromJson(json: Json): Result[String, Table[c]] =
        let root = JsonCodec.expectObject(json) |> Option.toOk("PropertyTween: object でない");
        let section = (name, obj) -> match Map.get(name, obj) {
            case None    => Ok(Map.empty())
            case Some(j) => JsonCodec.expectObject(j) |> Option.toOk("PropertyTween: ${name} が object でない")
        };
        let num = (key, j) -> JsonCodec.expectFloat(j) |> Option.map(settledNum) |> Option.toOk("PropertyTween: nums.${key} が数でない");
        let name = (key, j) -> match j {
            case Json.JNull => Ok(settledName(None))
            case _          => JsonCodec.expectString(j) |> Option.map(s -> settledName(Some(s))) |> Option.toOk("PropertyTween: names.${key} が文字か null でない")
        };
        forM (
            obj <- root;
            numsJson <- section("nums", obj);
            namesJson <- section("names", obj);
            nums <- decodeEach(num, numsJson);
            names <- decodeEach(name, namesJson)
        ) yield TableOf.TableOf({ nums = nums |> Map.map(x -> x :: Nil), names = names |> Map.map(x -> x :: Nil), triggers = Map.empty() })

    def decodeEach(f: (String, Json) -> Result[String, a], obj: Map[String, Json]): Result[String, Map[String, a]] =
        obj |> Map.toList |> Result.traverse(match (key, j) -> f(key, j) |> Result.map(v -> (key, v))) |> Result.map(List.toMap)
}
