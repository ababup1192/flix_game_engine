package migrate

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/rendercache"
)

// 鍵を先に撮る（plans/novel-migrate-scale.md の D）: flow を「比べのコマは鍵だけ」で流し、基準と鍵の違うコマだけに PNG を用意する。
// PNG の出所は、基準の記録の同じ鍵のコマ → render-cache の同じ鍵 → 同じ鍵のほかのコマを 1 か所だけで塗って写す、の順。

// Paint* は FlowVideo が読む、層ごとに塗るコマの環境変数（字は FGE_VIDEO_PAINT と同じ）。
const (
	PaintWorldEnv = "MIGRATE_PAINT_WORLD"
	PaintAllEnv   = "MIGRATE_PAINT_ALL"
)

// paintEnvOf は層の名前（frames/<層>）の環境変数。
func paintEnvOf(layer string) string {
	if layer == "all" {
		return PaintAllEnv
	}
	return PaintWorldEnv
}

// paintCopy は塗った PNG（src）を、同じ鍵のコマ（dst）へ写す約束。
type paintCopy struct{ src, dst string }

// paintPlan は鍵を撮った後に要る事。Paint は flow → 層 → 塗るコマの番号、Copies は塗った後に写す物。
type paintPlan struct {
	Paint  map[string]map[string][]int
	Copies []paintCopy
	// 数（shoot.json と端末へ出す）。
	FromBaseline int `json:"fromBaseline"`
	FromCache    int `json:"fromCache"`
	FromSibling  int `json:"fromSibling"`
	Painted      int `json:"painted"`
	KeysOnly     int `json:"keysOnly"`
}

// planPaint は撮った記録 cur と基準 base を突き合わせ、PNG の要るコマを集め、基準と render-cache から写せる物はここで写す。
// cacheDir が空なら render-cache から写さない（使わない設定・verify で毎回塗る設定）。
func planPaint(cur, base *Side, cacheDir string) (*paintPlan, error) {
	plan := &paintPlan{Paint: map[string]map[string][]int{}}
	keys := newDrawKeys()
	baseByKey := map[string]string{}
	for _, flow := range sortedKeys(base.Flows) {
		for _, size := range sortedKeys(base.Flows[flow]) {
			t := base.Flows[flow][size]
			for _, f := range t.Frames {
				p := filepath.Join(t.Dir, f.File)
				if k := keys.of(t.Dir, f.File); validKey(k) && baseByKey[k] == "" && fileExists(p) {
					baseByKey[k] = p
				}
			}
		}
	}
	owner := map[string]string{}
	for _, flow := range sortedKeys(cur.Flows) {
		for _, size := range sortedKeys(cur.Flows[flow]) {
			nt := cur.Flows[flow][size]
			for _, f := range framesNeedingPNG(keys, base.Flows[flow][size], nt) {
				dst := filepath.Join(nt.Dir, f.File)
				k := keys.of(nt.Dir, f.File)
				src := ""
				switch {
				case !validKey(k):
				case baseByKey[k] != "":
					src = baseByKey[k]
					plan.FromBaseline++
				case cacheDir != "" && fileExists(cachedPNG(cacheDir, k)):
					src = cachedPNG(cacheDir, k)
					now := time.Now()
					_ = os.Chtimes(src, now, now)
					plan.FromCache++
				case owner[k] != "":
					plan.Copies = append(plan.Copies, paintCopy{owner[k], dst})
					plan.FromSibling++
					continue
				default:
					owner[k] = dst
				}
				if src != "" {
					if err := copyFile(src, dst); err != nil {
						return nil, err
					}
					continue
				}
				n, ok := frameNumber(f.File)
				if !ok {
					return nil, fmt.Errorf("%s: コマの名前 %s から番号を読めない（鍵を先に撮れない。--full で撮る）", nt.Dir, f.File)
				}
				layer := filepath.Base(filepath.Dir(f.File))
				if plan.Paint[flow] == nil {
					plan.Paint[flow] = map[string][]int{}
				}
				plan.Paint[flow][layer] = append(plan.Paint[flow][layer], n)
				plan.Painted++
			}
		}
	}
	for _, t := range allTapes(cur) {
		plan.KeysOnly += len(t.Frames)
	}
	plan.KeysOnly -= plan.FromBaseline + plan.FromCache + plan.FromSibling + plan.Painted
	return plan, nil
}

// framesNeedingPNG は新しい記録 nt のコマのうち、PNG が無く、基準の組の相手と鍵が同じでもない物（比べるか頁に並べるのに PNG が要る）。
// 組の作り方は diff と同じ（keyed）。
func framesNeedingPNG(keys *drawKeys, bt, nt *Tape) []Frame {
	var byA map[string]Frame
	if bt != nil {
		byA, _, _ = keyed(bt.Frames)
	}
	byB, orderB, _ := keyed(nt.Frames)
	paired := map[string]bool{}
	var out []Frame
	for _, pk := range orderB {
		fb := byB[pk]
		paired[fb.File] = true
		if fileExists(filepath.Join(nt.Dir, fb.File)) {
			continue
		}
		if fa, ok := byA[pk]; ok && sameKey(keys.of(bt.Dir, fa.File), keys.of(nt.Dir, fb.File)) && fileExists(filepath.Join(bt.Dir, fa.File)) {
			continue
		}
		out = append(out, fb)
	}
	for _, f := range nt.Frames {
		if !paired[f.File] && !fileExists(filepath.Join(nt.Dir, f.File)) {
			out = append(out, f)
		}
	}
	return out
}

func allTapes(s *Side) []*Tape {
	var out []*Tape
	for _, flow := range sortedKeys(s.Flows) {
		for _, size := range sortedKeys(s.Flows[flow]) {
			out = append(out, s.Flows[flow][size])
		}
	}
	return out
}

// cachedPNG は render-cache の置き場の 1 枚（engine の RenderCache と同じ <鍵の頭 2 字>/<鍵>.png）。
func cachedPNG(dir, key string) string {
	return filepath.Join(dir, key[:2], key+".png")
}

// cacheDirForCopy は鍵で写してよい render-cache の置き場（verify は毎回塗って突き合わせる設定なので写さない）。
func cacheDirForCopy() string {
	if strings.HasPrefix(os.Getenv("FGE_RENDER_CACHE"), "verify") {
		return ""
	}
	return rendercache.Dir()
}

// frameRanges は番号の列を FGE_VIDEO_PAINT の字（frames:1-3,7-7）にする。
func frameRanges(ns []int) string {
	s := append([]int{}, ns...)
	sort.Ints(s)
	var parts []string
	for i := 0; i < len(s); {
		j := i
		for j+1 < len(s) && s[j+1] <= s[j]+1 {
			j++
		}
		parts = append(parts, strconv.Itoa(s[i])+"-"+strconv.Itoa(s[j]))
		i = j + 1
	}
	return "frames:" + strings.Join(parts, ",")
}

// paintEnv は 2 回目に流す flow の環境変数（塗らない層は none）。
func paintEnv(layers map[string][]int) []string {
	value := map[string]string{PaintWorldEnv: "none", PaintAllEnv: "none"}
	for layer, ns := range layers {
		value[paintEnvOf(layer)] = frameRanges(ns)
	}
	return []string{PaintWorldEnv + "=" + value[PaintWorldEnv], PaintAllEnv + "=" + value[PaintAllEnv]}
}

// drawHashTexts は記録のフォルダ rec の下の drawhash.txt の全部（パス → 中身）。
func drawHashTexts(rec string) map[string]string {
	out := map[string]string{}
	_ = filepath.Walk(rec, func(p string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() && info.Name() == DrawHashFile {
			if b, err := os.ReadFile(p); err == nil {
				out[p] = string(b)
			}
		}
		return nil
	})
	return out
}

// sameDrawHashes は 1 回目と 2 回目の鍵が同じか。違えば違ったファイルを返す（決定性の破れ）。
func sameDrawHashes(before, after map[string]string) []string {
	var bad []string
	for p, text := range before {
		if after[p] != text {
			bad = append(bad, p)
		}
	}
	for p := range after {
		if _, ok := before[p]; !ok {
			bad = append(bad, p)
		}
	}
	sort.Strings(bad)
	return bad
}

// missingPNGs は鍵を先に撮った後、まだ PNG の要るコマ（写し損ね・塗り損ね）。
func missingPNGs(cur, base *Side) []string {
	keys := newDrawKeys()
	var out []string
	for _, flow := range sortedKeys(cur.Flows) {
		for _, size := range sortedKeys(cur.Flows[flow]) {
			nt := cur.Flows[flow][size]
			for _, f := range framesNeedingPNG(keys, base.Flows[flow][size], nt) {
				out = append(out, filepath.Join(nt.Dir, f.File))
			}
		}
	}
	return out
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	tmp := dst + ".part"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}
