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
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	TapesDir      = "tapes"
	PublishedLog  = "published.jsonl"
	ConfigFile    = "tape.publish.json"
	KeepDays      = 30
	DefaultBranch = "main"
	waitLimit     = 10 * time.Minute
	waitEvery     = 10 * time.Second
)

const publishUsage = `使い方: bin/fge tape publish <テープのフォルダ> [--repo <owner/name>] [--yes] [--wait]

  bin/fge tape --dir が作ったフォルダ（index.html・video.mp4・strip.jpg）を、
  GitHub Pages を出す置き場のリポジトリの tapes/<YYYYMMDD>-<乱数 16 桁>/ に置き、公開の URL を出す。

  既定は dry run: 何を置き、何を外すかを出して止まる（push しない）。--yes を付けた時だけ push する。

  --repo <owner/name>  置き場のリポジトリ。省くと環境変数 FGE_TAPE_REPO、
                       それも無ければゲームのリポジトリ直下の tape.publish.json の {"repo": "owner/name"}
  --branch <名前>      Pages が出す枝（既定 main）
  --yes                本当に push する（置き場の枝は履歴を残さず force push で 1 コミットに置き換わる）
  --wait               push の後、URL が開ける（200）まで待つ（最長 10 分）
  --remote <url>       push 先の git の URL（既定 git@github.com:<owner/name>.git。
                       付けた時は GitHub の Pages の設定を確かめない）

  置く時に index.html の <head> へ noindex を足す。置き場の一覧の頁は作らない。
  30 日を過ぎたテープは publish のたびに置き場から外す。
  置いた物の一覧はテープのフォルダの隣の published.jsonl（手元だけ）に 1 行ずつ足す。
  Pages の公開の設定はしない（置き場の Settings → Pages で、枝の / を出す形にしておく）。`

// PublishOptions は Publish の指定。
type PublishOptions struct {
	Dir    string
	Repo   string // owner/name
	Remote string // 空なら git@github.com:<Repo>.git
	Branch string
	Yes    bool
	Wait   bool
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
	URL     string
	Kept    []string
	Removed []string
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

// IsExpired は name の日付が now から KeepDays 日より前なら true。
func IsExpired(name string, now time.Time) bool {
	d, ok := ParseName(name)
	if !ok {
		return false
	}
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.Local)
	return today.Sub(d) > KeepDays*24*time.Hour
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
		repo, err := repoFromConfig(opt.Dir)
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
	fmt.Fprintln(stdout, res.URL)
	if opt.Wait {
		if err := waitFor(res.URL, stdout); err != nil {
			fmt.Fprintln(stderr, "tape publish:", err)
			return 1
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
		case opt.Dir == "":
			opt.Dir = a
		default:
			err = fmt.Errorf("テープのフォルダは 1 つだけ: %s", a)
		}
		if err != nil {
			return opt, false, err
		}
	}
	if opt.Dir == "" {
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
	src, err := filepath.Abs(opt.Dir)
	if err != nil {
		return res, err
	}
	for _, f := range []string{IndexFile, VideoFile, StripFile} {
		if _, err := os.Stat(filepath.Join(src, f)); err != nil {
			return res, fmt.Errorf("%s に %s が無い（先に bin/fge tape --dir %s）", opt.Dir, f, opt.Dir)
		}
	}
	if err := guardNotGameRepo(src, opt.Repo, remote); err != nil {
		return res, err
	}
	if opt.CheckPages != nil {
		if err := opt.CheckPages(opt.Repo); err != nil {
			return res, err
		}
	}
	name := opt.Name
	if name == "" {
		if name, err = NewName(opt.Now); err != nil {
			return res, err
		}
	}
	if _, ok := ParseName(name); !ok {
		return res, fmt.Errorf("フォルダ名の形が違う: %s（<YYYYMMDD>-<16 桁の 16 進>）", name)
	}
	res.Name = name
	res.URL = PagesURL(opt.Repo, name)

	work, err := os.MkdirTemp("", "fge-tape-publish-")
	if err != nil {
		return res, err
	}
	defer os.RemoveAll(work)
	site := filepath.Join(work, "site")

	heads, err := gitOut("", "ls-remote", "--heads", remote, opt.Branch)
	if err != nil {
		return res, fmt.Errorf("置き場 %s を読めない（リポジトリがあるか・手元から git で読めるかを確かめる）: %w", remote, err)
	}
	if strings.TrimSpace(heads) == "" {
		fmt.Fprintf(log, "置き場の枝 %s はまだ無い。新しく作る。\n", opt.Branch)
		if err := os.MkdirAll(site, 0o755); err != nil {
			return res, err
		}
	} else if _, err := gitOut("", "clone", "--quiet", "--depth", "1", "--branch", opt.Branch, remote, site); err != nil {
		return res, fmt.Errorf("置き場を clone できない: %w", err)
	}
	if err := os.RemoveAll(filepath.Join(site, ".git")); err != nil {
		return res, err
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

	dst := filepath.Join(tapes, name)
	if err := copyTape(src, dst); err != nil {
		return res, err
	}

	git := func(args ...string) error {
		_, err := gitOut(site, append([]string{"-c", "user.name=fge tape", "-c", "user.email=fge-tape@localhost", "-c", "commit.gpgsign=false"}, args...)...)
		return err
	}
	msg := fmt.Sprintf("tape: %s を置く（%d 本を残し、%d 本を外す）", name, len(res.Kept), len(res.Removed))
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
	fmt.Fprintf(log, "置く:   %s/%s/  ← %s\n", TapesDir, name, opt.Dir)
	fmt.Fprintf(log, "残す:   %d 本 %s\n", len(res.Kept), strings.Join(res.Kept, " "))
	fmt.Fprintf(log, "外す:   %d 本 %s（%d 日を過ぎた物）\n", len(res.Removed), strings.Join(res.Removed, " "), KeepDays)
	fmt.Fprintf(log, "URL:    %s\n", res.URL)
	if !opt.Yes {
		return res, nil
	}
	if _, err := gitOut(site, "push", "--quiet", "--force", remote, "HEAD:refs/heads/"+opt.Branch); err != nil {
		return res, fmt.Errorf("push できない: %w", err)
	}
	res.Pushed = true
	return res, nil
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

func appendPublished(opt PublishOptions, res PublishResult) error {
	src, _ := filepath.Abs(opt.Dir)
	rec := Published{
		At:     opt.Now.Format(time.RFC3339),
		Name:   res.Name,
		URL:    res.URL,
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
