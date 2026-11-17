package tape

import (
	"bytes"
	"fmt"
	"html"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// DefaultKeepVideos は同じゲームの同じ flow で、動画を残す版の数。
const DefaultKeepVideos = 1

// KeepAllVideos を PublishOptions.KeepVideos に渡すと動画を消さない。
const KeepAllVideos = -1

const videoGoneMarker = "<!--fge-video-gone-->"

var (
	noticeRe     = regexp.MustCompile(`(?s)` + videoGoneMarker + `<div.*?</div>`)
	bodyRe       = regexp.MustCompile(`(?i)<body[^>]*>`)
	videoNamesRe = regexp.MustCompile(`^video(-phone)?\.mp4$`)
)

// PrunedVideo は動画を外したテープ 1 本。
type PrunedVideo struct {
	Name   string   // 乱数のフォルダ名
	Folder string   // 空なら 1 本だけ置いた物
	Files  []string // 外した動画
	Bytes  int64
}

// groupKey は「同じ物の別の版」を束ねる鍵。ゲームと、置いた flow の集まり（分岐は組で 1 つ）。
// WhyNot: 題名や commit では束ねない — 版ごとに変わるので、束ねる前に別物になる。
func groupKey(e IndexEntry) string {
	flows := make([]string, 0, len(e.Tapes))
	for _, t := range e.Tapes {
		flows = append(flows, t.Flow)
	}
	sort.Strings(flows)
	return e.GameRepo + "\x00" + e.Game + "\x00" + strings.Join(flows, "\x00")
}

// pruneOldVideos は entries（新しい順）を鍵ごとに束ね、新しい keep 版より古い版の動画を site から消し、
// 頁へ「動画は消えた・最新はこちら」を足す。頁・tape.json・strip は残す（渡した URL が開けなくなるのを避ける）。
// 動画が既に無い頁は触らない（何度流しても同じ結果になる）。
func pruneOldVideos(site string, entries []IndexEntry, keep int) ([]PrunedVideo, error) {
	if keep == 0 {
		keep = DefaultKeepVideos
	}
	if keep < 0 {
		return nil, nil
	}
	seen := map[string][]IndexEntry{}
	var order []string
	for _, e := range entries {
		k := groupKey(e)
		if _, ok := seen[k]; !ok {
			order = append(order, k)
		}
		seen[k] = append(seen[k], e)
	}
	var out []PrunedVideo
	for _, k := range order {
		group := seen[k]
		if len(group) <= keep {
			continue
		}
		latest := group[0]
		for _, old := range group[keep:] {
			for _, t := range old.Tapes {
				dir := filepath.Join(site, DocsDir, TapesDir, old.Name, t.Folder)
				p, err := pruneTapeVideos(dir, old.Name, t.Folder, latestURLFor(latest, t.Folder))
				if err != nil {
					return nil, err
				}
				if len(p.Files) > 0 {
					out = append(out, p)
				}
			}
		}
	}
	return out, nil
}

// latestURLFor は latest の中で folder と同じ名前のテープの URL（無ければ先頭）。
func latestURLFor(latest IndexEntry, folder string) string {
	for _, t := range latest.Tapes {
		if t.Folder == folder {
			return t.URL
		}
	}
	if len(latest.Tapes) > 0 {
		return latest.Tapes[0].URL
	}
	return ""
}

func pruneTapeVideos(dir, name, folder, latestURL string) (PrunedVideo, error) {
	p := PrunedVideo{Name: name, Folder: folder}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return p, nil
	}
	for _, e := range ents {
		if e.IsDir() || !videoNamesRe.MatchString(e.Name()) {
			continue
		}
		path := filepath.Join(dir, e.Name())
		if st, err := os.Stat(path); err == nil {
			p.Bytes += st.Size()
		}
		if err := os.Remove(path); err != nil {
			return p, err
		}
		p.Files = append(p.Files, e.Name())
	}
	page, err := os.ReadFile(filepath.Join(dir, IndexFile))
	if err != nil {
		return p, nil
	}
	// WhyNot: 動画を外し終えた頁でも知らせのリンクは付け直す — 前の「最新」もやがて古い版になり、リンク先の動画が消える。
	if len(p.Files) == 0 && !bytes.Contains(page, []byte(videoGoneMarker)) {
		return p, nil
	}
	page, err = AddVideoGoneNotice(page, latestURL)
	if err != nil {
		return p, err
	}
	return p, os.WriteFile(filepath.Join(dir, IndexFile), page, 0o644)
}

// AddVideoGoneNotice は <body> の直後に、動画を消した知らせと最新の版へのリンクを足す（既にあれば置き換える）。
func AddVideoGoneNotice(page []byte, latestURL string) ([]byte, error) {
	page = noticeRe.ReplaceAll(page, nil)
	loc := bodyRe.FindIndex(page)
	if loc == nil {
		return nil, fmt.Errorf("index.html に <body> が無い（bin/fge tape --dir が書いた頁か確かめる）")
	}
	msg := "この版の動画は古いので消した。"
	if latestURL != "" {
		msg += fmt.Sprintf(` 最新の版は <a href="%s" style="color:#9cf">こちら</a>。`, html.EscapeString(latestURL))
	}
	notice := videoGoneMarker + `<div style="position:fixed;top:0;left:0;right:0;z-index:99999;padding:6px 10px;background:#333;color:#fff;font:13px sans-serif;text-align:center">` + msg + `</div>`
	var out bytes.Buffer
	out.Write(page[:loc[1]])
	out.WriteString(notice)
	out.Write(page[loc[1]:])
	return out.Bytes(), nil
}

func logPruned(log io.Writer, ps []PrunedVideo, keep int) {
	if keep == 0 {
		keep = DefaultKeepVideos
	}
	var total int64
	for _, p := range ps {
		total += p.Bytes
		where := p.Name
		if p.Folder != "" {
			where += "/" + p.Folder
		}
		fmt.Fprintf(log, "動画を外す: %s  %s（%.1f MB・頁は残す）\n", where, strings.Join(p.Files, " "), float64(p.Bytes)/1e6)
	}
	if len(ps) == 0 {
		fmt.Fprintf(log, "動画を外す: 無し（同じゲームの同じ flow で、新しい %d 版より古い版の動画は無い）\n", keep)
		return
	}
	fmt.Fprintf(log, "動画を外す: 合わせて %.1f MB（同じゲームの同じ flow の新しい %d 版だけ残す）\n", float64(total)/1e6, keep)
}
