// ContentCache — 作るのに時間がかかり、入力がファイルで決まる値を、呼び出しをまたいで取っておく。
//
// build がファイルに対して行った問い（Fs.FileRead・Fs.FileTest・Fs.DirList）を答えごと記録し、
// 次の呼び出しでは同じ問いを同じ順にもう一度行う。答えが全部同じなら前の値を返し、違えば作り直す。
// キャッシュのキーは中身の SHA-256 と答えだけで、更新時刻は見ない。
pub mod ContentCache {
    use Concurrent.ReentrantLock
    use Concurrent.ReentrantLock.ReentrantLock
    import java.lang.Throwable

    /// params の種類をいくつまで持つか。
    def capacity(): Int32 = 4

    /// build がファイルに対して行った 1 回の問い。
    enum Query with Eq {
        case Read(String)
        case ReadLines(String)
        case ReadBytes(String)
        case Exists(String)
        case IsDirectory(String)
        case IsRegularFile(String)
        case IsSymbolicLink(String)
        case ListDir(String)
    }

    /// 問いへの答え。
    enum Answer with Eq {
        /// 読めた中身の SHA-256（16 進）
        case Content(String)
        /// FileTest の答え
        case Flag(Bool)
        /// DirList の並び（順のまま）
        case Names(List[String])
        /// 失敗の種類（無いファイルは NotFound）
        case Failed(IoError.ErrorKind)
        /// もう一度問えなかった（記録には現れないので、必ず作り直しになる）
        case Unasked
    }

    /// 問いと答えの組。
    type alias Step = (Query, Answer)

    /// 取っておく 1 件。
    type alias Entry[a] = {
        params = String,       // 呼ぶ側が渡した、ファイル以外の入力
        extra = List[Step],    // extraFiles の答え（呼んだ時の並び）
        steps = List[Step],    // build が行った問いと答え（行った順）
        value = a
    }

    enum CacheData[a] {
        case CacheData({
            entries = Ref[List[Entry[a]], Static],                  // 新しく使った順。長さは capacity() まで
            tableLock = ReentrantLock,                              // entries と buildLocks を触る間だけ持つ
            buildLocks = Ref[Map[String, ReentrantLock], Static]    // params ごとの、build の間だけ持つロック
        })
    }

    /// キャッシュの置き場。外からは fresh で作り、loadOrBuild に渡すだけ。
    pub type alias Cache[a] = CacheData[a]

    /// 空の置き場を作る。
    pub def fresh(): Cache[a] \ IO =
        CacheData.CacheData({
            entries = Ref.fresh(Static, Nil),
            tableLock = ReentrantLock.newLock(false),
            buildLocks = Ref.fresh(Static, Map.empty())
        })

    /// params ごとに、前回 build がファイルから受け取った物と今のディスクが同じなら前の値を返し、違えば build で作り直す。
    /// build の中の Fs.FileRead は記録するハンドラで受け、外の Fs.FileRead へ投げ直しながら記録する。
    /// Java から直に読む物（TTF・ImageIO）は extraFiles で明示する（外の Fs.FileRead.readBytes で中身を見る）。
    // WhyNot: Fs.FileTest と Fs.DirList をここで受けない — どちらも Fs.FileRead とは別の effect で、
    // build がそれを使うと ef を通って記録されないまま外へ抜ける。使う build は loadOrBuildWithDirs を呼ぶ。
    pub def loadOrBuild(cache: Cache[a], params: String, extraFiles: List[String],
                        build: Unit -> a \ ef): a \ (ef - Fs.FileRead) + Fs.FileRead + IO =
        let extra = answerExtraFiles(extraFiles);
        lookupOrBuild(cache, params, extra, replayRead, () -> recordRead(build))

    /// loadOrBuild に加えて、build の中の Fs.FileTest（exists 系）と Fs.DirList（一覧）も記録する。
    /// ファイルが足された・一覧の並びが変わった、も作り直しの理由になる。
    pub def loadOrBuildWithDirs(cache: Cache[a], params: String, extraFiles: List[String],
                                build: Unit -> a \ ef):
                                a \ (ef - Fs.FileRead - Fs.FileTest - Fs.DirList) + Fs.FileRead + Fs.FileTest + Fs.DirList + IO =
        let extra = answerExtraFiles(extraFiles);
        lookupOrBuild(cache, params, extra, replayAll, () -> recordAll(build))

    // ── 引くか作るか ──

    // WhyNot: 1 本のロックで build まで包まない — 会話の列と仕事の列が別の params を引くとき、
    // 片方の build（kit で約 1 s）の間もう片方が待たされる。同じ params だけを待たせる。
    def lookupOrBuild(cache: Cache[a], params: String, extra: List[Step],
                      replay: Query -> Answer \ ef1,
                      recorded: Unit -> (a, List[Step]) \ ef2): a \ ef1 + ef2 + IO =
        let CacheData.CacheData(c) = cache;
        let buildLock = holding(c#tableLock, () -> buildLockOf(params, c#buildLocks));
        holding(buildLock, () -> {
            let found = holding(c#tableLock, () -> findEntry(params, Ref.get(c#entries)));
            match reusable(replay, extra, found) {
                case Some(v) =>
                    holding(c#tableLock, () -> Ref.put(touch(params, Ref.get(c#entries)), c#entries));
                    v
                case None =>
                    let (v, steps) = recorded();
                    let entry = { params = params, extra = extra, steps = steps, value = v };
                    holding(c#tableLock, () -> Ref.put(remember(capacity(), entry, Ref.get(c#entries)), c#entries));
                    v
            }
        })

    /// lock を持っている間だけ f を走らせる。f が例外で抜けても lock は外してから投げ直す。
    def holding(lock: ReentrantLock, f: Unit -> b \ ef): b \ ef + IO =
        ReentrantLock.lock(lock);
        let result = try { f() } catch {
            case e: Throwable =>
                discard ReentrantLock.unlock(lock);
                throw e
        };
        discard ReentrantLock.unlock(lock);
        result

    // WhyNot: 追い出した params のロックを表から消さない — 消した直後に別のスレッドがまだそのロックで待っていると、
    // 次の呼び出しが新しいロックを作り、同じ params を 2 本が同時に作る。ロックは params の種類の数しか増えない。
    def buildLockOf(params: String, locks: Ref[Map[String, ReentrantLock], Static]): ReentrantLock \ IO =
        match Map.get(params, Ref.get(locks)) {
            case Some(lock) => lock
            case None =>
                let lock = ReentrantLock.newLock(false);
                Ref.put(Map.insert(params, lock, Ref.get(locks)), locks);
                lock
        }

    // ── 比べ方と捨てる順（純粋） ──

    /// 前の 1 件が今も使えるならその値。extraFiles の答えが同じで、記録した問いの答えも全部同じ時だけ。
    def reusable(replay: Query -> Answer \ ef, extra: List[Step], found: Option[Entry[a]]): Option[a] \ ef =
        match found {
            case Some(entry) =>
                if (entry#extra != extra) None
                else if (isUnchanged(replay, entry#steps)) Some(entry#value)
                else None
            case None => None
        }

    /// 記録した問いを同じ順にもう一度行い、答えが全部同じか。最初に違った所で止める。
    def isUnchanged(replay: Query -> Answer \ ef, steps: List[Step]): Bool \ ef = match steps {
        case Nil => true
        case (question, answer) :: rest =>
            if (replay(question) == answer) isUnchanged(replay, rest) else false
    }

    def findEntry(params: String, entries: List[Entry[a]]): Option[Entry[a]] =
        List.find(entry -> entry#params == params, entries)

    /// params の 1 件を先頭へ動かす（使った順を新しくする）。
    def touch(params: String, entries: List[Entry[a]]): List[Entry[a]] =
        let (hit, rest) = List.partition(entry -> entry#params == params, entries);
        hit ::: rest

    /// entry を先頭に入れ、同じ params の前の 1 件を除き、limit を超えた古い物を捨てる。
    def remember(limit: Int32, entry: Entry[a], entries: List[Entry[a]]): List[Entry[a]] =
        List.take(limit, entry :: List.filter(old -> old#params != entry#params, entries))

    // ── 答えの形 ──

    def sha256Hex(bytes: Vector[Int8]): String =
        Util.Codec.encodeHex(Util.Checksum.sha256(bytes))

    def answerOfText(result: Result[IoError, String]): Answer = match result {
        case Ok(text) => Answer.Content(sha256Hex(String.toBytes(text)))
        case Err(IoError.IoError(kind, _)) => Answer.Failed(kind)
    }

    // WhyNot: 行を "\n" でつないだだけをキーにしない — Nil と "" の 1 行が同じ字になる。行の数を頭に足す。
    def answerOfLines(result: Result[IoError, List[String]]): Answer = match result {
        case Ok(lines) =>
            let text = "${List.length(lines)}\n${String.intercalate("\n", lines)}";
            Answer.Content(sha256Hex(String.toBytes(text)))
        case Err(IoError.IoError(kind, _)) => Answer.Failed(kind)
    }

    def answerOfBytes(result: Result[IoError, Vector[Int8]]): Answer = match result {
        case Ok(bytes) => Answer.Content(sha256Hex(bytes))
        case Err(IoError.IoError(kind, _)) => Answer.Failed(kind)
    }

    def answerOfFlag(result: Result[IoError, Bool]): Answer = match result {
        case Ok(flag) => Answer.Flag(flag)
        case Err(IoError.IoError(kind, _)) => Answer.Failed(kind)
    }

    def answerOfNames(result: Result[IoError, List[String]]): Answer = match result {
        case Ok(names) => Answer.Names(names)
        case Err(IoError.IoError(kind, _)) => Answer.Failed(kind)
    }

    def answerExtraFiles(paths: List[String]): List[Step] \ Fs.FileRead =
        List.map(path -> (Query.ReadBytes(path), answerOfBytes(Fs.FileRead.readBytes(path))), paths)

    // ── もう一度問う ──

    def replayRead(question: Query): Answer \ Fs.FileRead = match question {
        case Query.Read(path)      => answerOfText(Fs.FileRead.read(path))
        case Query.ReadLines(path) => answerOfLines(Fs.FileRead.readLines(path))
        case Query.ReadBytes(path) => answerOfBytes(Fs.FileRead.readBytes(path))
        // WhyNot: bug! で止めない — 同じ置き場と params を loadOrBuildWithDirs と分け合うと、ここへ FileTest の記録が来る。
        case _                     => Answer.Unasked
    }

    def replayAll(question: Query): Answer \ Fs.FileRead + Fs.FileTest + Fs.DirList = match question {
        case Query.Read(path)           => answerOfText(Fs.FileRead.read(path))
        case Query.ReadLines(path)      => answerOfLines(Fs.FileRead.readLines(path))
        case Query.ReadBytes(path)      => answerOfBytes(Fs.FileRead.readBytes(path))
        case Query.Exists(path)         => answerOfFlag(Fs.FileTest.exists(path))
        case Query.IsDirectory(path)    => answerOfFlag(Fs.FileTest.isDirectory(path))
        case Query.IsRegularFile(path)  => answerOfFlag(Fs.FileTest.isRegularFile(path))
        case Query.IsSymbolicLink(path) => answerOfFlag(Fs.FileTest.isSymbolicLink(path))
        case Query.ListDir(path)        => answerOfNames(Fs.DirList.list(path))
    }

    // ── 記録しながら作る ──

    // WhyNot: 読んだパスだけ記録して後から読み直さない — build の最中に保存されると、
    // build が使った中身とキーの中身がずれ、古い値を新しいキーで返す。受け取った値そのものからキーを取る。
    def recordRead(build: Unit -> a \ ef): (a, List[Step]) \ (ef - Fs.FileRead) + Fs.FileRead = region rc {
        let log = Ref.fresh(rc, Nil);
        let note = (question, answer) -> Ref.put((question, answer) :: Ref.get(log), log);
        let value = run { build() } with handler Fs.FileRead {
            def read(path, k) = {
                let result = Fs.FileRead.read(path);
                note(Query.Read(path), answerOfText(result));
                k(result)
            }
            def readLines(path, k) = {
                let result = Fs.FileRead.readLines(path);
                note(Query.ReadLines(path), answerOfLines(result));
                k(result)
            }
            def readBytes(path, k) = {
                let result = Fs.FileRead.readBytes(path);
                note(Query.ReadBytes(path), answerOfBytes(result));
                k(result)
            }
        };
        (value, List.reverse(Ref.get(log)))
    }

    def recordAll(build: Unit -> a \ ef):
                  (a, List[Step]) \ (ef - Fs.FileRead - Fs.FileTest - Fs.DirList) + Fs.FileRead + Fs.FileTest + Fs.DirList = region rc {
        let log = Ref.fresh(rc, Nil);
        let note = (question, answer) -> Ref.put((question, answer) :: Ref.get(log), log);
        let value = run { build() } with handler Fs.FileRead {
            def read(path, k) = {
                let result = Fs.FileRead.read(path);
                note(Query.Read(path), answerOfText(result));
                k(result)
            }
            def readLines(path, k) = {
                let result = Fs.FileRead.readLines(path);
                note(Query.ReadLines(path), answerOfLines(result));
                k(result)
            }
            def readBytes(path, k) = {
                let result = Fs.FileRead.readBytes(path);
                note(Query.ReadBytes(path), answerOfBytes(result));
                k(result)
            }
        } with handler Fs.FileTest {
            def exists(path, k) = {
                let result = Fs.FileTest.exists(path);
                note(Query.Exists(path), answerOfFlag(result));
                k(result)
            }
            def isDirectory(path, k) = {
                let result = Fs.FileTest.isDirectory(path);
                note(Query.IsDirectory(path), answerOfFlag(result));
                k(result)
            }
            def isRegularFile(path, k) = {
                let result = Fs.FileTest.isRegularFile(path);
                note(Query.IsRegularFile(path), answerOfFlag(result));
                k(result)
            }
            def isSymbolicLink(path, k) = {
                let result = Fs.FileTest.isSymbolicLink(path);
                note(Query.IsSymbolicLink(path), answerOfFlag(result));
                k(result)
            }
        } with handler Fs.DirList {
            def list(path, k) = {
                let result = Fs.DirList.list(path);
                note(Query.ListDir(path), answerOfNames(result));
                k(result)
            }
        };
        (value, List.reverse(Ref.get(log)))
    }
}
