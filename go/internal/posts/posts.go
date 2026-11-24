package posts

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/proposal"
)

const (
	// PostFile は AI が書く物（proposal.json の形に author と origin を足した物）。
	PostFile = "post.json"
	// ReplyFile は人の最新の返事。
	ReplyFile = "reply.json"
	// RepliesDir は出し直す前の返事を残す所。
	RepliesDir = "replies"
	// ResolvedFile は片付けた返事の at を書いたファイル。中身が今の reply.json の at と同じ時だけ片付いた post。
	ResolvedFile = "resolved"
)

// replyStamp は replies/<at>.json の名前に使う時刻の形。
// WhyNot: RFC3339 のまま名前にしない — `:` は Windows のファイル名に使えない。
// WhyNot: 秒で切らない — 1 秒の間に 2 回送ると同じ名前になる。
const replyStamp = "20060102T150405.000000000"

var idRe = regexp.MustCompile(`^[0-9]{8}-[0-9]{6}-[a-z0-9-]+$`)

// Origin は post を書いた所。
type Origin struct {
	Branch   string `json:"branch"`
	Worktree string `json:"worktree"`
}

// Reply は reply.json の形。
type Reply struct {
	Version int               `json:"version"`
	At      string            `json:"at"`
	Picks   map[string]string `json:"picks"`
	Comment string            `json:"comment"`
}

// Post は置き場の post 1 つの見出し。
type Post struct {
	ID       string    `json:"id"`
	Dir      string    `json:"dir"`
	Title    string    `json:"title"`
	Lead     string    `json:"lead,omitempty"`
	Author   string    `json:"author,omitempty"`
	Origin   Origin    `json:"origin"`
	Choose   bool      `json:"choose"`
	Images   []string  `json:"images"`
	Created  time.Time `json:"created"`
	Reply    *Reply    `json:"reply,omitempty"`
	Resolved bool      `json:"resolved"`
	// Manifest は読んだ post.json（JSON には出さない）。
	Manifest *proposal.Manifest `json:"-"`
}

// Ref は inbox が出し resolve が受ける「<id>@<返事の at>」（返事が無ければ id だけ）。
func (p Post) Ref() string {
	if p.Reply == nil {
		return p.ID
	}
	return p.ID + "@" + p.Reply.At
}

// ValidID は id が置き場の 1 つ下のフォルダ名として安全な形か。
func ValidID(id string) bool { return idRe.MatchString(id) }

// CreateOptions は Create の指定。
type CreateOptions struct {
	PostsDir string
	// Manifest は AI が書いた post.json（proposal.json の形）のパス。
	Manifest string
	// RepoRoot は素材を許す根（この下の外の素材は止める）。
	RepoRoot string
	Author   string
	Origin   Origin
	Now      time.Time
}

// Create は manifest と素材を posts/<id>/ へ写し、id を返す。
func Create(o CreateOptions) (string, error) {
	data, err := os.ReadFile(o.Manifest)
	if err != nil {
		return "", err
	}
	m, errs := proposal.ParseManifest(filepath.Base(o.Manifest), data)
	if len(errs) > 0 {
		return "", errors.New(strings.Join(errs, "\n"))
	}
	base := filepath.Dir(RealPath(o.Manifest))
	root := RealPath(o.RepoRoot)
	sources := map[string]string{}
	var order []string
	for _, src := range m.MediaSources() {
		full := filepath.FromSlash(src)
		if !filepath.IsAbs(full) {
			full = filepath.Join(base, full)
		}
		info, err := os.Stat(full)
		if err != nil || !info.Mode().IsRegular() {
			return "", fmt.Errorf("素材がありません: %s", src)
		}
		if !Inside(root, RealPath(full)) {
			return "", fmt.Errorf("素材がリポの根（%s）の外にあります: %s", root, src)
		}
		sources[src] = RealPath(full)
		order = append(order, src)
	}
	if err := os.MkdirAll(o.PostsDir, 0o755); err != nil {
		return "", err
	}
	id, dir, err := makePostDir(o.PostsDir, o.Now, m.Title())
	if err != nil {
		return "", err
	}
	ok := false
	defer func() {
		if !ok {
			os.RemoveAll(dir)
		}
	}()
	rename := map[string]string{}
	copied := map[string]string{}
	// WhyNot: 名前の重なりを字のまま見ない — macOS と Windows のファイルシステムは大文字小文字を区別せず、A.png が a.png を上書きする。
	taken := map[string]bool{PostFile: true, ReplyFile: true, RepliesDir: true, ResolvedFile: true}
	for _, src := range order {
		from := sources[src]
		if name, done := copied[from]; done {
			rename[src] = name
			continue
		}
		name := freeName(safeName(filepath.Base(from)), taken)
		taken[strings.ToLower(name)] = true
		if err := copyFile(from, filepath.Join(dir, name)); err != nil {
			return "", err
		}
		copied[from] = name
		rename[src] = name
	}
	m.RewriteMedia(rename)
	if o.Author != "" {
		if err := m.Set("author", o.Author); err != nil {
			return "", err
		}
	}
	if err := m.Set("origin", o.Origin); err != nil {
		return "", err
	}
	if err := writeAtomic(filepath.Join(dir, PostFile), m.JSON()); err != nil {
		return "", err
	}
	ok = true
	return id, nil
}

var (
	slugDropRe = regexp.MustCompile(`[^a-z0-9]+`)
	unsafeRe   = regexp.MustCompile(`[^A-Za-z0-9._-]+`)
)

// safeName は写した素材の名前を [A-Za-z0-9._-] にそろえる。
// WhyNot: 元の名前のまま写さない — 空白・#・? を含む名前は頁の URL で別の物を指し、頭の . は隠しファイルになる。
func safeName(name string) string {
	ext := filepath.Ext(name)
	stem := strings.Trim(unsafeRe.ReplaceAllString(strings.TrimSuffix(name, ext), "-"), "-.")
	ext = unsafeRe.ReplaceAllString(ext, "")
	if stem == "" {
		stem = "media"
	}
	return stem + ext
}

// slug は題から作る短い名前（英数字だけを拾い、無ければ post）。
func slug(title string) string {
	s := strings.Trim(slugDropRe.ReplaceAllString(strings.ToLower(title), "-"), "-")
	if len(s) > 24 {
		s = strings.TrimRight(s[:24], "-")
	}
	if s == "" {
		return "post"
	}
	return s
}

// makePostDir は id のフォルダを os.Mkdir で作る。同じ id が既にあれば -2 から番号を付けて作り直す。
func makePostDir(postsDir string, now time.Time, title string) (string, string, error) {
	stem := now.Format("20060102-150405") + "-" + slug(title)
	for i := 1; i < 1000; i++ {
		id := stem
		if i > 1 {
			id = stem + "-" + strconv.Itoa(i)
		}
		dir := filepath.Join(postsDir, id)
		err := os.Mkdir(dir, 0o755)
		if err == nil {
			return id, dir, nil
		}
		if !os.IsExist(err) {
			return "", "", err
		}
	}
	return "", "", fmt.Errorf("%s の下に %s を作れません", postsDir, stem)
}

// freeName は taken とぶつからない名前（ぶつかれば拡張子の前に -2 -3 を付ける）。
func freeName(name string, taken map[string]bool) string {
	if !taken[strings.ToLower(name)] {
		return name
	}
	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	for i := 2; ; i++ {
		n := stem + "-" + strconv.Itoa(i) + ext
		if !taken[strings.ToLower(n)] {
			return n
		}
	}
}

// Inside は path が root の下（root そのものは含まない）か。どちらも symlink を辿った後のパスで渡す。
func Inside(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}

func copyFile(from, to string) error {
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(to, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// writeAtomic は path を書く。読み手は前の中身か新しい中身のどちらかだけを見る。
func writeAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	name := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(name)
		return err
	}
	if err := renameRetry(name, path); err != nil {
		os.Remove(name)
		return err
	}
	return nil
}

// renameRetry は Windows で rename が落ちた時だけ、短く数回やり直す。
// WhyNot: 1 回で諦めない — Windows では人のブラウザやウイルス検査が reply.json を開いている間、上書きの rename が共有違反で落ちる。
func renameRetry(from, to string) error {
	err := os.Rename(from, to)
	for i := 0; err != nil && runtime.GOOS == "windows" && i < 5; i++ {
		time.Sleep(time.Duration(20*(i+1)) * time.Millisecond)
		err = os.Rename(from, to)
	}
	return err
}

// Load は posts/<id> を読む。post.json が無い（書きかけ・消した）フォルダは os.ErrNotExist。
func Load(postsDir, id string) (Post, *proposal.Manifest, error) {
	if !ValidID(id) {
		return Post{}, nil, os.ErrNotExist
	}
	dir := filepath.Join(postsDir, id)
	data, err := os.ReadFile(filepath.Join(dir, PostFile))
	if err != nil {
		return Post{}, nil, err
	}
	m, errs := proposal.ParseManifest(PostFile, data)
	if len(errs) > 0 {
		return Post{}, nil, errors.New(strings.Join(errs, "\n"))
	}
	var extra struct {
		Origin Origin `json:"origin"`
	}
	json.Unmarshal(data, &extra)
	p := Post{
		ID: id, Dir: dir, Title: m.Title(), Lead: m.Lead(), Author: m.Author(), Origin: extra.Origin,
		Choose: m.HasChoices(), Images: m.Images(), Created: createdOf(id, dir), Manifest: m,
	}
	if p.Images == nil {
		p.Images = []string{}
	}
	if r, err := readReply(filepath.Join(dir, ReplyFile)); err == nil {
		p.Reply = &r
	}
	if done, err := os.ReadFile(filepath.Join(dir, ResolvedFile)); err == nil {
		// WhyNot: resolved があるだけで片付いたと見ない — AI が拾った後に人が出し直した返事まで片付き、誰にも届かない。
		p.Resolved = p.Reply == nil || strings.TrimSpace(string(done)) == p.Reply.At
	}
	return p, m, nil
}

func createdOf(id, dir string) time.Time {
	if t, err := time.ParseInLocation("20060102-150405", id[:15], time.Local); err == nil {
		return t
	}
	info, err := os.Stat(dir)
	if err != nil {
		return time.Time{}
	}
	return info.ModTime()
}

func readReply(path string) (Reply, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Reply{}, err
	}
	var r Reply
	if err := json.Unmarshal(data, &r); err != nil {
		return Reply{}, fmt.Errorf("%s を読めません: %w", path, err)
	}
	return r, nil
}

// List は置き場の post を新しい順に返す（読めない post は飛ばす）。
func List(postsDir string) []Post {
	entries, err := os.ReadDir(postsDir)
	if err != nil {
		return []Post{}
	}
	out := []Post{}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if p, _, err := Load(postsDir, e.Name()); err == nil {
			out = append(out, p)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].ID > out[j].ID })
	return out
}

// Inbox は返事があり片付いていない post。all でなければ origin の worktree が worktree に合う物だけ。
func Inbox(list []Post, worktree string, all bool) []Post {
	out := []Post{}
	for _, p := range list {
		if p.Reply == nil || p.Resolved {
			continue
		}
		if !all && !SamePath(p.Origin.Worktree, worktree) {
			continue
		}
		out = append(out, p)
	}
	return out
}

// WriteReply は reply.json を書く。前の reply.json は replies/<at>.json へ写してから、新しい物で上から差し替える。
func WriteReply(postsDir, id string, picks map[string]string, comment string, now time.Time) (Reply, error) {
	if _, _, err := Load(postsDir, id); err != nil {
		return Reply{}, err
	}
	dir := filepath.Join(postsDir, id)
	if picks == nil {
		picks = map[string]string{}
	}
	// WhyNot: at を秒で切らない — 1 秒の間に出し直すと前の返事と同じ at になり、resolve が新しい返事まで片付ける。
	r := Reply{Version: 1, At: now.Format(time.RFC3339Nano), Picks: picks, Comment: comment}
	cur := filepath.Join(dir, ReplyFile)
	if old, err := os.ReadFile(cur); err == nil {
		if err := keepOldReply(dir, old, now); err != nil {
			return Reply{}, err
		}
	} else if !os.IsNotExist(err) {
		return Reply{}, err
	}
	data, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return Reply{}, err
	}
	// WhyNot: 前の reply.json を消してから書かない — 消えている間に inbox を打つと「返事なし」に見える。
	if err := writeAtomic(cur, append(data, '\n')); err != nil {
		return Reply{}, err
	}
	return r, nil
}

// keepOldReply は前の返事の中身を replies/<at>.json に写す（名前は O_EXCL で取り、ぶつかれば -2 から番号を付ける）。
func keepOldReply(dir string, old []byte, now time.Time) error {
	var r Reply
	at := now
	if json.Unmarshal(old, &r) == nil {
		if t, err := time.Parse(time.RFC3339Nano, r.At); err == nil {
			at = t
		}
	}
	if err := os.MkdirAll(filepath.Join(dir, RepliesDir), 0o755); err != nil {
		return err
	}
	stem := at.Format(replyStamp)
	for i := 1; i < 1000; i++ {
		name := stem + ".json"
		if i > 1 {
			name = stem + "-" + strconv.Itoa(i) + ".json"
		}
		f, err := os.OpenFile(filepath.Join(dir, RepliesDir, name), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
		if os.IsExist(err) {
			continue
		}
		if err != nil {
			return err
		}
		if _, err := f.Write(old); err != nil {
			f.Close()
			return err
		}
		return f.Close()
	}
	return fmt.Errorf("%s の下に %s を作れません", RepliesDir, stem)
}

// StaleError は resolve が受けた返事より新しい返事が来ている時の誤り。
type StaleError struct {
	Post Post
}

func (e *StaleError) Error() string {
	return "片付ける前に新しい返事が来ています（" + e.Post.Ref() + "）"
}

// ParseRef は「<id>@<at>」を id と at に分ける（@ が無ければ at は空）。
func ParseRef(ref string) (string, string) {
	id, at, _ := strings.Cut(ref, "@")
	return id, at
}

// MarkResolved は resolved に今の返事の at を書く。at を渡した時は、それが今の返事の at と違えば *StaleError で断る。
func MarkResolved(postsDir, id, at string) (Post, error) {
	p, _, err := Load(postsDir, id)
	if err != nil {
		return Post{}, err
	}
	cur := ""
	if p.Reply != nil {
		cur = p.Reply.At
	}
	if at != "" && at != cur {
		return p, &StaleError{Post: p}
	}
	if err := writeAtomic(filepath.Join(postsDir, id, ResolvedFile), []byte(cur+"\n")); err != nil {
		return p, err
	}
	p.Resolved = true
	return p, nil
}

// Signature は置き場の変わり目を見分ける短い文字列（post の数と、post.json・reply.json・resolved の最新の時刻）。
func Signature(postsDir string) string {
	entries, err := os.ReadDir(postsDir)
	if err != nil {
		return "0"
	}
	n, latest := 0, int64(0)
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		n++
		for _, f := range []string{"", PostFile, ReplyFile, ResolvedFile} {
			if info, err := os.Stat(filepath.Join(postsDir, e.Name(), f)); err == nil && info.ModTime().UnixNano() > latest {
				latest = info.ModTime().UnixNano()
			}
		}
	}
	return strconv.Itoa(n) + "-" + strconv.FormatInt(latest, 36)
}
