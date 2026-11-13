package tape

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	TapesDir     = "tapes"
	PublishedLog = "published.jsonl"
	ConfigFile   = "tape.publish.json"
	// MarkerFile は置き場の目印。publish はこれがあるか、HEAD のコミットの文が CommitPrefix で始まる枝にだけ push する。
	MarkerFile    = ".fge-tapes"
	CommitPrefix  = "tape:"
	KeepDays      = 30
	DefaultBranch = "main"
	waitLimit     = 10 * time.Minute
	waitEvery     = 10 * time.Second
)

const publishUsage = `使い方: bin/fge tape publish <テープのフォルダ>… [--repo <owner/name>] [--yes] [--wait] [--init]

  bin/fge tape --dir が作ったフォルダ（index.html・video.mp4・strip.jpg）を、
  GitHub Pages を出す置き場のリポジトリの tapes/<YYYYMMDD>-<乱数 16 桁>/ に置き、公開の URL を出す。
  フォルダを 2 つ以上渡すと（bin/fge tape --group で分岐をつないだテープ）、1 つの乱数のフォルダの下に
  tapes/<YYYYMMDD>-<乱数 16 桁>/<フォルダ名>/ で並べて置き、URL を全部出す（分岐の道のボタンが隣の頁へ移れる）。

  既定は dry run: 何を置き、何を外すかを出して止まる（push しない）。--yes を付けた時だけ push する。

  --repo <owner/name>  置き場のリポジトリ。省くと環境変数 FGE_TAPE_REPO、
                       それも無ければゲームのリポジトリ直下の tape.publish.json の {"repo": "owner/name"}
  --branch <名前>      Pages が出す枝（既定 main）
  --yes                本当に push する（置き場の枝は履歴を残さず force push で 1 コミットに置き換わる）
  --wait               push の後、URL が開ける（200）まで待つ（最長 10 分）
  --init               目印の無い枝を初めて置き場にする（下の「置き場の目印」）
  --remote <url>       push 先の git の URL（既定 git@github.com:<owner/name>.git。
                       付けた時は GitHub の Pages の設定を確かめない）

  置く時に index.html の <head> へ noindex を足す。置き場の一覧の頁は作らない。
  30 日を過ぎたテープは publish のたびに置き場から外す。
  置いた物の一覧はテープのフォルダの隣の published.jsonl（手元だけ）に 1 行ずつ足す。
  Pages の公開の設定はしない（置き場の Settings → Pages で、枝の / を出す形にしておく）。

  置き場の目印: 枝の直下に .fge-tapes があるか、HEAD のコミットの文が "tape:" で始まる枝にだけ push する。
  どちらでも無い既存の枝（別の用途のリポジトリを --repo に取り違えた時など）は止める。初めての置き場だけ --init で通す。
  publish が作るコミットは文を "tape:" で始め、.fge-tapes も必ず置く。`

// PublishOptions は Publish の指定。
type PublishOptions struct {
	Dirs   []string // 1 つなら tapes/<Name>/ に、2 つ以上なら tapes/<Name>/<フォルダ名>/ に並べる
	Repo   string   // owner/name
	Remote string   // 空なら git@github.com:<Repo>.git
	Branch string
	Yes    bool
	Wait   bool
	Init   bool // 目印の無い既存の枝を置き場にしてよい
	Now    time.Time
	// Name は置くフォルダ名。空なら日付と crypto/rand の 16 桁で作る。
	Name string
	// CheckPages は push の前に Pages が有効かを確かめる。nil なら確かめない。
	CheckPages func(repo string) error
	Log        io.Writer
}

// PublishResult は Publish が置いた物。
type PublishResult struct {
	Name    string
	URLs    []string // Dirs と同じ並び
	Kept    []string
	Removed []string
	Outside []string // tapes/ の外で残す物（置き場の直下の名前）
	Pushed  bool
}

// Published は published.jsonl の 1 行。
type Published struct {
	At     string `json:"at"`
	Name   string `json:"name"`
	URL    string `json:"url"`
	Source string `json:"source"`
	Game   string `json:"game"`
	Commit string `json:"commit"`
	Repo   string `json:"repo"`
}

var (
	nameRe = regexp.MustCompile(`^(\d{8})-[0-9a-f]{16}$`)
	repoRe = regexp.MustCompile(`^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$`)
)

// NewName は今日の日付と crypto/rand の 16 桁の 16 進でフォルダ名を作る。
func NewName(now time.Time) (string, error) {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return now.Format("20060102") + "-" + hex.EncodeToString(b[:]), nil
}

// ParseName はフォルダ名の日付を返す。形が違えば ok=false。
func ParseName(name string) (time.Time, bool) {
	m := nameRe.FindStringSubmatch(name)
	if m == nil {
		return time.Time{}, false
	}
	d, err := time.ParseInLocation("20060102", m[1], time.Local)
	if err != nil {
		return time.Time{}, false
	}
	return d, true
}

// IsExpired は name の日付が now の日付から KeepDays 日より前なら true（ちょうど KeepDays 日前は残す）。
// WhyNot: 時刻の差を 24 時間で割らない — 夏時間の切り替わりをまたぐと 1 日が 23・25 時間になり、境目の日がずれる。
func IsExpired(name string, now time.Time) bool {
	d, ok := ParseName(name)
	if !ok {
		return false
	}
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.Local)
	return d.AddDate(0, 0, KeepDays).Before(today)
}

// PagesURL は置いたテープの公開の URL。
func PagesURL(repo, name string) string {
	owner, rname, _ := strings.Cut(repo, "/")
	return fmt.Sprintf("https://%s.github.io/%s/%s/%s/", strings.ToLower(owner), rname, TapesDir, name)
}

var (
	headRe   = regexp.MustCompile(`(?i)<head[^>]*>`)
	robotsRe = regexp.MustCompile(`(?i)<meta[^>]+name=["']?robots["']?`)
)

// AddNoindex は <head> の直後に robots noindex の meta を足す（既にあれば触らない）。
func AddNoindex(page []byte) ([]byte, error) {
	if robotsRe.Match(page) {
		return page, nil
	}
	loc := headRe.FindIndex(page)
	if loc == nil {
		return nil, errors.New("index.html に <head> が無い（bin/fge tape --dir が書いた頁か確かめる）")
	}
	var out bytes.Buffer
	out.Write(page[:loc[1]])
	out.WriteString("\n<meta name=\"robots\" content=\"noindex\">")
	out.Write(page[loc[1]:])
	return out.Bytes(), nil
}

// RunPublish は bin/fge tape publish の本体。
func RunPublish(args []string, stdout, stderr io.Writer) int {
	opt, help, err := parsePublishArgs(args)
	if help {
		fmt.Fprintln(stdout, publishUsage)
		return 0
	}
	if err != nil {
		fmt.Fprintln(stderr, "tape publish:", err)
		fmt.Fprintln(stderr, publishUsage)
		return 2
	}
	if opt.Repo == "" {
		repo, err := repoFromConfig(opt.Dirs[0])
		if err != nil {
			fmt.Fprintln(stderr, "tape publish:", err)
			return 2
		}
		opt.Repo = repo
	}
	opt.Now = time.Now()
	if opt.Remote == "" {
		opt.CheckPages = checkPagesWithGh
	}
	opt.Log = stdout
	res, err := Publish(opt)
	if err != nil {
		fmt.Fprintln(stderr, "tape publish:", err)
		return 1
	}
	if !res.Pushed {
		fmt.Fprintln(stdout, "\ndry run なので push していない。置くなら --yes を付けて流し直す（フォルダ名はその時に作り直す）。")
		return 0
	}
	if err := appendPublished(opt, res); err != nil {
		fmt.Fprintln(stderr, "tape publish: push はできたが一覧を書けない:", err)
	}
	for _, u := range res.URLs {
		fmt.Fprintln(stdout, u)
	}
	if opt.Wait {
		for _, u := range res.URLs {
			if err := waitFor(u, stdout); err != nil {
				fmt.Fprintln(stderr, "tape publish:", err)
				return 1
			}
		}
	}
	return 0
}

func parsePublishArgs(args []string) (PublishOptions, bool, error) {
	opt := PublishOptions{Branch: DefaultBranch}
	value := func(i *int, flag string) (string, error) {
		if *i+1 >= len(args) {
			return "", fmt.Errorf("%s の後に値が要る", flag)
		}
		*i++
		return args[*i], nil
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		var err error
		switch {
		case a == "-h" || a == "--help":
			return opt, true, nil
		case a == "--yes":
			opt.Yes = true
		case a == "--wait":
			opt.Wait = true
		case a == "--init":
			opt.Init = true
		case a == "--repo":
			opt.Repo, err = value(&i, a)
		case strings.HasPrefix(a, "--repo="):
			opt.Repo = strings.TrimPrefix(a, "--repo=")
		case a == "--branch":
			opt.Branch, err = value(&i, a)
		case a == "--remote":
			opt.Remote, err = value(&i, a)
		case strings.HasPrefix(a, "-"):
			err = fmt.Errorf("知らない引数: %s", a)
		default:
			opt.Dirs = append(opt.Dirs, a)
		}
		if err != nil {
			return opt, false, err
		}
	}
	if len(opt.Dirs) == 0 {
		return opt, false, errors.New("テープのフォルダが要る（bin/fge tape --dir が作ったフォルダ）")
	}
	if opt.Wait && !opt.Yes {
		return opt, false, errors.New("--wait は --yes と一緒に使う（dry run では何も置かない）")
	}
	return opt, false, nil
}

func repoFromConfig(dir string) (string, error) {
	if r := os.Getenv("FGE_TAPE_REPO"); r != "" {
		return r, nil
	}
	if top, err := gitOut(dir, "rev-parse", "--show-toplevel"); err == nil {
		raw, err := os.ReadFile(filepath.Join(top, ConfigFile))
		if err == nil {
			var c struct {
				Repo string `json:"repo"`
			}
			if err := json.Unmarshal(raw, &c); err != nil {
				return "", fmt.Errorf("%s を読めない: %w", filepath.Join(top, ConfigFile), err)
			}
			if c.Repo != "" {
				return c.Repo, nil
			}
		}
	}
	return "", errors.New("置き場のリポジトリが決まっていない。--repo <owner/name> を付けるか、FGE_TAPE_REPO か、ゲームのリポジトリ直下の tape.publish.json に {\"repo\": \"owner/name\"} を書く")
}

// Publish は置き場を浅く clone し、30 日以内のテープと新しいテープを並べた木を、
// 親の無い 1 つのコミットにする。Yes の時だけ force push する。
func Publish(opt PublishOptions) (PublishResult, error) {
	var res PublishResult
	log := opt.Log
	if log == nil {
		log = io.Discard
	}
	if !repoRe.MatchString(opt.Repo) {
		return res, fmt.Errorf("--repo は owner/name の形で（受け取った値: %q）", opt.Repo)
	}
	if opt.Branch == "" {
		opt.Branch = DefaultBranch
	}
	remote := opt.Remote
	if remote == "" {
		remote = "git@github.com:" + opt.Repo + ".git"
	}
	if len(opt.Dirs) == 0 {
		return res, errors.New("テープのフォルダが要る（bin/fge tape --dir が作ったフォルダ）")
	}
	srcs := make([]string, len(opt.Dirs))
	subs := make([]string, len(opt.Dirs))
	seen := map[string]string{}
	for i, d := range opt.Dirs {
		src, err := filepath.Abs(d)
		if err != nil {
			return res, err
		}
		for _, f := range []string{IndexFile, VideoFile, StripFile} {
			if _, err := os.Stat(filepath.Join(src, f)); err != nil {
				return res, fmt.Errorf("%s に %s が無い（先に bin/fge tape --dir %s）", d, f, d)
			}
		}
		if err := guardNotGameRepo(src, opt.Repo, remote); err != nil {
			return res, err
		}
		srcs[i] = src
		if len(opt.Dirs) > 1 {
			subs[i] = filepath.Base(src)
			if prev, ok := seen[subs[i]]; ok {
				return res, fmt.Errorf("フォルダ名 %s が 2 つある（%s と %s）。並べて置く時はフォルダ名で分けるので、名前を分ける", subs[i], prev, d)
			}
			seen[subs[i]] = d
		}
	}
	warnMissingRoutes(srcs, subs, log)
	if opt.CheckPages != nil {
		if err := opt.CheckPages(opt.Repo); err != nil {
			return res, err
		}
	}
	name := opt.Name
	var err error
	if name == "" {
		if name, err = NewName(opt.Now); err != nil {
			return res, err
		}
	}
	if _, ok := ParseName(name); !ok {
		return res, fmt.Errorf("フォルダ名の形が違う: %s（<YYYYMMDD>-<16 桁の 16 進>）", name)
	}
	res.Name = name
	for _, sub := range subs {
		u := PagesURL(opt.Repo, name)
		if sub != "" {
			u += sub + "/"
		}
		res.URLs = append(res.URLs, u)
	}

	work, err := os.MkdirTemp("", "fge-tape-publish-")
	if err != nil {
		return res, err
	}
	defer os.RemoveAll(work)
	site := filepath.Join(work, "site")

	ref := "refs/heads/" + opt.Branch
	heads, err := gitOut("", "ls-remote", remote, ref)
	if err != nil {
		return res, fmt.Errorf("置き場 %s を読めない（リポジトリがあるか・手元から git で読めるかを確かめる）: %w", remote, err)
	}
	if !hasRef(heads, ref) {
		fmt.Fprintf(log, "置き場の枝 %s はまだ無い。新しく作る。\n", opt.Branch)
		if err := os.MkdirAll(site, 0o755); err != nil {
			return res, err
		}
	} else {
		if _, err := gitOut("", "clone", "--quiet", "--depth", "1", "--branch", opt.Branch, remote, site); err != nil {
			return res, fmt.Errorf("置き場を clone できない: %w", err)
		}
		if err := guardTapesBranch(site, opt, log); err != nil {
			return res, err
		}
	}
	if err := os.RemoveAll(filepath.Join(site, ".git")); err != nil {
		return res, err
	}
	if err := os.WriteFile(filepath.Join(site, MarkerFile), []byte("この枝は bin/fge tape publish が置くテープの置き場（publish はこの印がある枝にだけ push する）\n"), 0o644); err != nil {
		return res, err
	}
	if top, err := os.ReadDir(site); err == nil {
		for _, e := range top {
			if e.Name() != TapesDir {
				res.Outside = append(res.Outside, e.Name())
			}
		}
	}

	tapes := filepath.Join(site, TapesDir)
	entries, _ := os.ReadDir(tapes)
	for _, e := range entries {
		n := e.Name()
		if IsExpired(n, opt.Now) {
			if err := os.RemoveAll(filepath.Join(tapes, n)); err != nil {
				return res, err
			}
			res.Removed = append(res.Removed, n)
			continue
		}
		res.Kept = append(res.Kept, n)
	}
	sort.Strings(res.Kept)
	sort.Strings(res.Removed)

	for i, src := range srcs {
		if err := copyTape(src, filepath.Join(tapes, name, subs[i])); err != nil {
			return res, err
		}
	}

	git := func(args ...string) error {
		_, err := gitOut(site, append([]string{"-c", "user.name=fge tape", "-c", "user.email=fge-tape@localhost", "-c", "commit.gpgsign=false"}, args...)...)
		return err
	}
	msg := fmt.Sprintf("%s %s を置く（%d 本を残し、%d 本を外す）", CommitPrefix, name, len(res.Kept), len(res.Removed))
	if err := git("init", "--quiet", "-b", opt.Branch); err != nil {
		return res, err
	}
	if err := git("add", "-A"); err != nil {
		return res, err
	}
	if err := git("commit", "--quiet", "-m", msg); err != nil {
		return res, err
	}

	fmt.Fprintf(log, "置き場: %s（枝 %s・履歴を残さず 1 コミットで置き換える）\n", remote, opt.Branch)
	for i, d := range opt.Dirs {
		fmt.Fprintf(log, "置く:   %s  ← %s\n", filepath.Join(TapesDir, name, subs[i])+"/", d)
	}
	fmt.Fprintf(log, "残す:   %d 本 %s\n", len(res.Kept), strings.Join(res.Kept, " "))
	fmt.Fprintf(log, "外す:   %d 本 %s（%d 日を過ぎた物）\n", len(res.Removed), strings.Join(res.Removed, " "), KeepDays)
	fmt.Fprintf(log, "tapes/ の外で残す物: %s\n", strings.Join(res.Outside, " "))
	for _, u := range res.URLs {
		fmt.Fprintf(log, "URL:    %s\n", u)
	}
	if !opt.Yes {
		return res, nil
	}
	if _, err := gitOut(site, "push", "--quiet", "--force", remote, "HEAD:refs/heads/"+opt.Branch); err != nil {
		return res, fmt.Errorf("push できない: %w", err)
	}
	res.Pushed = true
	return res, nil
}

// warnMissingRoutes は、頁の分岐の道（../<フォルダ>/…）の先が一緒に置くフォルダに無ければ 1 行ずつ言う（止めない）。
func warnMissingRoutes(srcs, subs []string, log io.Writer) {
	placed := map[string]bool{}
	for _, sub := range subs {
		if sub != "" {
			placed[sub] = true
		}
	}
	for _, src := range srcs {
		page, err := os.ReadFile(filepath.Join(src, IndexFile))
		if err != nil {
			continue
		}
		told := map[string]bool{}
		for _, name := range routeTargets(page) {
			if placed[name] || told[name] {
				continue
			}
			told[name] = true
			fmt.Fprintf(log, "注意: %s の分岐の道の先 %s が一緒に置くフォルダに無い。公開した頁ではその道へ移れない（同じ publish に並べて渡す）\n", filepath.Base(src), name)
		}
	}
}

// routeTargets は頁の TAPE.branches の道の先のフォルダ名（書いた順。頁が読めなければ空）。
func routeTargets(page []byte) []string {
	i := bytes.Index(page, []byte(tapeDecl))
	if i < 0 {
		return nil
	}
	var tape struct {
		Branches []Branch `json:"branches"`
	}
	if err := json.NewDecoder(bytes.NewReader(page[i+len(tapeDecl):])).Decode(&tape); err != nil {
		return nil
	}
	var out []string
	for _, br := range tape.Branches {
		for _, r := range br.Routes {
			rest, ok := strings.CutPrefix(r.Href, "../")
			if !ok {
				continue
			}
			dir, _, _ := strings.Cut(rest, "/")
			if name, err := url.PathUnescape(dir); err == nil && name != "" {
				out = append(out, name)
			}
		}
	}
	return out
}

// hasRef は ls-remote の出力に ref と完全に同じ名前の行があるか（refs/heads/main と refs/heads/x/main を取り違えない）。
func hasRef(lsRemote, ref string) bool {
	for _, line := range strings.Split(lsRemote, "\n") {
		if f := strings.Fields(line); len(f) == 2 && f[1] == ref {
			return true
		}
	}
	return false
}

// guardTapesBranch は clone した枝が置き場の目印を持つかを確かめる。目印が無い枝は opt.Init の時だけ通す。
func guardTapesBranch(site string, opt PublishOptions, log io.Writer) error {
	if _, err := os.Stat(filepath.Join(site, MarkerFile)); err == nil {
		return nil
	}
	subject, err := gitOut(site, "log", "-1", "--format=%s")
	if err != nil {
		return err
	}
	if strings.HasPrefix(subject, CommitPrefix) {
		return nil
	}
	if opt.Init {
		fmt.Fprintf(log, "枝 %s に置き場の目印（%s・%q で始まるコミット）が無いが、--init なので置き場にする。\n", opt.Branch, MarkerFile, CommitPrefix)
		return nil
	}
	return fmt.Errorf("枝 %s は置き場の目印（直下の %s か、文が %q で始まる HEAD のコミット）を持たない（HEAD: %q）。"+
		"別の用途のリポジトリなら --repo を確かめる。テープの置き場として初めて使うなら --init を付けて流す", opt.Branch, MarkerFile, CommitPrefix, subject)
}

// guardNotGameRepo はテープのフォルダがあるゲームのリポジトリへ置こうとしていないかを確かめる。
func guardNotGameRepo(src, repo, remote string) error {
	remotes, err := gitOut(src, "remote", "-v")
	if err != nil {
		return nil
	}
	want := strings.ToLower(repo)
	for _, line := range strings.Split(remotes, "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		u := strings.ToLower(strings.TrimSuffix(f[1], ".git"))
		if u == strings.ToLower(strings.TrimSuffix(remote, ".git")) || strings.HasSuffix(u, ":"+want) || strings.HasSuffix(u, "/"+want) {
			return fmt.Errorf("置き場 %s はテープを撮ったゲームのリポジトリそのもの。ゲームのリポジトリには置かない（テープ専用のリポジトリを --repo に渡す）", repo)
		}
	}
	return nil
}

func copyTape(src, dst string) error {
	if err := os.MkdirAll(dst, 0o755); err != nil {
		return err
	}
	page, err := os.ReadFile(filepath.Join(src, IndexFile))
	if err != nil {
		return err
	}
	page, err = AddNoindex(page)
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dst, IndexFile), page, 0o644); err != nil {
		return err
	}
	for _, f := range []string{VideoFile, StripFile} {
		if err := copyTapeFile(filepath.Join(src, f), filepath.Join(dst, f)); err != nil {
			return err
		}
	}
	return nil
}

func copyTapeFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func gitOut(dir string, args ...string) (string, error) {
	if dir != "" {
		args = append([]string{"-C", dir}, args...)
	}
	cmd := exec.Command("git", args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return strings.TrimSpace(string(out)), nil
}

func checkPagesWithGh(repo string) error {
	if _, err := exec.LookPath("gh"); err != nil {
		return nil
	}
	cmd := exec.Command("gh", "api", "repos/"+repo+"/pages", "--jq", ".status")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if _, err := cmd.Output(); err != nil {
		if strings.Contains(stderr.String(), "404") {
			return fmt.Errorf("置き場 %s の GitHub Pages が有効でない。置き場の Settings → Pages で、枝の / を出す形にしてから流し直す（publish は Pages の設定をしない）", repo)
		}
		return fmt.Errorf("置き場 %s の Pages の設定を gh で読めない（gh auth status を確かめる）: %s", repo, strings.TrimSpace(stderr.String()))
	}
	return nil
}

var commitRe = regexp.MustCompile(`"commit":"([^"]*)"`)

// appendPublished は置いたテープ 1 本ごとに 1 行を、そのフォルダの隣の published.jsonl へ足す。
func appendPublished(opt PublishOptions, res PublishResult) error {
	for i, d := range opt.Dirs {
		if i >= len(res.URLs) {
			break
		}
		if err := appendPublishedOne(opt, res.Name, res.URLs[i], d); err != nil {
			return err
		}
	}
	return nil
}

func appendPublishedOne(opt PublishOptions, name, url, dir string) error {
	src, _ := filepath.Abs(dir)
	rec := Published{
		At:     opt.Now.Format(time.RFC3339),
		Name:   name,
		URL:    url,
		Source: src,
		Repo:   opt.Repo,
	}
	if raw, err := os.ReadFile(filepath.Join(src, TapeFile)); err == nil {
		var t struct {
			Game string `json:"game"`
		}
		if json.Unmarshal(raw, &t) == nil {
			rec.Game = t.Game
		}
	}
	if page, err := os.ReadFile(filepath.Join(src, IndexFile)); err == nil {
		if m := commitRe.FindSubmatch(page); m != nil {
			rec.Commit = string(m[1])
		}
	}
	line, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(filepath.Dir(src), PublishedLog), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	w := bufio.NewWriter(f)
	w.Write(line)
	w.WriteByte('\n')
	if err := w.Flush(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func waitFor(url string, out io.Writer) error {
	deadline := time.Now().Add(waitLimit)
	client := &http.Client{Timeout: 15 * time.Second}
	for {
		resp, err := client.Get(url)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				fmt.Fprintln(out, "開けるようになった:", url)
				return nil
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%s 待っても %s が開けない（置き場の Actions で Pages の配信が終わったか確かめる）", waitLimit, url)
		}
		time.Sleep(waitEvery)
	}
}
