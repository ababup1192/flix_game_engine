// Package refactor は Flix のプロジェクトを名前の位置の索引（flixlint の --spans）で読み、
// 書き換えの前に「どこを替えるか」を数で出す道具（bin/fge refactor）。
//
//	refactor refs <Mod.name> [--callers]                     def・case・enum の宣言と参照
//	refactor match-sites <Enum|Enum.Case> [--catch-all]      match の位置・腕の数・`_` の腕
//	refactor field-sites --label x [--receiver T] [--outside Mod]   record の欄の直の読み書き
//
// 書き換える操作（expand-wildcard・remove-dead・field-to-accessor・remove-field・fix-construction）は Usage を見る。
//
// 索引は flixlint の shim が書く（コンパイラの AST から。名前解決も型もコンパイラの物）。
// 段は 2 つ: resolved（def・case・enum・match。速い）と typed（欄の読み書きと受け手の型。遅い）。
// 操作は要る段だけを作る。置き場は build/refactor/spans-<段>.tsv、鍵は src・test の .flix の中身・
// flix.toml・flix.jar・shim の版のハッシュで、同じなら作り直さない。作るのは bin/fge heavy の枠の中。
//
// ゲームの名前は持たない（受け手・欄・enum は引数で渡す）。設定は bin/lint-rules/refactor.json と
// ゲームの refactor.local.json（flixlint の場所・索引に入れるフォルダ・書き換えの後の確かめの口）。
//
// WhyNot: Go で Flix を読まないのは、型が無いと `w#scene` の `w` が World か決められないため。
package refactor

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// FormatVersion は読める索引の形の版（flixlint の shim/Spans.scala の FormatVersion と同じ数）。
const FormatVersion = 2

// Stage は索引の段。
type Stage string

const (
	Resolved Stage = "resolved" // 名前解決の直後（def・case・enum・match）
	Typed    Stage = "typed"    // 型検査の後（resolved の物に欄の読み書きと受け手を足す）
)

// Row は索引の 1 行（1 出現）。行と列は 1 から、EndCol は最後の字の次（UTF-16 の数え方）。
type Row struct {
	Kind    string `json:"kind"`
	File    string `json:"file"`
	Line    int    `json:"line"`
	Col     int    `json:"col"`
	EndLine int    `json:"endLine"`
	EndCol  int    `json:"endCol"`
	Sym     string `json:"sym"`
	Owner   string `json:"owner"`
	Extra   string `json:"extra,omitempty"`
}

// Attr は extra の `key=value` を引く（無ければ ""）。
func (r Row) Attr(key string) string {
	for _, f := range strings.Fields(r.Extra) {
		if k, v, ok := strings.Cut(f, "="); ok && k == key {
			return v
		}
	}
	return ""
}

// AttrInt は Attr を数で読む（読めなければ 0）。
func (r Row) AttrInt(key string) int {
	n, _ := strconv.Atoi(r.Attr(key))
	return n
}

// Where は `file:line:col`。
func (r Row) Where() string { return fmt.Sprintf("%s:%d:%d", r.File, r.Line, r.Col) }

// contains は r の範囲が o の始まりを含むか（同じファイルで）。
func (r Row) contains(o Row) bool {
	if r.File != o.File {
		return false
	}
	afterStart := o.Line > r.Line || (o.Line == r.Line && o.Col >= r.Col)
	beforeEnd := o.Line < r.EndLine || (o.Line == r.EndLine && o.Col < r.EndCol)
	return afterStart && beforeEnd
}

// ReadIndex は索引のファイルを読む。頭の行の版と段が違えば誤り（古い shim の索引を使わない）。
func ReadIndex(path string, want Stage) ([]Row, error) {
	rows, _, err := readIndex(path, want)
	return rows, err
}

// readIndex は ReadIndex に、頭の行の adds=（後から足した種類。flixlint 0.6.6 の use・type-use・alias-decl）を添える。
func readIndex(path string, want Stage) ([]Row, string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, "", err
	}
	defer f.Close()
	return parseIndexAdds(f, want)
}

func parseIndex(r io.Reader, want Stage) ([]Row, error) {
	rows, _, err := parseIndexAdds(r, want)
	return rows, err
}

func parseIndexAdds(r io.Reader, want Stage) ([]Row, string, error) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	var rows []Row
	adds := ""
	n := 0
	for sc.Scan() {
		n++
		line := sc.Text()
		if n == 1 {
			if err := checkHeader(line, want); err != nil {
				return nil, "", err
			}
			for _, f := range strings.Fields(line) {
				if v, ok := strings.CutPrefix(f, "adds="); ok {
					adds = v
				}
			}
			continue
		}
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		c := strings.Split(line, "\t")
		if len(c) != 9 {
			return nil, "", fmt.Errorf("索引の %d 行目の欄が %d 個（9 個のはず）", n, len(c))
		}
		var nums [4]int
		for i := range nums {
			v, err := strconv.Atoi(c[2+i])
			if err != nil {
				return nil, "", fmt.Errorf("索引の %d 行目の位置が数でない: %q", n, c[2+i])
			}
			nums[i] = v
		}
		rows = append(rows, Row{Kind: c[0], File: c[1], Line: nums[0], Col: nums[1], EndLine: nums[2], EndCol: nums[3], Sym: c[6], Owner: c[7], Extra: c[8]})
	}
	if err := sc.Err(); err != nil {
		return nil, "", err
	}
	if n == 0 {
		return nil, "", errors.New("索引が空（頭の行も無い）")
	}
	return rows, adds, nil
}

// checkHeader は `# flixlint-spans <版> stage=<段> ...` を確かめる。
func checkHeader(line string, want Stage) error {
	f := strings.Fields(line)
	if len(f) < 4 || f[0] != "#" || f[1] != "flixlint-spans" {
		return fmt.Errorf("索引の頭の行が flixlint-spans の形でない: %q", line)
	}
	if f[2] != strconv.Itoa(FormatVersion) {
		return fmt.Errorf("索引の形の版が %s（この道具が読めるのは %d）。flixlint %s 以上へ上げてください（bin/fge refactor index --rebuild で作り直す）", f[2], FormatVersion, MinFlixlint)
	}
	if f[3] != "stage="+string(want) {
		return fmt.Errorf("索引の段が %s（%s が要る）", strings.TrimPrefix(f[3], "stage="), want)
	}
	return nil
}

// Index は読んだ索引と、それをどう手に入れたか。
type Index struct {
	Stage   Stage
	Path    string
	Rows    []Row
	Adds    string  // 頭の行の adds=（後から足した種類を , で）。無ければ ""
	Cached  bool    // 前に作った物をそのまま使った
	Seconds float64 // 作るのに掛かった秒（使い回した時は前に作った時の秒）
	Key     string
}

// Runner は索引を作るコマンドを流す口（既定は heavy の枠の中。テストは直に流す）。stage は枠の長短を決める
// （typed は JVM に 4〜5 GB を取るので長い物の枠で、make test と並ばないようにする）。log が空でなければ
// コマンドの出力（標準出力とエラー）をそのファイルへ書き、画面には出さない（--verbose の時は "" で画面へ）。
type Runner func(stage Stage, desc, dir string, cmd []string, log string) int

// Builder は索引を手に入れる所の設定。
type Builder struct {
	Root     string
	Config   Config
	Flixlint string // 解決済みの bin/flixlint
	FlixJar  string // 解決済みの flix.jar（空なら flixlint に任せる）
	Run      Runner
	Log      io.Writer
	Rebuild  bool // 鍵が同じでも作り直す
	Verbose  bool // flixlint の出力を画面へ（既定は build/refactor/index-<段>.log へ書き、1 行だけ言う）
}

// IndexError は索引を作れなかった訳と、写してそのまま流せる次の手（無ければ ""。その時は NextWhy を next の 1 行に）。
type IndexError struct {
	Msg     string `json:"msg"`
	Next    string `json:"next,omitempty"`
	NextWhy string `json:"nextWhy,omitempty"`
	Compile bool   `json:"compile,omitempty"` // ソースが型検査（resolved は名前解決）を通らない
}

func (e *IndexError) Error() string { return e.Msg }

// Dir は索引の置き場（build/refactor）。
func (b Builder) Dir() string { return filepath.Join(b.Root, "build", "refactor") }

func (b Builder) indexPath(s Stage) string { return filepath.Join(b.Dir(), "spans-"+string(s)+".tsv") }
func (b Builder) keyPath(s Stage) string   { return filepath.Join(b.Dir(), "spans-"+string(s)+".key") }
func (b Builder) failPath(s Stage) string  { return filepath.Join(b.Dir(), "spans-"+string(s)+".fail") }

// Load は段 s の索引を返す。無いか鍵が違えば作る。
func (b Builder) Load(s Stage) (*Index, error) {
	key, err := b.Key(s)
	if err != nil {
		return nil, err
	}
	path := b.indexPath(s)
	if !b.Rebuild {
		if old, secs, ok := readKey(b.keyPath(s)); ok && old == key {
			if rows, adds, err := readIndex(path, s); err == nil {
				return &Index{Stage: s, Path: path, Rows: rows, Adds: adds, Cached: true, Seconds: secs, Key: key}, nil
			}
		}
		// 同じソースで前に型検査（名前解決）が落ちていれば、JVM を立てずに同じ答えを返す。
		if ie := readFail(b.failPath(s), key); ie != nil {
			return nil, ie
		}
	}
	os.Remove(b.failPath(s))
	if err := os.MkdirAll(b.Dir(), 0o755); err != nil {
		return nil, err
	}
	tmp := path + ".tmp"
	os.Remove(tmp)
	// --resident: 索引も lint（make lint）と同じ常駐の server（プロジェクトの根と flix.jar・shim の jar ごとに 1 つ）で作る。
	// 2 回目からは変わったファイルだけ組み直し、server が lint を流している間は並ぶ（flixlint が「前に N 本」を 1 行言う）。
	// WhyNot: 1 回きりの JVM にしない。typed の索引は JVM に 4〜5 GB を取り、lint の server と並べると 2 本になる。
	// build ディレクトリは走行ごとの引数なので、lint と分けたままでよい（同じ server を使う）。
	cmd := []string{b.Flixlint, "--resident", "--spans", tmp, "--stage", string(s), "--build-dir", filepath.Join(b.Dir(), "flixlint")}
	if b.FlixJar != "" {
		cmd = append(cmd, "--flix-jar", b.FlixJar)
	}
	if extra := strings.Fields(b.Config.JavaOpts); len(extra) > 0 {
		cmd = append(cmd, "--java-opts", b.Config.JavaOpts)
	}
	cmd = append(cmd, b.sources()...)
	log := filepath.Join(b.Dir(), "index-"+string(s)+".log")
	if b.Verbose {
		fmt.Fprintf(b.Log, "[refactor] 索引（%s）を作ります: %s\n", s, strings.Join(cmd, " "))
		log = ""
	} else {
		fmt.Fprintf(b.Log, "[refactor] 索引（%s）を作ります（ログ %s）\n", s, rel(log))
	}
	start := time.Now()
	code := b.Run(s, "flixlint --spans --stage "+string(s), b.Root, cmd, log)
	secs := time.Since(start).Seconds()
	if code != 0 {
		os.Remove(tmp)
		ie := b.indexError(s, code, log)
		if ie.Compile {
			writeFail(b.failPath(s), key, ie)
		} else if log != "" {
			fmt.Fprint(b.Log, tailOf(log, 12))
		}
		return nil, ie
	}
	rows, adds, err := readIndex(tmp, s)
	if err != nil {
		return nil, err
	}
	if err := os.Rename(tmp, path); err != nil {
		return nil, err
	}
	// 鍵は作った後に取り直す。初めての flixlint は依存を lib/ へ広げるので、前の鍵のままだと次の 1 回が作り直しになる。
	if after, err := b.Key(s); err == nil {
		key = after
	}
	if err := os.WriteFile(b.keyPath(s), []byte(fmt.Sprintf("%s %.1f\n", key, secs)), 0o644); err != nil {
		return nil, err
	}
	return &Index{Stage: s, Path: path, Rows: rows, Adds: adds, Seconds: secs, Key: key}, nil
}

// tailOf はログの終わりの n 行（索引を作れなかった時に、誤りの所だけ見せる）。
func tailOf(path string, n int) string {
	data, err := os.ReadFile(path)
	if err != nil || len(data) == 0 {
		return ""
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return "[refactor] " + rel(path) + " の終わり:\n" + strings.Join(lines, "\n") + "\n"
}

// indexError は flixlint の終了コードとログから、止めた訳と次の手を作る。
//
// 依存（lib/）が無い・欠けている時、flixlint は終了コード 4 で「flix check を 1 度」と言って止まる。その時は
// make check を next に出すだけで、道具が裏で make を流さない（依存を入れるのは flix の 1 つの源。
// 設計 refactor-tool-design §8.1・段 C で flixlint が自分で入れるようになるまで）。
//
// ソースがコンパイルできない時（終了コード 3。typed の段では型の誤りのある AST を歩いて例外の 4 になることもある）は、
// コンパイラの誤りの見出しで見分け、最初の誤りの 1 行と「先に道具、手の直しは後」の next だけを返す
// （例外の中身は出さない。全文はログ）。
func (b Builder) indexError(s Stage, code int, log string) *IndexError {
	text := logText(log)
	if code == 3 || (code == 4 && compileFailed(text)) {
		first := firstCompileError(text)
		if first == "" {
			first = "誤りの全文は make check"
		}
		ie := &IndexError{Compile: true,
			Msg:     fmt.Sprintf("索引（%s）を作れません: ソースがコンパイルできない・%s（最初の誤り: %s）", s, passWord(s, "を通らない"), first),
			NextWhy: fmt.Sprintf("%s の索引は%s状態で作る。先に道具、手の直しは後（手の直しを戻してから道具を流す。誤りの全文は make check）", s, passWord(s, "が通る")),
		}
		return ie
	}
	switch code {
	case 4:
		if strings.Contains(text, "flix check") {
			return &IndexError{
				Msg:     "索引を作れません: flixlint が依存（lib/）を読めない（終了コード 4。上の出力）",
				Next:    "make check",
				NextWhy: "flix check が lib/ に依存を入れる。通ったら同じコマンドをもう一度",
			}
		}
		return &IndexError{Msg: fmt.Sprintf("索引を作れません: flixlint の終了コード 4（呼び方か環境の誤り）。使っている flixlint（%s・%s）が --spans を知らない時もこれになります。"+
			"この道具には flixlint %s 以上が要ります（--spans と索引の形 2）。submodule なら git -C flixlint fetch して %s 以上へ上げ、"+
			"別の場所の物は --flixlint か refactor.local.json の flixlint で名指ししてください。上の flixlint の出力に flix check とあれば依存（lib/）が無いので make check を 1 度",
			b.Flixlint, flixlintVersion(b.Flixlint), MinFlixlint, MinFlixlint)}
	}
	return &IndexError{Msg: fmt.Sprintf("索引を作れません: flixlint の終了コード %d", code)}
}

// passWord は段ごとの「通る」物の言い方（typed は型検査・resolved は名前解決）。
func passWord(s Stage, verb string) string {
	if s == Typed {
		return "型検査" + verb
	}
	return "名前解決" + verb
}

var (
	ansiEscape   = regexp.MustCompile("\x1b\\[[0-9;]*[A-Za-z]")
	flixErrHead  = regexp.MustCompile(`^-- (.*?(?:Error|error))(?: \[\w+\])? -{2,} (\S+)\s*$`)
	flixErrLine  = regexp.MustCompile(`^\s*(\d+) \|`)
	noTypedAST   = "no typed AST"
	walkerFailed = "the fact walker failed"
)

// compileFailed はログにコンパイラの誤りの見出し（-- Type Error --- src/A.flix）か、型つきの AST が無いという行があるか。
func compileFailed(text string) bool {
	if strings.Contains(text, noTypedAST) {
		return true
	}
	return firstCompileError(text) != ""
}

// firstCompileError は最初のコンパイラの誤りを「file:line 種類: 要約」の 1 行にする（見出しが無ければ ""）。
func firstCompileError(text string) string {
	lines := strings.Split(ansiEscape.ReplaceAllString(text, ""), "\n")
	for i, l := range lines {
		m := flixErrHead.FindStringSubmatch(strings.TrimRight(l, "\r"))
		if m == nil {
			continue
		}
		where, summary := m[2], ""
		for _, n := range lines[i+1:] {
			n = strings.TrimSpace(n)
			if strings.HasPrefix(n, "-- ") || strings.Contains(n, walkerFailed) {
				break
			}
			if summary == "" && strings.HasPrefix(n, ">> ") {
				summary = strings.TrimPrefix(n, ">> ")
			}
			if ln := flixErrLine.FindStringSubmatch(n); ln != nil {
				where += ":" + ln[1]
				break
			}
		}
		s := where + " " + m[1]
		if summary != "" {
			s += ": " + summary
		}
		if r := []rune(s); len(r) > 200 {
			s = string(r[:200]) + "…"
		}
		return s
	}
	return ""
}

// writeFail は型検査（名前解決）が落ちた時の答えを鍵と一緒に控える（同じソースで呼ばれたら JVM を立てない）。
func writeFail(path, key string, ie *IndexError) {
	data, err := json.Marshal(ie)
	if err != nil {
		return
	}
	os.WriteFile(path, []byte(key+"\n"+string(data)+"\n"), 0o644)
}

// readFail は鍵が同じ時だけ、控えた答えを返す。
func readFail(path, key string) *IndexError {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	head, body, ok := strings.Cut(string(data), "\n")
	if !ok || head != key {
		return nil
	}
	var ie IndexError
	if json.Unmarshal([]byte(body), &ie) != nil || !ie.Compile {
		return nil
	}
	ie.Msg += "（前の回と同じソースなので作り直していない）"
	return &ie
}

// logText はログの中身（-v で画面へ流した時は "" で、読めない）。
func logText(log string) string {
	if log == "" {
		return ""
	}
	data, _ := os.ReadFile(log)
	return string(data)
}

func readKey(path string) (string, float64, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", 0, false
	}
	f := strings.Fields(string(data))
	if len(f) == 0 {
		return "", 0, false
	}
	secs := 0.0
	if len(f) > 1 {
		secs, _ = strconv.ParseFloat(f[1], 64)
	}
	return f[0], secs, true
}

// sources は索引に入れるフォルダのうち、在る物（根からの相対）。
func (b Builder) sources() []string {
	var out []string
	for _, s := range b.Config.Sources {
		if info, err := os.Stat(filepath.Join(b.Root, s)); err == nil && info.IsDir() {
			out = append(out, s)
		}
	}
	return out
}

// Key は索引の鍵: 段・形の版・sources の .flix（パスと中身）・flix.toml・flix.jar（パス・大きさ・時刻）・
// flixlint の shim と前面（中身）のハッシュ。
//
// WhyNot: flix.jar は中身を読まない。100 MB 近くを毎回読むと、索引を引くだけで秒が掛かる
// （flixlint が engine.jar の鍵に使うのと同じ見分け方）。
func (b Builder) Key(s Stage) (string, error) {
	h := sha256.New()
	fmt.Fprintf(h, "refactor-index %d %s\n", FormatVersion, s)
	files, err := flixFiles(b.Root, b.sources())
	if err != nil {
		return "", err
	}
	if len(files) == 0 {
		return "", fmt.Errorf("索引に入れる .flix がありません（%s の %s）", b.Root, strings.Join(b.Config.Sources, "・"))
	}
	for _, rel := range files {
		data, err := os.ReadFile(filepath.Join(b.Root, rel))
		if err != nil {
			return "", err
		}
		fmt.Fprintf(h, "file %s %d\n", filepath.ToSlash(rel), len(data))
		h.Write(data)
	}
	// 依存の fpkg・jar（lib/ の下）。中身は読まず、パス・大きさ・時刻で見分ける（engine の版を上げると替わる）。
	for _, dep := range libFiles(b.Root) {
		fmt.Fprintf(h, "lib %s\n", dep)
	}
	if data, err := os.ReadFile(filepath.Join(b.Root, "flix.toml")); err == nil {
		fmt.Fprintf(h, "flix.toml %d\n", len(data))
		h.Write(data)
	}
	if b.FlixJar != "" {
		if info, err := os.Stat(b.FlixJar); err == nil {
			fmt.Fprintf(h, "flix.jar %s %d %d\n", b.FlixJar, info.Size(), info.ModTime().Unix())
		}
	}
	for _, p := range shimFiles(b.Flixlint) {
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		fmt.Fprintf(h, "shim %s %d\n", filepath.Base(p), len(data))
		h.Write(data)
	}
	return hex.EncodeToString(h.Sum(nil))[:24], nil
}

// shimFiles は flixlint の版を表すファイル: 前面の bin/flixlint と shim/*.scala と flix.toml（version）。
func shimFiles(flixlint string) []string {
	out := []string{flixlint}
	real, err := filepath.EvalSymlinks(flixlint)
	if err != nil {
		return out
	}
	home := filepath.Dir(filepath.Dir(real))
	scala, _ := filepath.Glob(filepath.Join(home, "shim", "*.scala"))
	sort.Strings(scala)
	return append(append(out, scala...), filepath.Join(home, "flix.toml"))
}

// flixFiles は dirs の下の .flix を根からの相対で返す（名前の順）。symlink の先も辿る（engine の src は symlink 集）。
func flixFiles(root string, dirs []string) ([]string, error) {
	var out []string
	seen := map[string]bool{}
	var walk func(dir string) error
	walk = func(dir string) error {
		real, err := filepath.EvalSymlinks(filepath.Join(root, dir))
		if err != nil {
			return err
		}
		if seen[real] {
			return nil
		}
		seen[real] = true
		entries, err := os.ReadDir(filepath.Join(root, dir))
		if err != nil {
			return err
		}
		for _, e := range entries {
			rel := filepath.Join(dir, e.Name())
			mode := e.Type()
			if mode&fs.ModeSymlink != 0 {
				info, err := os.Stat(filepath.Join(root, rel))
				if err != nil {
					continue // 先の無い symlink はコンパイラも読まない
				}
				mode = info.Mode().Type()
			}
			switch {
			case mode.IsDir():
				if err := walk(rel); err != nil {
					return err
				}
			case mode.IsRegular() && strings.HasSuffix(e.Name(), ".flix"):
				out = append(out, rel)
			}
		}
		return nil
	}
	for _, d := range dirs {
		if err := walk(d); err != nil {
			return nil, err
		}
	}
	sort.Strings(out)
	return out, nil
}

// LookPath は PATH の上のコマンドを探す（見つからなければ ""）。
func LookPath(name string) string {
	p, err := exec.LookPath(name)
	if err != nil {
		return ""
	}
	return p
}

// MinFlixlint は読める索引（--spans・形の版 FormatVersion）を書き、--resident を知る一番古い flixlint の版。
// 0.6.5 の常駐は build ディレクトリごとに別の JVM。lint と 1 つの JVM を共有するのは 0.6.6 から（protocol 2・鍵は根 × identity）。
const MinFlixlint = "0.6.5"

// MinFlixlintUsages は usages の型の注記と use（resolved の段の adds=use,type-use,alias-decl）を書く一番古い flixlint の版。
// それより古い索引でも usages は動き、その 2 つを数えない。
const MinFlixlintUsages = "0.6.6"

// flixlintVersion は `flixlint --version` の答え（読めなければ「版は読めない」）。
func flixlintVersion(flixlint string) string {
	b, err := exec.Command(flixlint, "--version").Output()
	if err != nil {
		return "版は読めない"
	}
	return strings.TrimSpace(string(b))
}

// libFiles は lib/ の下の依存（github の fpkg・external と cache の jar）を「相対パス 大きさ 時刻」で並べる。
func libFiles(root string) []string {
	var out []string
	lib := filepath.Join(root, "lib")
	filepath.WalkDir(lib, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !(strings.HasSuffix(p, ".fpkg") || strings.HasSuffix(p, ".jar") || strings.HasSuffix(p, ".toml")) {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(lib, p)
		out = append(out, fmt.Sprintf("%s %d %d", filepath.ToSlash(rel), info.Size(), info.ModTime().Unix()))
		return nil
	})
	sort.Strings(out)
	return out
}
