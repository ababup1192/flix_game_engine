// Package tape は flow で撮った動画を、スマホで注釈を付ける 1 枚の頁（index.html）に束ねる。
//
// 入力はゲームが書いた tape.json と video.mp4。ここで足すのは commit・strip.jpg（コマを横に並べた絵）と
// それを指す欄だけで、ゲームの書いた値は並びも中身もそのまま頁へ渡す。
package tape

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/yarn"
)

//go:embed template.html
var templateHTML string

// tapeDecl は雛形で TAPE の JSON を置く所の前の字（publish が置いた頁の branches を読み返す時にも引く）。
const tapeDecl = "const TAPE = "

// splashDecl は雛形で SPLASH の JSON を置く所の前の字。
const splashDecl = "const SPLASH = "

const (
	TapeFile  = "tape.json"
	VideoFile = "video.mp4"
	StripFile = "strip.jpg"
	IndexFile = "index.html"

	// 縦の画面（スマホを縦に持った時）で同じ flow を撮った分。あれば頁は縦で開き、ボタンで横（上の 3 つ）へ替える。
	PhoneTapeFile  = "tape-phone.json"
	PhoneVideoFile = "video-phone.mp4"
	PhoneStripFile = "strip-phone.jpg"

	// PlayDir はテープのフォルダの中に置くゲームのブラウザ版（bin/fge export-web の書き出し）。あれば頁の上に「はじめから遊ぶ」を出す。
	PlayDir = "play"

	// StripPerSec は strip のコマの間隔（0.5 秒ごと）。頁の欄の名前 stripPerSec はモックのまま。
	StripPerSec = 2
	// StripW・StripH は strip の 1 コマ（帯とサムネの枠の比）。動画の比が違えば真ん中から切り抜く（横長の動画は左右が落ちる）。
	StripW = 54
	StripH = 96
)

// Strip は頁の TAPE.strip。Cols・Rows は格子の列と行の数（無い頁は前の版の横 1 列）。
type Strip struct {
	File  string `json:"file"`
	Count int    `json:"count"`
	W     int    `json:"w"`
	H     int    `json:"h"`
	Cols  int    `json:"cols,omitempty"`
	Rows  int    `json:"rows,omitempty"`
}

// Options は Build の指定。
type Options struct {
	Dir    string
	Group  []string // --group のフォルダ（2 つ以上。Dir の代わり）
	Commit string   // 空なら Dir で git rev-parse --short HEAD
	FFmpeg string   // 空なら環境変数 FFMPEG、それも無ければ PATH の ffmpeg
	// Branches は頁の branches をこの値にする（--group が組み立てた物）。nil なら tape.json の値のまま。
	Branches *[]Branch
	// Splash は動画を取っている間に頁が描く起動画面の材料（bin/fge が engine の BootFontData から作って渡す）。
	Splash Splash
	// Warn は止めない注意の書き先（nil なら書かない）。
	Warn io.Writer
	// Play はゲームのブラウザ版の書き出しのフォルダ（--play）。空でなければテープのフォルダの play/ へ写す。
	Play string
	// PlayCheck は写す前の書き出しと、残っている play/ に掛ける公開前の門（bin/fge が web-check を渡す。nil なら掛けない）。
	// 赤なら play/ を置かず、頁は「はじめから遊ぶ」を出さない。report は Warn へ書く 1 行。
	PlayCheck func(dir string) (ok bool, report string)
}

// Splash は頁の SPLASH。ゲームのブラウザ版の bundle.json の splash と同じ形（ロゴと組み込みフォントの PNG・字の表・字の寸法）。
// WhyNot: 頁の system-ui の字で起動画面を描かない — ゲームの起動画面はドットの字で描くので、並べた時に同じ絵に見えない。
// WhyNot: ここで BootFontData.flix を読まない — 読み解きは書き出し（export-web）の側に 1 つだけ置き、2 つに割らない。
type Splash struct {
	Logo     string  `json:"logo,omitempty"`
	Font     string  `json:"font,omitempty"`
	Glyphs   string  `json:"glyphs,omitempty"`
	FontSize float64 `json:"fontSize,omitempty"`
	Ascent   float64 `json:"ascent,omitempty"`
	Descent  float64 `json:"descent,omitempty"`
	LineGap  float64 `json:"lineGap,omitempty"`
	CellH    int     `json:"cellH,omitempty"`
}

// Run は bin/fge tape の本体。splash は作る頁に埋める起動画面の材料（publish では使わない）。
func Run(args []string, splash Splash, playCheck func(string) (bool, string), stdout, stderr io.Writer) int {
	if len(args) > 0 && args[0] == "publish" {
		return RunPublish(args[1:], stdout, stderr)
	}
	opt, err := parseArgs(args)
	if err != nil {
		fmt.Fprintln(stderr, err)
		fmt.Fprintln(stderr, usage)
		return 2
	}
	opt.Splash = splash
	opt.PlayCheck = playCheck
	opt.Warn = stderr
	if len(opt.Group) > 0 {
		outs, err := BuildGroup(opt, stderr)
		if err != nil {
			fmt.Fprintln(stderr, "tape:", err)
			return 1
		}
		fmt.Fprintln(stdout, strings.Join(outs, "\n"))
		return 0
	}
	out, err := Build(opt)
	if err != nil {
		fmt.Fprintln(stderr, "tape:", err)
		return 1
	}
	fmt.Fprintln(stdout, out)
	return 0
}

const usage = "使い方: bin/fge tape --dir <フォルダ>   （フォルダに tape.json と video.mp4。strip.jpg と index.html を書く。ゲームのシナリオが見つかれば分岐のグラフとシナリオ原稿 .md も頁に載せる）\n" +
	"       bin/fge tape --group <フォルダ> <フォルダ>…   （同じ始まりから撮った複数のテープ。選んだ道が分かれた所を分岐にして、グラフの箱から隣の頁へつなぐ。フォルダは並べて置く）\n" +
	"       どちらにも --play <書き出しのフォルダ> を付けると、ゲームのブラウザ版（bin/fge export-web の書き出し）を各フォルダの play/ へ写し、頁の上に「はじめから遊ぶ」を出す\n" +
	"       （フォルダに tape-phone.json と video-phone.mp4 があれば、縦の画面の分として頁に載せ、頁は縦で開いて上のボタンで横へ替える）\n" +
	"       bin/fge tape publish <フォルダ>…   （Pages の置き場へ置いて URL を出す。詳しくは publish --help）"

func parseArgs(args []string) (Options, error) {
	var opt Options
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--dir" && i+1 < len(args):
			opt.Dir = args[i+1]
			i++
		case strings.HasPrefix(a, "--dir="):
			opt.Dir = strings.TrimPrefix(a, "--dir=")
		case a == "--group":
			for i+1 < len(args) && !strings.HasPrefix(args[i+1], "-") {
				opt.Group = append(opt.Group, args[i+1])
				i++
			}
		case a == "--play" && i+1 < len(args):
			opt.Play = args[i+1]
			i++
		case strings.HasPrefix(a, "--play="):
			opt.Play = strings.TrimPrefix(a, "--play=")
		case a == "-h" || a == "--help":
			return opt, errors.New("")
		default:
			return opt, fmt.Errorf("知らない引数: %s", a)
		}
	}
	if opt.Dir != "" && len(opt.Group) > 0 {
		return opt, errors.New("--dir と --group はどちらか 1 つ")
	}
	if len(opt.Group) == 1 {
		return opt, errors.New("--group には 2 つ以上のフォルダが要る（1 つなら --dir）")
	}
	if opt.Dir == "" && len(opt.Group) == 0 {
		return opt, errors.New("--dir か --group が要る")
	}
	return opt, nil
}

// Build は Dir の tape.json と video.mp4 から strip.jpg と index.html を書き、index.html の道を返す。
func Build(opt Options) (string, error) {
	raw, err := os.ReadFile(filepath.Join(opt.Dir, TapeFile))
	if err != nil {
		return "", fmt.Errorf("%s を読めない（ゲームの make tape が書く）: %w", TapeFile, err)
	}
	t, err := Parse(raw)
	if err != nil {
		return "", err
	}
	return build(opt, t)
}

func build(opt Options, t *Tape) (string, error) {
	video := filepath.Join(opt.Dir, VideoFile)
	info, err := os.Stat(video)
	if err != nil {
		return "", fmt.Errorf("%s が無い（ゲームの Makefile の動画の手順が作る）: %w", video, err)
	}
	// WhyNot: 頁で返事の Content-Length だけに頼らない — GitHub Pages は大きな mp4 を Content-Length 無しで返すことがあり、割合が出せない。
	t.raw["videoBytes"] = json.RawMessage(fmt.Sprint(info.Size()))
	commit := opt.Commit
	if commit == "" {
		if commit, err = gitShortHead(opt.Dir); err != nil {
			return "", err
		}
	}
	strip, err := MakeStrip(opt.FFmpeg, video, filepath.Join(opt.Dir, StripFile), t.Duration)
	if err != nil {
		return "", err
	}
	if err := addPhoneView(opt.FFmpeg, opt.Dir, t); err != nil {
		return "", err
	}
	if err := addPlay(opt, t); err != nil {
		return "", err
	}
	addScript(opt.Dir, t, opt.Warn)
	if err := nameScenes(t); err != nil {
		return "", err
	}
	pickSceneThumbs(t, filepath.Join(opt.Dir, StripFile), strip)
	if opt.Branches != nil {
		b, err := json.Marshal(*opt.Branches)
		if err != nil {
			return "", err
		}
		t.raw["branches"] = b
	}
	page, err := Render(t, commit, strip, opt.Splash)
	if err != nil {
		return "", err
	}
	index := filepath.Join(opt.Dir, IndexFile)
	if err := os.WriteFile(index, page, 0o644); err != nil {
		return "", err
	}
	return index, nil
}

// View は頁の TAPE.views の 1 つ（同じ flow を別の画面の大きさで撮った分）。台詞・帯・音の時刻は上の欄と同じ物を使い、
// 画面の形で変わる物（動画・帯の絵・メッセージウィンドウ・画面に出ている物の枠）だけを持つ。
type View struct {
	Video      string          `json:"video"`
	VideoBytes int64           `json:"videoBytes"`
	Strip      Strip           `json:"strip"`
	Msg        json.RawMessage `json:"msg"`
	Objects    json.RawMessage `json:"objects"`
}

// sameTimeKeys は縦と横で一致しないといけない欄（頁はどちらの動画でも同じ時刻の台詞・帯・音・分岐を出す）。
var sameTimeKeys = []string{"duration", "fps", "scenes", "timeline", "lines", "sounds", "choices", "yarn", "node"}

// addPhoneView は dir に縦の画面の tape-phone.json があれば、video-phone.mp4 の strip を作り、頁の views.phone に足す。
// tape-phone.json が無ければ何もしない（横だけのテープ。頁は切り替えのボタンを出さない）。
// WhyNot: 時刻が食い違う縦の分を言わずに載せない — 切り替えた途端に台詞と帯が動画とずれ、注釈が別のコマを指す。
func addPhoneView(ffmpeg, dir string, t *Tape) error {
	raw, err := os.ReadFile(filepath.Join(dir, PhoneTapeFile))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	phone, err := Parse(raw)
	if err != nil {
		return fmt.Errorf("%s: %w", PhoneTapeFile, err)
	}
	for _, key := range sameTimeKeys {
		if !sameJSON(t.raw[key], phone.raw[key]) {
			return fmt.Errorf("%s と %s で %q が違う（縦と横で同じ flow が同じ時刻に進んでいない。縦だけ・横だけで撮るならゲームの make tape の TAPE_VIEWS）", TapeFile, PhoneTapeFile, key)
		}
	}
	video := filepath.Join(dir, PhoneVideoFile)
	info, err := os.Stat(video)
	if err != nil {
		return fmt.Errorf("%s があるのに %s が無い（ゲームの Makefile の動画の手順が作る）: %w", PhoneTapeFile, video, err)
	}
	strip, err := MakeStrip(ffmpeg, video, filepath.Join(dir, PhoneStripFile), phone.Duration)
	if err != nil {
		return err
	}
	views, err := json.Marshal(map[string]View{"phone": {Video: PhoneVideoFile, VideoBytes: info.Size(), Strip: strip,
		Msg: phone.raw["msg"], Objects: phone.raw["objects"]}})
	if err != nil {
		return err
	}
	t.raw["views"] = views
	return nil
}

// addPlay は opt.Play（空なら写さない）を dir/play へ写し、dir/play/index.html があれば頁の start に足す。
// opt.PlayCheck が赤なら写さず、前に写した play/ も消す。
func addPlay(opt Options, t *Tape) error {
	play, dir := opt.Play, opt.Dir
	dst := filepath.Join(dir, PlayDir)
	if play != "" {
		if _, err := os.Stat(filepath.Join(play, "index.html")); err != nil {
			return fmt.Errorf("--play %s に index.html が無い（bin/fge export-web の書き出しのフォルダを渡す）: %w", play, err)
		}
		if opt.PlayCheck != nil && !isExport(play) {
			return fmt.Errorf("--play %s に bundle.json が無い（bin/fge export-web の書き出しのフォルダを渡す）", play)
		}
		if !playPasses(opt, play, dst) {
			return nil
		}
		if err := os.RemoveAll(dst); err != nil {
			return err
		}
		if err := copyTree(play, dst); err != nil {
			return fmt.Errorf("%s を %s へ写せない: %w", play, dst, err)
		}
	}
	if _, err := os.Stat(filepath.Join(dst, "index.html")); err != nil {
		return nil
	}
	if err := checkNoHomePath(dst); err != nil {
		return err
	}
	if play == "" && opt.PlayCheck != nil {
		// WhyNot: 書き出しでない play/（bundle.json の無い、人が置いた物）を門に掛けて消さない — 人のファイルを消す。start も付けない。
		if !isExport(dst) {
			return nil
		}
		if !playPasses(opt, dst, dst) {
			return nil
		}
	}
	t.raw["start"] = json.RawMessage(`"` + PlayDir + `/index.html"`)
	return nil
}

// checkNoHomePath は dir の下のファイルに、手元のホームのパス（ユーザー名を含む）が入っていないかを見る。
// WhyNot: 書き出しをそのまま置き場へ出さない — 組み立てた作業フォルダのパスが wasm に残ることがあり、公開した頁からユーザー名が読める。
func checkNoHomePath(dir string) error {
	home, err := os.UserHomeDir()
	if err != nil || len(home) < 2 {
		return nil
	}
	needles := [][]byte{[]byte(home), []byte(filepath.ToSlash(home))}
	return filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		body, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		for _, n := range needles {
			if bytes.Contains(body, n) {
				return fmt.Errorf("%s にホームのパス（%s）が入っている。公開するとユーザー名が読めるので、ホームの外の作業フォルダで書き出し直す（bin/fge export-web --work /tmp/…）", p, home)
			}
		}
		return nil
	})
}

// copyTree は src の下を dst へ写す（dst は無い前提）。
func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, p)
		if err != nil {
			return err
		}
		to := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(to, 0o755)
		}
		return copyTapeFile(p, to)
	})
}

// sameJSON は 2 つの JSON の値が同じか（空白と、オブジェクトの鍵の並びは見ない）。どちらも無い欄は同じ。
func sameJSON(a, b json.RawMessage) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	var x, y any
	if json.Unmarshal(a, &x) != nil || json.Unmarshal(b, &y) != nil {
		return false
	}
	ja, _ := json.Marshal(x)
	jb, _ := json.Marshal(y)
	return bytes.Equal(ja, jb)
}

// addScript は tape.json の yarn（ゲームのルートからのパス）のフォルダの .yarn から、分岐のグラフ（graph）と
// シナリオ原稿の Markdown（script）を作って頁の欄に足す。ゲームのルートは dir から上へ辿って最初に project.json のあるフォルダ。
// ルートか .yarn が見つからなければ足さない（頁は「映像 / グラフ」とシナリオ原稿のボタンを出さない）。
// WhyNot: シナリオが読めなくても頁を作るのをやめない — 動画に注釈を付けるのがテープの本題で、グラフは添え物。
func addScript(dir string, t *Tape, warn io.Writer) {
	root := yarn.FindGameRoot(dir)
	if root == "" || t.Yarn == "" {
		return
	}
	folder := filepath.Dir(filepath.Join(root, filepath.FromSlash(t.Yarn)))
	if info, err := os.Stat(folder); err != nil || !info.IsDir() {
		return
	}
	graph, script, err := yarn.ForTape(folder)
	if err == nil && graph != nil {
		var g, s []byte
		if g, err = json.Marshal(graph); err == nil {
			if s, err = json.Marshal(script); err == nil {
				t.raw["graph"], t.raw["script"] = g, s
			}
		}
	}
	if err != nil && warn != nil {
		fmt.Fprintf(warn, "tape: 注意: シナリオ %s を読めないので、グラフとシナリオ原稿を載せない: %v\n", folder, err)
	}
}

// markSlack は mark の秒より前でも、そのシーンの最初の行として数える幅（秒）。flow は行を出したコマの次のコマで mark を打つことがある。
const markSlack = 0.1

// nameScenes は名前の表に無かったシーン（name が id のまま）の name を、そのシーンの最初の台詞か地の文の見出し（yarn.ShortHeading）にする。
// 文の行が 1 つも無いシーンは id のまま。選択肢の行は文に数えない。
// WhyNot: ゲームの tape.json を書き直させない — 名前の表を書き足さないと英語の mark の名前が出て、撮り直さないと直らない。
// WhyNot: 表で id と同じ名前を付けたシーンも書き替える — tape.json は表に無いのか同じ名前なのかを持たず、id と同じ名前は英語の mark の名前の時がほとんど。
func nameScenes(t *Tape) error {
	var scenes []scene
	var timeline [][2]*float64
	var lines map[string]line
	if err := json.Unmarshal(t.raw["scenes"], &scenes); err != nil {
		return err
	}
	_ = json.Unmarshal(t.raw["timeline"], &timeline)
	_ = json.Unmarshal(t.raw["lines"], &lines)
	for i, s := range scenes {
		if *s.Name != *s.ID {
			continue
		}
		end := t.Duration
		if i+1 < len(scenes) {
			end = *scenes[i+1].T
		}
		if h := firstHeading(timeline, lines, t.Choices, *s.T-markSlack, end-markSlack); h != "" {
			scenes[i].Name = &h
		}
	}
	b, err := json.Marshal(scenes)
	if err != nil {
		return err
	}
	t.raw["scenes"] = b
	return nil
}

// firstHeading は秒 from 以上 to 未満に出た最初の文の行（選択肢の行を除く）の見出し（無ければ空）。
func firstHeading(timeline [][2]*float64, lines map[string]line, choices []Choice, from, to float64) string {
	for _, row := range timeline {
		if row[0] == nil || row[1] == nil || *row[0] < from || *row[0] >= to || isChoiceRow(choices, *row[0], int(*row[1])) {
			continue
		}
		if l := lines[strconv.Itoa(int(*row[1]))]; l.Text != nil {
			if h := yarn.ShortHeading(*l.Text); h != "" {
				return h
			}
		}
	}
	return ""
}

// isChoiceRow は timeline の行が選択肢の行か（選択肢が出た秒の行か、選択肢の行番号の並びの中）。
func isChoiceRow(choices []Choice, t float64, ln int) bool {
	for _, ch := range choices {
		if t == ch.T || (ln >= ch.Line && ln < ch.Line+len(ch.Options)) {
			return true
		}
	}
	return false
}

func gitShortHead(dir string) (string, error) {
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--short", "HEAD").Output()
	if err != nil {
		return "", fmt.Errorf("commit を取れない（%s で git rev-parse --short HEAD が失敗。ゲームのリポジトリの中で流す）: %w", dir, err)
	}
	return strings.TrimSpace(string(out)), nil
}

// Render は雛形の HTML に TAPE と SPLASH を差し込む。足す欄（commit・video・stripPerSec・strip）はゲームの値より優先する。
func Render(t *Tape, commit string, strip Strip, splash Splash) ([]byte, error) {
	added := map[string]any{"commit": commit, "video": VideoFile, "stripPerSec": StripPerSec, "strip": strip}
	var buf bytes.Buffer
	buf.WriteByte('{')
	first := true
	write := func(key string, val []byte) {
		if !first {
			buf.WriteByte(',')
		}
		first = false
		k, _ := json.Marshal(key)
		buf.Write(k)
		buf.WriteByte(':')
		buf.Write(val)
	}
	for _, key := range fieldOrder {
		if v, ok := added[key]; ok {
			b, err := json.Marshal(v)
			if err != nil {
				return nil, err
			}
			write(key, b)
			continue
		}
		v, ok := t.raw[key]
		if !ok {
			continue
		}
		var c bytes.Buffer
		if err := json.Compact(&c, v); err != nil {
			return nil, err
		}
		write(key, c.Bytes())
	}
	buf.WriteByte('}')
	// WhyNot: 素の JSON を <script> にそのまま置くと、台詞の "</script>" で頁が切れる。< > & と U+2028/9 を \u に逃がす。
	var safe bytes.Buffer
	json.HTMLEscape(&safe, buf.Bytes())

	splashJSON, err := json.Marshal(splash)
	if err != nil {
		return nil, err
	}
	page := strings.Replace(templateHTML, tapeDecl+"__TAPE_JSON__", tapeDecl+safe.String(), 1)
	page = strings.Replace(page, splashDecl+"__SPLASH_JSON__", splashDecl+string(splashJSON), 1)
	page = strings.Replace(page, "__TAPE_TITLE__", html.EscapeString(t.Title), 1)
	return []byte(page), nil
}

// isExport は dir が bin/fge export-web の書き出し（bundle.json がある）か。
func isExport(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, "bundle.json"))
	return err == nil
}

// playPasses は src（写す前の書き出しか、残っている play/）に公開前の門を掛ける。赤なら dst の play/ を消し、Warn に 1 行書く。
// dst を消すのは、dst が書き出し（bundle.json がある）の時だけ。
// WhyNot: 赤の時に前の play/ を残さない — 前の版の書き出しが「はじめから遊ぶ」付きで公開され続ける。
func playPasses(opt Options, src, dst string) bool {
	if opt.PlayCheck == nil {
		return true
	}
	ok, report := opt.PlayCheck(src)
	if ok {
		return true
	}
	if isExport(dst) {
		os.RemoveAll(dst)
	}
	if opt.Warn != nil {
		fmt.Fprintf(opt.Warn, "tape: ブラウザ版を play/ に置かない（公開前の門が赤・頁は「はじめから遊ぶ」を出さない）: %s\n", report)
	}
	return false
}
