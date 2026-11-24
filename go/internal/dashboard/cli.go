package dashboard

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
	"github.com/ababup1192/flix_game_engine/go/internal/posts"
)

func (d Deps) now() time.Time {
	if d.Now == nil {
		return time.Now()
	}
	return d.Now()
}

// roots は今のフォルダの置き場の根。main にゲームが無くて worktree の置き場へ戻した時は stderr に 1 行出す。
func (d Deps) roots(stderr io.Writer) (posts.Roots, error) {
	wd, err := d.Getwd()
	if err != nil {
		return posts.Roots{}, err
	}
	r := posts.Resolve(wd)
	if note := r.MissingNote(); note != "" {
		fmt.Fprintf(stderr, "[dashboard] %s\n", note)
	}
	return r, nil
}

// splitFlags は引数を旗と残りに分ける。known に無い旗は誤り（値を取る旗は known の値が true）。
func splitFlags(args []string, known map[string]bool) (map[string]string, []string, error) {
	flags := map[string]string{}
	var rest []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "--") {
			rest = append(rest, a)
			continue
		}
		name, val, hasVal := strings.Cut(strings.TrimPrefix(a, "--"), "=")
		takesValue, ok := known[name]
		if !ok {
			return nil, nil, fmt.Errorf("知らない旗です: %s", a)
		}
		if takesValue && !hasVal {
			if i+1 >= len(args) {
				return nil, nil, fmt.Errorf("--%s に値がありません", name)
			}
			i++
			val = args[i]
		}
		flags[name] = val
	}
	return flags, rest, nil
}

// gameLink は MainRoot のゲームの頁の URL と、ワークスペースの一覧にあるか。
func gameLink(mainRoot string) (string, bool) {
	name, listed := filepath.Base(mainRoot), false
	if ws, err := fgehome.ReadWorkspace(); err == nil {
		for _, g := range ws.Games {
			if posts.SamePath(g.Dir, mainRoot) {
				name, listed = g.Name, true
				break
			}
		}
	}
	return localURL(DefaultPort, "/"+url.PathEscape(name)+"/"), listed
}

func runPost(args []string, asJSON bool, stdout, stderr io.Writer, d Deps) int {
	const use = "使い方: bin/fge dashboard post <post.json> [--author <名前>] [--json]"
	flags, rest, err := splitFlags(args, map[string]bool{"author": true})
	if err != nil || len(rest) != 1 {
		if err != nil {
			fmt.Fprintf(stderr, "!! %v\n", err)
		}
		fmt.Fprintln(stderr, use)
		return exitBadUsage
	}
	roots, err := d.roots(stderr)
	if err != nil {
		fmt.Fprintf(stderr, "!! %v\n", err)
		return exitProblem
	}
	manifest := rest[0]
	if !filepath.IsAbs(manifest) {
		wd, _ := d.Getwd()
		manifest = filepath.Join(wd, manifest)
	}
	repo := roots.Worktree
	if repo == "" {
		repo = roots.GameRoot
	}
	id, err := posts.Create(posts.CreateOptions{
		PostsDir: roots.PostsDir(), Manifest: manifest, RepoRoot: repo, Author: flags["author"],
		Origin: posts.Origin{Branch: roots.Branch, Worktree: roots.Worktree}, Now: d.now(),
	})
	if err != nil {
		fmt.Fprintf(stderr, "!! post を置けません:\n%v\n", err)
		return exitProblem
	}
	link, listed := gameLink(roots.MainRoot)
	link += "#post-" + id
	dir := filepath.Join(roots.PostsDir(), id)
	if asJSON {
		b, _ := json.Marshal(map[string]string{"id": id, "dir": dir, "url": link})
		fmt.Fprintln(stdout, string(b))
		return exitDone
	}
	running := ""
	if d.IsOurServer != nil {
		running = "（人が fge dashboard を立てると開ける）"
		if d.IsOurServer(DefaultPort) {
			running = "（立っています）"
		}
	}
	fmt.Fprintf(stdout, "[dashboard] post を置きました: %s\n", id)
	fmt.Fprintf(stdout, "  置き場: %s\n", dir)
	fmt.Fprintf(stdout, "  頁:     %s%s\n", link, running)
	if !listed {
		fmt.Fprintf(stdout, "  このゲームはワークスペースの一覧にまだありません。人が %s で fge dashboard を打つと足されます\n", roots.MainRoot)
	}
	fmt.Fprintln(stdout, "  人の返事は bin/fge dashboard inbox で拾う")
	return exitDone
}

// InboxPick は選んだ案 1 つ（--json の形）。
type InboxPick struct {
	Section string   `json:"section"`
	Option  string   `json:"option"`
	Label   string   `json:"label,omitempty"`
	Media   []string `json:"media,omitempty"`
}

// InboxItem は inbox の 1 件（--json の形）。Ref は resolve に渡す「<id>@<返事の at>」。
type InboxItem struct {
	ID     string       `json:"id"`
	Ref    string       `json:"ref"`
	Title  string       `json:"title"`
	Dir    string       `json:"dir"`
	Origin posts.Origin `json:"origin"`
	Reply  posts.Reply  `json:"reply"`
	Picks  []InboxPick  `json:"picks"`
}

func inboxItem(p posts.Post) InboxItem {
	it := InboxItem{ID: p.ID, Ref: p.Ref(), Title: p.Title, Dir: p.Dir, Origin: p.Origin, Reply: *p.Reply, Picks: []InboxPick{}}
	m := p.Manifest
	keys := make([]string, 0, len(p.Reply.Picks))
	for k := range p.Reply.Picks {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		pick := InboxPick{Section: k, Option: p.Reply.Picks[k]}
		if m != nil {
			if c, ok := m.ChoiceOf(k, pick.Option); ok {
				pick.Label = c.Label
				for _, src := range c.Media {
					pick.Media = append(pick.Media, filepath.Join(p.Dir, filepath.FromSlash(src)))
				}
			}
		}
		it.Picks = append(it.Picks, pick)
	}
	return it
}

func runInbox(args []string, asJSON bool, stdout, stderr io.Writer, d Deps) int {
	flags, rest, err := splitFlags(args, map[string]bool{"all": false})
	if err != nil || len(rest) != 0 {
		if err != nil {
			fmt.Fprintf(stderr, "!! %v\n", err)
		}
		fmt.Fprintln(stderr, "使い方: bin/fge dashboard inbox [--json] [--all]")
		return exitBadUsage
	}
	_, all := flags["all"]
	roots, err := d.roots(stderr)
	if err != nil {
		fmt.Fprintf(stderr, "!! %v\n", err)
		return exitProblem
	}
	found := posts.Inbox(posts.List(roots.PostsDir()), roots.Worktree, all)
	// WhyNot: 新しい順で出さない — 古い返事から直すと、後の返事が前の返事を打ち消した時に読み違えない。
	sort.SliceStable(found, func(i, j int) bool { return found[i].ID < found[j].ID })
	items := make([]InboxItem, 0, len(found))
	for _, p := range found {
		items = append(items, inboxItem(p))
	}
	if asJSON {
		b, _ := json.MarshalIndent(items, "", "  ")
		fmt.Fprintln(stdout, string(b))
		return exitDone
	}
	if len(items) == 0 {
		scope := "この worktree の post"
		if all {
			scope = "全部の post"
		}
		fmt.Fprintf(stdout, "[dashboard] %s に新しい返事はありません（置き場: %s）\n", scope, roots.PostsDir())
		return exitDone
	}
	fmt.Fprintf(stdout, "[dashboard] 返事 %d 件（直したら bin/fge dashboard resolve <id>@<at> で片付ける）\n", len(items))
	for _, it := range items {
		printInboxItem(stdout, it)
	}
	return exitDone
}

func printInboxItem(stdout io.Writer, it InboxItem) {
	title := it.Title
	if title == "" {
		title = "（題なし）"
	}
	fmt.Fprintf(stdout, "\n== %s  %s\n", it.Ref, title)
	fmt.Fprintf(stdout, "  返事の時刻: %s\n", it.Reply.At)
	for _, p := range it.Picks {
		label := ""
		if p.Label != "" {
			label = "（" + p.Label + "）"
		}
		fmt.Fprintf(stdout, "  選んだ案: %s=%s%s\n", p.Section, p.Option, label)
		for _, m := range p.Media {
			fmt.Fprintf(stdout, "    %s\n", m)
		}
	}
	if c := strings.TrimSpace(it.Reply.Comment); c != "" {
		fmt.Fprintln(stdout, "  コメント:")
		for _, line := range strings.Split(c, "\n") {
			fmt.Fprintf(stdout, "    %s\n", line)
		}
	}
	fmt.Fprintf(stdout, "  post: %s\n", filepath.Join(it.Dir, posts.PostFile))
}

func runResolve(args []string, stdout, stderr io.Writer, d Deps) int {
	if len(args) != 1 || strings.HasPrefix(args[0], "--") {
		fmt.Fprintln(stderr, "使い方: bin/fge dashboard resolve <id>@<at>   （inbox が出す形。@<at> を省くと今の返事を片付ける）")
		return exitBadUsage
	}
	roots, err := d.roots(stderr)
	if err != nil {
		fmt.Fprintf(stderr, "!! %v\n", err)
		return exitProblem
	}
	id, at := posts.ParseRef(args[0])
	p, err := posts.MarkResolved(roots.PostsDir(), id, at)
	var stale *posts.StaleError
	if errors.As(err, &stale) {
		fmt.Fprintf(stderr, "!! %s を片付けません: 拾った後に人が返事を出し直しています。新しい返事を読んで直してから %s で片付けてください\n", id, stale.Post.Ref())
		printInboxItem(stderr, inboxItem(stale.Post))
		return exitProblem
	}
	if err != nil {
		fmt.Fprintf(stderr, "!! %s を片付けられません（置き場 %s）: %v\n", id, roots.PostsDir(), err)
		return exitProblem
	}
	fmt.Fprintf(stdout, "[dashboard] %s を片付けました\n", args[0])
	if at == "" && p.Reply != nil {
		// WhyNot: @<at> を省いた時に黙らない — 片付けたのが自分の読んだ返事かを、AI がここで見比べられるようにする。
		fmt.Fprintf(stdout, "  片付けた返事: %s「%s」\n", p.Reply.At, commentHead(p.Reply.Comment))
	}
	return exitDone
}

// runGame はこのゲームの頁だけを base の下で立てる（全体の fge が子として --port 0 --no-open --base /<名前>/ で起こす）。
func runGame(base string, port int, noOpen bool, stdout, stderr io.Writer, d Deps) int {
	if !strings.HasPrefix(base, "/") || !strings.HasSuffix(base, "/") || strings.Contains(base, "..") {
		fmt.Fprintln(stderr, "!! --base は / で始まり / で終わる形（例: /mygame/）")
		return exitBadUsage
	}
	roots, err := d.roots(stderr)
	if err != nil {
		fmt.Fprintf(stderr, "!! %v\n", err)
		return exitProblem
	}
	if _, err := os.Stat(filepath.Join(roots.GameRoot, "flix.toml")); err != nil {
		fmt.Fprintln(stderr, "!! ゲームのフォルダ（flix.toml のある所）で打ってください")
		return exitProblem
	}
	name := strings.Trim(base, "/")
	if name == "" {
		name = filepath.Base(roots.MainRoot)
	}
	ln, err := listenLocal(port)
	if err != nil {
		fmt.Fprintf(stderr, "!! 127.0.0.1 で待てません: %v\n", err)
		return exitProblem
	}
	actual := ln.Addr().(*net.TCPAddr).Port
	gs := NewGameServer(actual, base, name, roots, d.now)
	fmt.Fprintf(stdout, "%s127.0.0.1:%d\n", ListenPrefix, actual)
	fmt.Fprintf(stdout, "[fge dashboard] %s で %s の頁を出しています（Ctrl-C で止める）\n", localURL(actual, base), name)
	if !noOpen {
		openOrPrint(stdout, d, localURL(actual, base), false)
	}
	if d.WatchParent != nil {
		d.WatchParent()
	}
	if err := d.Serve(ln, gs); err != nil {
		fmt.Fprintf(stderr, "!! %v\n", err)
		return exitProblem
	}
	return exitDone
}

// exitWhenStdinCloses は stdin が親からの pipe の時だけ、閉じたら止まる。
// WhyNot: 端末や /dev/null の stdin では見ない — 人が手で立てた時に、すぐ止まる・止まらないが打ち方で変わる。
func exitWhenStdinCloses() {
	info, err := os.Stdin.Stat()
	if err != nil || info.Mode()&os.ModeNamedPipe == 0 {
		return
	}
	go func() {
		io.Copy(io.Discard, os.Stdin)
		os.Exit(0)
	}()
}

// commentHead は自由文の頭の 1 行（長ければ 40 字で切る）。
func commentHead(c string) string {
	line, _, _ := strings.Cut(strings.TrimSpace(c), "\n")
	if r := []rune(line); len(r) > 40 {
		return string(r[:40]) + "…"
	}
	return line
}
