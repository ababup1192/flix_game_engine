// Package refactor は Flix のプロジェクトを名前の位置の索引（flixlint の --spans）で読み、
// 書き換えの前に「どこを替えるか」を数で出す道具（bin/fge refactor）。
//
//	refactor refs <Mod.name> [--callers]                     def・case・enum の宣言と参照
//	refactor match-sites <Enum|Enum.Case> [--catch-all]      match の位置・腕の数・`_` の腕
//	refactor field-sites --label x [--receiver T] [--outside Mod]   record の欄の直の読み書き
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
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
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
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return parseIndex(f, want)
}

func parseIndex(r io.Reader, want Stage) ([]Row, error) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	var rows []Row
	n := 0
	for sc.Scan() {
		n++
		line := sc.Text()
		if n == 1 {
			if err := checkHeader(line, want); err != nil {
				return nil, err
			}
			continue
		}
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		c := strings.Split(line, "\t")
		if len(c) != 9 {
			return nil, fmt.Errorf("索引の %d 行目の欄が %d 個（9 個のはず）", n, len(c))
		}
		var nums [4]int
		for i := range nums {
			v, err := strconv.Atoi(c[2+i])
			if err != nil {
				return nil, fmt.Errorf("索引の %d 行目の位置が数でない: %q", n, c[2+i])
			}
			nums[i] = v
		}
		rows = append(rows, Row{Kind: c[0], File: c[1], Line: nums[0], Col: nums[1], EndLine: nums[2], EndCol: nums[3], Sym: c[6], Owner: c[7], Extra: c[8]})
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, errors.New("索引が空（頭の行も無い）")
	}
	return rows, nil
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
	Cached  bool    // 前に作った物をそのまま使った
	Seconds float64 // 作るのに掛かった秒（使い回した時は前に作った時の秒）
	Key     string
}

// Runner は索引を作るコマンドを流す口（既定は heavy の枠の中。テストは直に流す）。stage は枠の長短を決める
// （typed は JVM に 4〜5 GB を取るので長い物の枠で、make test と並ばないようにする）。
type Runner func(stage Stage, desc, dir string, cmd []string) int

// Builder は索引を手に入れる所の設定。
type Builder struct {
	Root     string
	Config   Config
	Flixlint string // 解決済みの bin/flixlint
	FlixJar  string // 解決済みの flix.jar（空なら flixlint に任せる）
	Run      Runner
	Log      io.Writer
	Rebuild  bool // 鍵が同じでも作り直す
}

// Dir は索引の置き場（build/refactor）。
func (b Builder) Dir() string { return filepath.Join(b.Root, "build", "refactor") }

func (b Builder) indexPath(s Stage) string { return filepath.Join(b.Dir(), "spans-"+string(s)+".tsv") }
func (b Builder) keyPath(s Stage) string   { return filepath.Join(b.Dir(), "spans-"+string(s)+".key") }

// Load は段 s の索引を返す。無いか鍵が違えば作る。
func (b Builder) Load(s Stage) (*Index, error) {
	key, err := b.Key(s)
	if err != nil {
		return nil, err
	}
	path := b.indexPath(s)
	if !b.Rebuild {
		if old, secs, ok := readKey(b.keyPath(s)); ok && old == key {
			if rows, err := ReadIndex(path, s); err == nil {
				return &Index{Stage: s, Path: path, Rows: rows, Cached: true, Seconds: secs, Key: key}, nil
			}
		}
	}
	if err := os.MkdirAll(b.Dir(), 0o755); err != nil {
		return nil, err
	}
	tmp := path + ".tmp"
	os.Remove(tmp)
	cmd := []string{b.Flixlint, "--spans", tmp, "--stage", string(s), "--build-dir", filepath.Join(b.Dir(), "flixlint")}
	if b.FlixJar != "" {
		cmd = append(cmd, "--flix-jar", b.FlixJar)
	}
	if extra := strings.Fields(b.Config.JavaOpts); len(extra) > 0 {
		cmd = append(cmd, "--java-opts", b.Config.JavaOpts)
	}
	cmd = append(cmd, b.sources()...)
	fmt.Fprintf(b.Log, "[refactor] 索引（%s）を作ります: %s\n", s, strings.Join(cmd, " "))
	start := time.Now()
	code := b.Run(s, "flixlint --spans --stage "+string(s), b.Root, cmd)
	secs := time.Since(start).Seconds()
	if code != 0 {
		os.Remove(tmp)
		switch code {
		case 4:
			return nil, fmt.Errorf("索引を作れません: flixlint の終了コード 4（呼び方か環境の誤り）。使っている flixlint（%s・%s）が --spans を知らない時もこれになります。"+
				"この道具には flixlint %s 以上が要ります（--spans と索引の形 2）。submodule なら git -C flixlint fetch して %s 以上へ上げ、"+
				"別の場所の物は --flixlint か refactor.local.json の flixlint で名指ししてください。上の flixlint の出力も見てください",
				b.Flixlint, flixlintVersion(b.Flixlint), MinFlixlint, MinFlixlint)
		case 3:
			return nil, fmt.Errorf("索引を作れません: ソースがコンパイルできない（flixlint の終了コード 3。上の出力か make check）")
		default:
			return nil, fmt.Errorf("索引を作れません: flixlint の終了コード %d", code)
		}
	}
	rows, err := ReadIndex(tmp, s)
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
	return &Index{Stage: s, Path: path, Rows: rows, Seconds: secs, Key: key}, nil
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

// MinFlixlint は読める索引（--spans・形の版 FormatVersion）を書く一番古い flixlint の版。
const MinFlixlint = "0.6.0"

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
