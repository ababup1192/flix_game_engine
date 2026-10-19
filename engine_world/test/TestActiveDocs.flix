// ActiveDocs のテスト。テストするのは「エディタが読める形か」だけ —
// { "active": { id: パス } } にまとまり、1 本は文字列・複数は列で出ること。
// いつ書くか(書き込みのスキップ)は IO の振る舞いなのでテストしない。
mod TestActiveDocs {
    use Util.Json.Json.{JObject, JString, JArray}

    /// 出力を JSON として読み戻すと active の下に id が並び、
    /// パス 1 本は文字列・複数は列・空の一覧は空オブジェクトになる。
    @Test
    def testJsonShapesForEditor(): Unit \ Assert =
        let one = ("theme", "assets/x.theme.json" :: Nil) :: Nil;
        let many = ("ui", "assets/ui/a.ui.json" :: "assets/ui/b.ui.json" :: Nil) :: Nil;
        Assert.assertEq(
            expected = (
                Some(JObject(Map#{"active" => JObject(Map#{"theme" => JString("assets/x.theme.json")})})),
                Some(JObject(Map#{"active" => JObject(Map#{"ui" =>
                    JArray(Vector#{JString("assets/ui/a.ui.json"), JString("assets/ui/b.ui.json")})})})),
                Some(JObject(Map#{"active" => JObject(Map.empty())}))
            ),
            (DocJson.parse(ActiveDocs.json(one)),
             DocJson.parse(ActiveDocs.json(many)),
             DocJson.parse(ActiveDocs.json(Nil))))

    /// 同じ一覧なら指紋も同じ(App.withDocTable の出力の鍵 = 変わらないフレームで書き込みをスキップする根拠)。
    @Test
    def testFingerprintStableForSameEntries(): Unit \ Assert =
        let entries = ("theme", "assets/x.theme.json" :: Nil)
            :: ("ui", "assets/ui/a.ui.json" :: "assets/ui/b.ui.json" :: Nil) :: Nil;
        Assert.assertEq(expected = ActiveDocs.fingerprint(entries), ActiveDocs.fingerprint(entries))

    /// パスを 1 本差し替えると指紋が変わる(差し替え後のフレームで新しい JSON が書かれる根拠)。
    @Test
    def testFingerprintChangesWhenPathSwapped(): Unit \ Assert =
        let before = ("theme", "assets/x.theme.json" :: Nil) :: Nil;
        let after = ("theme", "assets/y.theme.json" :: Nil) :: Nil;
        Assert.assertEq(expected = false,
            ActiveDocs.fingerprint(before) == ActiveDocs.fingerprint(after))

    /// id とパスの境目は区切り文字で守られる(連結で同じ文字列になる組を取り違えない)。
    @Test
    def testFingerprintSeparatesIdAndPath(): Unit \ Assert =
        let a = ("ab", "c.json" :: Nil) :: Nil;
        let b = ("a", "bc.json" :: Nil) :: Nil;
        Assert.assertEq(expected = false,
            ActiveDocs.fingerprint(a) == ActiveDocs.fingerprint(b))
}
