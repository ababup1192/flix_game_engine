mod TestSaveFormat {

    use Util.Json.Json
    use Util.Json.Json.{JObject, JArray, JNumber}

    /// 道 → 字のファイルの表。
    type alias Disk = Map[String, String]

    /// 版 1 は包み無しで {"version": 1, "hp": n}、版 2 で hp を life に、版 3 で items を足した形式。
    def demoFormat(): SaveFormat.Format =
        SaveFormat.make("demo", 3)
            |> SaveFormat.withMigration(1, renameHpToLife)
            |> SaveFormat.withMigration(2, addItems)
            |> SaveFormat.withUnwrappedVersion(json ->
                JsonCodec.expectObject(json) |> Option.map(obj -> JsonCodec.intOr("version", 1, obj)) |> Option.getWithDefault(1))

    def renameHpToLife(json: Json): Result[String, Json] =
        JsonCodec.expectObject(json)
            |> Option.flatMap(obj -> Map.get("hp", obj) |> Option.map(hp -> JObject(Map#{ "life" => hp })))
            |> Option.toOk("hp が無い")

    def addItems(json: Json): Result[String, Json] =
        JsonCodec.expectObject(json)
            |> Option.map(obj -> JObject(Map.insert("items", JArray(Vector#{}), obj)))
            |> Option.toOk("object でない")

    /// 版 3 の中身から life を読む。items が無ければ Err。
    def readDemo(json: Json): Result[String, Int32] =
        JsonCodec.expectObject(json)
            |> Option.flatMap(obj -> forM (
                life <- Map.get("life", obj) |> Option.flatMap(JsonCodec.expectInt);
                _items <- Map.get("items", obj)
            ) yield life)
            |> Option.toOk("life か items が無い")

    def lifeData(life: Int32): Json =
        JObject(Map#{ "life" => JNumber(JsonCodec.intToBd(life)), "items" => JArray(Vector#{}) })

    def text(json: Json): String = Util.Json.toPrettyString(2, json)

    /// f を disk の上で流し、結果と流した後の disk を返す。
    def onDisk(disk: Disk, f: Unit -> a \ ef + Fs.FileRead + Fs.FileWrite): (a, Disk) \ ef =
        region rc {
            let files = Ref.fresh(rc, disk);
            let found = path -> Map.get(path, Ref.get(files)) |> Option.toOk(IoError.IoError(IoError.ErrorKind.NotFound, path));
            let put = (path, body) -> { Ref.put(Map.insert(path, body, Ref.get(files)), files); Ok(()) };
            let unsupported = path -> Err(IoError.IoError(IoError.ErrorKind.Unsupported, path));
            let result = run f() with handler Fs.FileRead {
                def read(path, k)      = k(found(path))
                def readLines(path, k) = k(found(path) |> Result.map(String.lines))
                def readBytes(path, k) = k(found(path) |> Result.map(String.toBytes))
            } with handler Fs.FileWrite {
                def write(data, path, k)          = k(put(path, data#str))
                def writeLines(_data, path, k)    = k(unsupported(path))
                def writeBytes(_data, path, k)    = k(unsupported(path))
                def append(_data, path, k)        = k(unsupported(path))
                def appendLines(_data, path, k)   = k(unsupported(path))
                def appendBytes(_data, path, k)   = k(unsupported(path))
                def truncate(path, k)             = k(unsupported(path))
                def copyWith(_src, dst, _opts, k) = k(unsupported(dst))
                def moveWith(_src, dst, _opts, k) = k(unsupported(dst))
                def delete(path, k)               = k(unsupported(path))
                def mkDir(path, k)                = k(unsupported(path))
                def mkDirs(path, k)               = k(unsupported(path))
                def mkTempDir(prefix, k)          = k(Err(IoError.IoError(IoError.ErrorKind.Unsupported, prefix)))
            };
            (result, Ref.get(files))
        }

    def v1Text(): String = "{\"version\": 1, \"hp\": 10}"

    def v1TextOther(): String = "{\"version\": 1, \"hp\": 99}"

    def futureText(): String = "{\"format\": \"demo\", \"version\": 9, \"data\": {}}"

    def futureTextWrittenBy(): String = "{\"format\": \"demo\", \"version\": 9, \"writtenBy\": \"1.6.0\", \"data\": {}}"

    /// demoFormat にゲームの版 1.4.0 を足した物。
    def demoFormatAt140(): SaveFormat.Format = demoFormat() |> SaveFormat.withGameVersion("1.4.0")

    def parsed(source: String): Json = DocJson.parse(source) |> Option.getWithDefault(JObject(Map.empty()))

    @Test
    def testDecodeReturnsDataOfCurrentVersionAsIs(): Unit \ Assert =
        Assert.assertEq(expected = Ok(lifeData(5)), SaveFormat.decode(SaveFormat.wrap(lifeData(5), demoFormat()), demoFormat()))

    @Test
    def testDecodeMigratesUnwrappedV1ToCurrentShape(): Unit \ Assert =
        Assert.assertEq(expected = Ok(lifeData(10)), SaveFormat.decodeText(v1Text(), demoFormat()))

    @Test
    def testDecodeRejectsFutureVersion(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(SaveFormat.decodeText(futureText(), demoFormat())))

    @Test
    def testDecodeRejectsOtherFormatName(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(SaveFormat.decode(SaveFormat.wrap(lifeData(5), SaveFormat.make("other", 3)), demoFormat())))

    @Test
    def testDecodeRejectsMissingMigration(): Unit \ Assert =
        let onlyV2 = SaveFormat.make("demo", 3) |> SaveFormat.withMigration(2, addItems) |> SaveFormat.withUnwrappedVersion(_ -> 1);
        Assert.assertTrue(Result.isErr(SaveFormat.decodeText(v1Text(), onlyV2)))

    @Test
    def testDecodeRejectsUnwrappedWithoutUnwrappedVersion(): Unit \ Assert =
        let noUnwrapped = SaveFormat.make("demo", 3) |> SaveFormat.withMigration(1, renameHpToLife) |> SaveFormat.withMigration(2, addItems);
        Assert.assertTrue(Result.isErr(SaveFormat.decodeText(v1Text(), noUnwrapped)))

    @Test
    def testVersionOfReadsUnwrappedVersion(): Unit \ Assert =
        Assert.assertEq(expected = Some(1), DocJson.parse(v1Text()) |> Option.flatMap(json -> SaveFormat.versionOf(json, demoFormat())))

    @Test
    def testLoadOfAbsentFileIsOkNone(): Unit \ Assert =
        Assert.assertEq(expected = Ok(None), fst(onDisk(Map.empty(), () -> SaveFormat.load("saves/a.json", demoFormat()))))

    @Test
    def testLoadMigratesFileToCurrentShape(): Unit \ Assert =
        Assert.assertEq(expected = Ok(Some(lifeData(10))), fst(onDisk(Map#{ "saves/a.json" => v1Text() }, () -> SaveFormat.load("saves/a.json", demoFormat()))))

    @Test
    def testSaveOverOlderVersionKeepsOldTextAsBackup(): Unit \ Assert =
        let (_, disk) = onDisk(Map#{ "saves/a.json" => v1Text() }, () -> SaveFormat.save("saves/a.json", lifeData(10), demoFormat()));
        Assert.assertEq(expected = Some(v1Text()), Map.get(SaveFormat.backupPath("saves/a.json", 1), disk))

    @Test
    def testSaveWritesCurrentVersionEnvelope(): Unit \ Assert =
        let (_, disk) = onDisk(Map#{ "saves/a.json" => v1Text() }, () -> SaveFormat.save("saves/a.json", lifeData(10), demoFormat()));
        Assert.assertEq(expected = Some(text(SaveFormat.wrap(lifeData(10), demoFormat()))), Map.get("saves/a.json", disk))

    @Test
    def testSaveDoesNotOverwriteExistingBackupOfSameVersion(): Unit \ Assert =
        let backup = SaveFormat.backupPath("saves/a.json", 1);
        let (_, disk) = onDisk(Map#{ "saves/a.json" => v1TextOther(), backup => v1Text() }, () -> SaveFormat.save("saves/a.json", lifeData(10), demoFormat()));
        Assert.assertEq(expected = Some(v1Text()), Map.get(backup, disk))

    @Test
    def testSaveOverCurrentVersionMakesNoBackup(): Unit \ Assert =
        let current = text(SaveFormat.wrap(lifeData(5), demoFormat()));
        let (_, disk) = onDisk(Map#{ "saves/a.json" => current }, () -> SaveFormat.save("saves/a.json", lifeData(6), demoFormat()));
        Assert.assertEq(expected = None, Map.get(SaveFormat.backupPath("saves/a.json", 3), disk))

    @Test
    def testSaveOverFutureVersionIsErr(): Unit \ Assert =
        let (result, _) = onDisk(Map#{ "saves/a.json" => futureText() }, () -> SaveFormat.save("saves/a.json", lifeData(6), demoFormat()));
        Assert.assertTrue(Result.isErr(result))

    @Test
    def testSaveOverFutureVersionKeepsFile(): Unit \ Assert =
        let (_, disk) = onDisk(Map#{ "saves/a.json" => futureText() }, () -> SaveFormat.save("saves/a.json", lifeData(6), demoFormat()));
        Assert.assertEq(expected = Some(futureText()), Map.get("saves/a.json", disk))

    @Test
    def testSaveOverBrokenTextWrites(): Unit \ Assert =
        let (_, disk) = onDisk(Map#{ "saves/a.json" => "not json" }, () -> SaveFormat.save("saves/a.json", lifeData(6), demoFormat()));
        Assert.assertEq(expected = Some(text(SaveFormat.wrap(lifeData(6), demoFormat()))), Map.get("saves/a.json", disk))

    @Test
    def testCheckSamplesReadsEveryReleasedVersion(): Unit \ {Assert, Fs.DirList, Fs.FileRead} =
        Assert.assertEq(expected = Nil, SaveFormat.checkSamples("test/assets/save-samples", readDemo, demoFormat()))

    @Test
    def testCheckSamplesNamesFailedSamples(): Unit \ {Assert, Fs.DirList, Fs.FileRead} =
        let failed = SaveFormat.checkSamples("test/assets/save-samples-broken", readDemo, demoFormat()) |> List.map(fst);
        Assert.assertEq(expected = List#{"future.json", "torn.json"}, failed)

    @Test
    def testCheckSamplesCountsMissingFolderAsFailure(): Unit \ {Assert, Fs.DirList, Fs.FileRead} =
        Assert.assertEq(expected = 1, SaveFormat.checkSamples("test/assets/no-such-samples", readDemo, demoFormat()) |> List.length)

    @Test
    def testWrapWithGameVersionLeavesWrittenBy(): Unit \ Assert =
        Assert.assertEq(expected = Some("1.4.0"), SaveFormat.writtenByOf(SaveFormat.wrap(lifeData(5), demoFormatAt140())))

    @Test
    def testWrapWithoutGameVersionLeavesNoWrittenBy(): Unit \ Assert =
        Assert.assertEq(expected = None, SaveFormat.writtenByOf(SaveFormat.wrap(lifeData(5), demoFormat())))

    @Test
    def testWrittenByOfEnvelopeWithoutWrittenByIsNone(): Unit \ Assert =
        Assert.assertEq(expected = None, SaveFormat.writtenByOf(parsed(futureText())))

    @Test
    def testWrittenByOfUnwrappedSaveIsNone(): Unit \ Assert =
        Assert.assertEq(expected = None, SaveFormat.writtenByOf(parsed("{\"version\": 1, \"writtenBy\": \"1.0.0\", \"hp\": 10}")))

    @Test
    def testWithGameVersionTrimsSpaces(): Unit \ Assert =
        Assert.assertEq(expected = Some("1.4.0"), SaveFormat.getGameVersion(demoFormat() |> SaveFormat.withGameVersion(" 1.4.0 ")))

    @Test
    def testDecodeReadsEnvelopeWithWrittenByWithoutGameVersion(): Unit \ Assert =
        Assert.assertEq(expected = Ok(lifeData(5)), SaveFormat.decode(SaveFormat.wrap(lifeData(5), demoFormatAt140()), demoFormat()))

    @Test
    def testDecodeOfFutureVersionNamesWrittenBy(): Unit \ Assert =
        Assert.assertEq(expected = Err("今より新しい版のセーブ（9 版・1.6.0 で書いた・このゲームは 3 版まで）"), SaveFormat.decodeText(futureTextWrittenBy(), demoFormat()))

    @Test
    def testSaveOverFutureVersionNamesWrittenBy(): Unit \ Assert =
        let (result, _) = onDisk(Map#{ "saves/a.json" => futureTextWrittenBy() }, () -> SaveFormat.save("saves/a.json", lifeData(6), demoFormat()));
        Assert.assertEq(expected = Err("saves/a.json は今より新しい版（9 版・1.6.0 で書いた）なので上書きしない"), result)

    @Test
    def testSaveWritesWrittenBy(): Unit \ Assert =
        let (_, disk) = onDisk(Map.empty(), () -> SaveFormat.save("saves/a.json", lifeData(6), demoFormatAt140()));
        Assert.assertEq(expected = Some("1.4.0"), Map.get("saves/a.json", disk) |> Option.flatMap(written -> SaveFormat.writtenByOf(parsed(written))))
}
