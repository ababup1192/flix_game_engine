package dashboard

import (
	"bufio"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/posts"
	"github.com/ababup1192/flix_game_engine/go/internal/tape"
)

// TapeCard は Tape タブの 1 枚。
type TapeCard struct {
	Name      string    `json:"name"`
	Title     string    `json:"title"`
	Branch    string    `json:"branch,omitempty"`
	Worktree  string    `json:"worktree"`
	At        time.Time `json:"at"`
	PageURL   string    `json:"pageUrl,omitempty"`
	Published string    `json:"published,omitempty"`
}

// tapeRoot はテープを読む作業ツリー 1 つ（key は URL に使う短い名前）。
type tapeRoot struct {
	key    string
	dir    string
	branch string
	path   string
}

// tapeRoots は全部の作業ツリーの <prefix>/debug/tape。git でなければゲームの根の debug/tape だけ。
// WhyNot: 撮ったテープを main へ写さない — テープは撮った worktree にでき、写すと消した worktree の物と食い違う。
func tapeRoots(r posts.Roots) []tapeRoot {
	wts := posts.Worktrees(r.GameRoot)
	if len(wts) == 0 {
		wts = []posts.Worktree{{Path: r.GameRoot, Branch: r.Branch}}
		r.Prefix = ""
	}
	out := make([]tapeRoot, 0, len(wts))
	for _, w := range wts {
		dir := filepath.Join(w.Path, filepath.FromSlash(r.Prefix), "debug", "tape")
		sum := sha1.Sum([]byte(dir))
		out = append(out, tapeRoot{key: hex.EncodeToString(sum[:])[:10], dir: dir, branch: w.Branch, path: w.Path})
	}
	return out
}

func listTapes(roots []tapeRoot) []TapeCard {
	cards := []TapeCard{}
	for _, root := range roots {
		published := readPublished(filepath.Join(root.dir, tape.PublishedLog))
		entries, err := os.ReadDir(root.dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			dir := filepath.Join(root.dir, e.Name())
			info, err := os.Stat(filepath.Join(dir, tape.TapeFile))
			if err != nil {
				continue
			}
			c := TapeCard{Name: e.Name(), Title: e.Name(), Branch: root.branch, Worktree: root.path, At: info.ModTime()}
			var t struct {
				Title string `json:"title"`
			}
			if raw, err := os.ReadFile(filepath.Join(dir, tape.TapeFile)); err == nil && json.Unmarshal(raw, &t) == nil && t.Title != "" {
				c.Title = t.Title
			}
			if page, err := os.Stat(filepath.Join(dir, tape.IndexFile)); err == nil {
				c.PageURL = "tapes/" + root.key + "/" + e.Name() + "/"
				if page.ModTime().After(c.At) {
					c.At = page.ModTime()
				}
			}
			c.Published = published[posts.RealPath(dir)]
			cards = append(cards, c)
		}
	}
	sort.SliceStable(cards, func(i, j int) bool { return cards[i].At.After(cards[j].At) })
	return cards
}

// readPublished は published.jsonl を、テープのフォルダ → 最後に置いた URL にする。
func readPublished(path string) map[string]string {
	out := map[string]string{}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		var p tape.Published
		if json.Unmarshal([]byte(strings.TrimSpace(sc.Text())), &p) == nil && p.Source != "" && p.URL != "" {
			out[posts.RealPath(p.Source)] = p.URL
		}
	}
	return out
}

func tapesSignature(roots []tapeRoot) string {
	n, latest := 0, int64(0)
	for _, root := range roots {
		if info, err := os.Stat(filepath.Join(root.dir, tape.PublishedLog)); err == nil && info.ModTime().UnixNano() > latest {
			latest = info.ModTime().UnixNano()
		}
		entries, err := os.ReadDir(root.dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			for _, f := range []string{tape.TapeFile, tape.IndexFile} {
				if info, err := os.Stat(filepath.Join(root.dir, e.Name(), f)); err == nil {
					n++
					if info.ModTime().UnixNano() > latest {
						latest = info.ModTime().UnixNano()
					}
				}
			}
		}
	}
	return strconv.Itoa(n) + "-" + strconv.FormatInt(latest, 36)
}
