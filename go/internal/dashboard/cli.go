package dashboard

import (
	"encoding/json"
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

func (d Deps) roots() (posts.Roots, error) {
	wd, err := d.Getwd()
	if err != nil {
		return posts.Roots{}, err
	}
	return posts.Resolve(wd), nil
}

// splitFlags は引数を、名前つきの旗（値を取る物は takesValue）と残りに分ける。
func splitFlags(args []string, takesValue map[string]bool) (map[string]string, []string, error) {
	flags := map[string]string{}
	var rest []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "--") {
			rest = append(rest, a)
			continue
		}
		name, val, hasVal := strings.Cut(strings.TrimPrefix(a, "--"), "=")
		if takesValue[name] && !hasVal {
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
	flags, rest, err := splitFlags(args, map[string]bool{"author": true})
	if err != nil || len(rest) != 1 {
		fmt.Fprintln(stderr, "使い方: bin/fge dashboard post <post.json> [--author <名前>] [--json]")
		return exitBadUsage
	}
	roots, err := d.roots()
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
	fmt.Fprintf(stdout, "[dashboard] post を置きました: %s\n", id)
	fmt.Fprintf(stdout, "  置き場: %s\n", dir)
	fmt.Fprintf(stdout, "  頁:     %s（人が fge dashboard を立てている時）\n", link)
	if !listed {
		fmt.Fprintf(stdout, "  このゲームはワークスペースの一覧にまだありません。人が %s で fge dashboard を打つと足されます\n", roots.MainRoot)
	}
	fmt.Fprintln(stdout, "  人の返事は bin/fge dashboard inbox で拾う")
	return exitDone
}

// InboxItem は inbox の 1 件（--json の形）。
type InboxItem struct {
	ID     string       `json:"id"`
	Title  string       `json:"title"`
	Dir    string       `json:"dir"`
	Origin posts.Origin `json:"origin"`
	Reply  posts.Reply  `json:"reply"`
}

func runInbox(args []string, asJSON bool, stdout, stderr io.Writer, d Deps) int {
	flags, rest, err := splitFlags(args, nil)
	if err != nil || len(rest) != 0 {
		fmt.Fprintln(stderr, "使い方: bin/fge dashboard inbox [--json] [--all]")
		return exitBadUsage
	}
	_, all := flags["all"]
	roots, err := d.roots()
	if err != nil {
		fmt.Fprintf(stderr, "!! %v\n", err)
		return exitProblem
	}
	found := posts.Inbox(posts.List(roots.PostsDir()), roots.Worktree, all)
	// WhyNot: 新しい順のまま出さない — 返事は古い物から順に片付けると、後の返事が前の返事を上書きする意図を読み違えない。
	sort.SliceStable(found, func(i, j int) bool { return found[i].ID < found[j].ID })
	items := make([]InboxItem, 0, len(found))
	for _, p := range found {
		items = append(items, InboxItem{ID: p.ID, Title: p.Title, Dir: p.Dir, Origin: p.Origin, Reply: *p.Reply})
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
	fmt.Fprintf(stdout, "[dashboard] 返事 %d 件（直したら bin/fge dashboard resolve <id> で片付ける）\n", len(items))
	for _, it := range items {
		title := it.Title
		if title == "" {
			title = "（題なし）"
		}
		fmt.Fprintf(stdout, "\n== %s  %s\n", it.ID, title)
		fmt.Fprintf(stdout, "  返事の時刻: %s\n", it.Reply.At)
		if len(it.Reply.Picks) > 0 {
			keys := make([]string, 0, len(it.Reply.Picks))
			for k := range it.Reply.Picks {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			var picks []string
			for _, k := range keys {
				picks = append(picks, k+"="+it.Reply.Picks[k])
			}
			fmt.Fprintf(stdout, "  選んだ案: %s\n", strings.Join(picks, " "))
		}
		if c := strings.TrimSpace(it.Reply.Comment); c != "" {
			fmt.Fprintln(stdout, "  コメント:")
			for _, line := range strings.Split(c, "\n") {
				fmt.Fprintf(stdout, "    %s\n", line)
			}
		}
		fmt.Fprintf(stdout, "  post: %s\n", filepath.Join(it.Dir, posts.PostFile))
	}
	return exitDone
}

func runResolve(args []string, stdout, stderr io.Writer, d Deps) int {
	if len(args) != 1 || strings.HasPrefix(args[0], "--") {
		fmt.Fprintln(stderr, "使い方: bin/fge dashboard resolve <id>")
		return exitBadUsage
	}
	roots, err := d.roots()
	if err != nil {
		fmt.Fprintf(stderr, "!! %v\n", err)
		return exitProblem
	}
	if err := posts.MarkResolved(roots.PostsDir(), args[0]); err != nil {
		fmt.Fprintf(stderr, "!! %s を片付けられません（置き場 %s）: %v\n", args[0], roots.PostsDir(), err)
		return exitProblem
	}
	fmt.Fprintf(stdout, "[dashboard] %s を片付けました\n", args[0])
	return exitDone
}

// runGame はこのゲームの頁だけを base の下で立てる（全体の fge が子として --port 0 --no-open --base /<名前>/ で起こす）。
func runGame(base string, port int, noOpen bool, stdout, stderr io.Writer, d Deps) int {
	if !strings.HasPrefix(base, "/") || !strings.HasSuffix(base, "/") || strings.Contains(base, "..") {
		fmt.Fprintln(stderr, "!! --base は / で始まり / で終わる形（例: /mygame/）")
		return exitBadUsage
	}
	wd, err := d.Getwd()
	if err != nil {
		fmt.Fprintf(stderr, "!! %v\n", err)
		return exitProblem
	}
	if _, err := os.Stat(filepath.Join(posts.Resolve(wd).GameRoot, "flix.toml")); err != nil {
		fmt.Fprintln(stderr, "!! ゲームのフォルダ（flix.toml のある所）で打ってください")
		return exitProblem
	}
	roots := posts.Resolve(wd)
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
