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

const (
	videoGoneMarker = "<!--fge-video-gone-->"
	videoGoneEnd    = "<!--/fge-video-gone-->"
)

var (
	// 前の形（バナーの <div> 1 つ・終わりの印が無い）も拾う。
	noticeRe     = regexp.MustCompile(`(?s)` + videoGoneMarker + `(?:.*?` + videoGoneEnd + `|<div[^>]*>[^<]*(?:<a [^>]*>[^<]*</a>[^<]*)?</div>)`)
	bodyRe       = regexp.MustCompile(`(?i)<body[^>]*>`)
	videoNamesRe = regexp.MustCompile(`^video(-phone)?\.mp4$`)
)

// PrunedVideo は動画を外したテープ 1 本。
type PrunedVideo struct {
	Name   string   // 乱数のフォルダ名
	Folder string   // 空なら 1 本だけ置いた物
	Files  []string // 外した動画
	Bytes  int64
	// Renoticed は動画を前の回に外し終えていて、知らせだけを書き換えた（前の形のバナーを modal に替えた・最新のリンクを付け直した）。
	Renoticed bool
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
// 動画が既に無く知らせも今の形の頁は書き換えない（何度流しても同じ結果になる）。
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
				if len(p.Files) > 0 || p.Renoticed {
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
	before := page
	page, err = AddVideoGoneNotice(page, latestURL)
	if err != nil {
		return p, err
	}
	if bytes.Equal(before, page) {
		return p, nil
	}
	p.Renoticed = len(p.Files) == 0
	return p, os.WriteFile(filepath.Join(dir, IndexFile), page, 0o644)
}

// AddVideoGoneNotice は <body> の直後に、動画を消した知らせ（画面の真ん中の modal）と最新の版へのリンクを足す
// （既にあれば置き換える。前の形のバナーも同じ印で拾って置き換える）。
// 後ろの頁は暗く沈め、ボタンなどは disabled・残りは inert にし、キーは知らせの中の物だけ通す。
// WhyNot: バナーのまま頁を触れるようにしない — 動画が無いので、再生・頭出し・画面の切り替え・はじめから遊ぶのどれも動かない。
func AddVideoGoneNotice(page []byte, latestURL string) ([]byte, error) {
	page = noticeRe.ReplaceAll(page, nil)
	loc := bodyRe.FindIndex(page)
	if loc == nil {
		return nil, fmt.Errorf("index.html に <body> が無い（bin/fge tape --dir が書いた頁か確かめる）")
	}
	link := ""
	if latestURL != "" {
		link = fmt.Sprintf(`<a href="%s" style="display:inline-block;margin-top:24px;padding:14px 44px;border-radius:12px;background:#4a9eff;color:#fff;`+
			`font:bold clamp(18px,6.3vw,30px)/1.2 sans-serif;text-decoration:none">こちら</a>`, html.EscapeString(latestURL))
	}
	msg := "最新バージョンがあります。"
	if latestURL == "" {
		// WhyNot: リンクが無いのに「最新があります」と言わない — 行き先を示せず、閉じ込めただけになる。
		msg = "この版の動画は外しました。"
	}
	notice := videoGoneMarker +
		`<div id="fge-video-gone" role="alertdialog" aria-modal="true" aria-labelledby="fge-video-gone-msg" ` +
		`style="position:fixed;inset:0;z-index:2147483647;display:flex;align-items:center;justify-content:center;` +
		`padding:12px;box-sizing:border-box;background:rgba(0,0,0,.78);-webkit-backdrop-filter:blur(3px);backdrop-filter:blur(3px)">` +
		`<div style="width:min(100%,460px);box-sizing:border-box;padding:28px 16px;border-radius:16px;background:#1f2329;` +
		`box-shadow:0 12px 40px rgba(0,0,0,.6);color:#fff;text-align:center">` +
		`<p id="fge-video-gone-msg" style="margin:0;font:bold clamp(18px,6.3vw,30px)/1.4 sans-serif;word-break:keep-all">` + msg + `</p>` +
		link + `</div></div>` +
		`<script>(function(){var n=document.getElementById("fge-video-gone");` +
		`addEventListener("keydown",function(e){if(!n.contains(e.target))e.stopImmediatePropagation();},true);` +
		`function off(){for(var c of document.body.children){if(c!==n&&c.tagName!=="SCRIPT")c.inert=true;}` +
		`document.querySelectorAll("button,input,select,textarea").forEach(function(b){if(!n.contains(b))b.disabled=true;});` +
		`document.querySelectorAll("video,audio").forEach(function(v){v.pause();v.autoplay=false;});` +
		`var a=n.querySelector("a");if(a)a.focus();}` +
		`if(document.readyState==="loading")addEventListener("DOMContentLoaded",off);else off();})();</script>` +
		videoGoneEnd
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
	removed := 0
	for _, p := range ps {
		where := p.Name
		if p.Folder != "" {
			where += "/" + p.Folder
		}
		if p.Renoticed {
			fmt.Fprintf(log, "知らせを書き換える: %s（動画は外し済み・真ん中の知らせと最新へのリンクを今の形に）\n", where)
			continue
		}
		removed++
		total += p.Bytes
		fmt.Fprintf(log, "動画を外す: %s  %s（%.1f MB・頁は残す）\n", where, strings.Join(p.Files, " "), float64(p.Bytes)/1e6)
	}
	if removed == 0 {
		fmt.Fprintf(log, "動画を外す: 無し（同じゲームの同じ flow で、新しい %d 版より古い版の動画は無い）\n", keep)
		return
	}
	fmt.Fprintf(log, "動画を外す: 合わせて %.1f MB（同じゲームの同じ flow の新しい %d 版だけ残す）\n", float64(total)/1e6, keep)
}
