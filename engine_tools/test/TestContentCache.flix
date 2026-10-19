// ContentCache.loadOrBuild のキャッシュと作り直しの条件を、メモリの上のファイル表で確かめる。
mod TestContentCache {

    /// テストのディスク: (パス, 中身) の並び。並びの順がそのまま一覧の順になる。
    type alias Disk = List[(String, String)]

    /// disk の上で f を流す。Fs.FileRead・Fs.FileTest・Fs.DirList を disk から答える。
    def withDisk(disk: Ref[Disk, r], f: Unit -> a \ ef): a \ (ef - Fs.FileRead - Fs.FileTest - Fs.DirList) + r =
        let lookup = path -> List.find(entry -> fst(entry) == path, Ref.get(disk)) |> Option.map(snd);
        let missing = path -> IoError.IoError(IoError.ErrorKind.NotFound, path);
        run { f() } with handler Fs.FileRead {
            def read(path, k)      = k(Option.toOk(missing(path), lookup(path)))
            def readLines(path, k) = k(Option.toOk(missing(path), lookup(path)) |> Result.map(String.lines))
            def readBytes(path, k) = k(Option.toOk(missing(path), lookup(path)) |> Result.map(String.toBytes))
        } with handler Fs.FileTest {
            def exists(path, k)         = k(Ok(Option.nonEmpty(lookup(path))))
            def isDirectory(_path, k)   = k(Ok(false))
            def isRegularFile(path, k)  = k(Ok(Option.nonEmpty(lookup(path))))
            def isSymbolicLink(_path, k) = k(Ok(false))
        } with handler Fs.DirList {
            def list(dir, k) =
                k(Ok(Ref.get(disk) |> List.map(fst) |> List.filter(path -> String.startsWith(prefix = "${dir}/", path))))
        }

    /// build を数える: 呼ばれるたびに builds を 1 足し、path の中身を読んで返す。
    def countingRead(builds: Ref[Int32, r], path: String): Unit -> String \ r + Fs.FileRead = () -> {
        Ref.put(Ref.get(builds) + 1, builds);
        Fs.FileRead.read(path) |> Result.getWithDefault("")
    }

    // ── 同じなら作らない ──

    /// 同じ params・同じ中身で 2 回引くと、build は 1 回だけ走る。
    @Test
    def testSameInputsBuildOnce(): Unit \ {Assert, IO} = region rc {
        let disk = Ref.fresh(rc, ("doc.json", "a") :: Nil);
        let builds = Ref.fresh(rc, 0);
        let cache = ContentCache.fresh();
        discard withDisk(disk, () -> ContentCache.loadOrBuild(cache, "day", Nil, countingRead(builds, "doc.json")));
        discard withDisk(disk, () -> ContentCache.loadOrBuild(cache, "day", Nil, countingRead(builds, "doc.json")));
        Assert.assertEq(expected = 1, Ref.get(builds))
    }

    // ── ファイルが変わったら作り直す ──

    /// 読んだファイルの中身が変わると、作り直した新しい中身が返る。
    @Test
    def testChangedContentRebuilds(): Unit \ {Assert, IO} = region rc {
        let disk = Ref.fresh(rc, ("doc.json", "a") :: Nil);
        let builds = Ref.fresh(rc, 0);
        let cache = ContentCache.fresh();
        discard withDisk(disk, () -> ContentCache.loadOrBuild(cache, "day", Nil, countingRead(builds, "doc.json")));
        Ref.put(("doc.json", "b") :: Nil, disk);
        let second = withDisk(disk, () -> ContentCache.loadOrBuild(cache, "day", Nil, countingRead(builds, "doc.json")));
        Assert.assertEq(expected = ("b", 2), (second, Ref.get(builds)))
    }

    /// 前は読めなかった（無かった）ファイルが現れると作り直す。
    @Test
    def testMissingFileAppearingRebuilds(): Unit \ {Assert, IO} = region rc {
        let disk = Ref.fresh(rc, Nil);
        let builds = Ref.fresh(rc, 0);
        let cache = ContentCache.fresh();
        discard withDisk(disk, () -> ContentCache.loadOrBuild(cache, "day", Nil, countingRead(builds, "extra.json")));
        Ref.put(("extra.json", "x") :: Nil, disk);
        let second = withDisk(disk, () -> ContentCache.loadOrBuild(cache, "day", Nil, countingRead(builds, "extra.json")));
        Assert.assertEq(expected = ("x", 2), (second, Ref.get(builds)))
    }

    /// exists の答えが false から true に変わる（ファイルが足された）と作り直す。
    @Test
    def testExistsAnswerChangeRebuilds(): Unit \ {Assert, IO} = region rc {
        let disk = Ref.fresh(rc, Nil);
        let builds = Ref.fresh(rc, 0);
        let cache = ContentCache.fresh();
        let build = () -> {
            Ref.put(Ref.get(builds) + 1, builds);
            Fs.FileTest.exists("night.json") |> Result.getWithDefault(false)
        };
        discard withDisk(disk, () -> ContentCache.loadOrBuildWithDirs(cache, "day", Nil, build));
        Ref.put(("night.json", "{}") :: Nil, disk);
        let second = withDisk(disk, () -> ContentCache.loadOrBuildWithDirs(cache, "day", Nil, build));
        Assert.assertEq(expected = (true, 2), (second, Ref.get(builds)))
    }

    /// 一覧の中身が同じでも並びが変わると作り直す。
    @Test
    def testListingOrderChangeRebuilds(): Unit \ {Assert, IO} = region rc {
        let disk = Ref.fresh(rc, ("sprites/a.json", "") :: ("sprites/b.json", "") :: Nil);
        let builds = Ref.fresh(rc, 0);
        let cache = ContentCache.fresh();
        let build = () -> {
            Ref.put(Ref.get(builds) + 1, builds);
            Fs.DirList.list("sprites") |> Result.getWithDefault(Nil)
        };
        discard withDisk(disk, () -> ContentCache.loadOrBuildWithDirs(cache, "day", Nil, build));
        Ref.put(("sprites/b.json", "") :: ("sprites/a.json", "") :: Nil, disk);
        let second = withDisk(disk, () -> ContentCache.loadOrBuildWithDirs(cache, "day", Nil, build));
        Assert.assertEq(expected = ("sprites/b.json" :: "sprites/a.json" :: Nil, 2), (second, Ref.get(builds)))
    }

    /// build が読まない extraFiles の中身が変わると作り直す。
    @Test
    def testChangedExtraFileRebuilds(): Unit \ {Assert, IO} = region rc {
        let disk = Ref.fresh(rc, ("doc.json", "a") :: ("font.ttf", "v1") :: Nil);
        let builds = Ref.fresh(rc, 0);
        let cache = ContentCache.fresh();
        discard withDisk(disk, () -> ContentCache.loadOrBuild(cache, "day", "font.ttf" :: Nil, countingRead(builds, "doc.json")));
        Ref.put(("doc.json", "a") :: ("font.ttf", "v2") :: Nil, disk);
        discard withDisk(disk, () -> ContentCache.loadOrBuild(cache, "day", "font.ttf" :: Nil, countingRead(builds, "doc.json")));
        Assert.assertEq(expected = 2, Ref.get(builds))
    }

    // ── params ごとに持つ ──

    /// day・night・day と交互に引いても、params ごとに別に持つので build は 2 回。
    @Test
    def testDifferentParamsAreKeptSeparately(): Unit \ {Assert, IO} = region rc {
        let disk = Ref.fresh(rc, ("doc.json", "a") :: Nil);
        let builds = Ref.fresh(rc, 0);
        let cache = ContentCache.fresh();
        discard withDisk(disk, () -> ContentCache.loadOrBuild(cache, "day", Nil, countingRead(builds, "doc.json")));
        discard withDisk(disk, () -> ContentCache.loadOrBuild(cache, "night", Nil, countingRead(builds, "doc.json")));
        discard withDisk(disk, () -> ContentCache.loadOrBuild(cache, "day", Nil, countingRead(builds, "doc.json")));
        Assert.assertEq(expected = 2, Ref.get(builds))
    }

    /// 4 つまで持つので、p1〜p5 を引くと一番古い p1 が消えて作り直しになり、p5 は残る（5 + p1 の 1 = 6 回）。
    @Test
    def testFifthParamsEvictsOldest(): Unit \ {Assert, IO} = region rc {
        let disk = Ref.fresh(rc, ("doc.json", "a") :: Nil);
        let builds = Ref.fresh(rc, 0);
        let cache = ContentCache.fresh();
        discard withDisk(disk, () -> ContentCache.loadOrBuild(cache, "p1", Nil, countingRead(builds, "doc.json")));
        discard withDisk(disk, () -> ContentCache.loadOrBuild(cache, "p2", Nil, countingRead(builds, "doc.json")));
        discard withDisk(disk, () -> ContentCache.loadOrBuild(cache, "p3", Nil, countingRead(builds, "doc.json")));
        discard withDisk(disk, () -> ContentCache.loadOrBuild(cache, "p4", Nil, countingRead(builds, "doc.json")));
        discard withDisk(disk, () -> ContentCache.loadOrBuild(cache, "p5", Nil, countingRead(builds, "doc.json")));
        discard withDisk(disk, () -> ContentCache.loadOrBuild(cache, "p5", Nil, countingRead(builds, "doc.json")));
        discard withDisk(disk, () -> ContentCache.loadOrBuild(cache, "p1", Nil, countingRead(builds, "doc.json")));
        Assert.assertEq(expected = 6, Ref.get(builds))
    }
}
