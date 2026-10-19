// Package videos は、ゲームが撮った動画（debug/video/）の一覧と、撮れたかの判定を持つ。
//
//	fge videos status [--root DIR] [--json]
//
// 見る物（どれも debug/ の下で git の外。ここは読むだけで何も書かない）:
//
//	debug/video/<名前>.video.json   撮れたかの記録（ゲームの動画の口が書く。state = running / ok / failed）
//	debug/video/<名前>.mp4          動画
//	debug/video/<フォルダ>/f*.png    連番（最後の 1 枚が「最後の画面」）・sfx.txt（コマ番号 音の名前）
//	debug/compare/report.tsv        make compare の結果（動画が基準と違うか）
//
// 判定（Studio の動画のタブと make status が同じ物を読む）:
//
//	ok       mix まで通った
//	failed   入口か mp4 に束ねる段で止まった（stage）
//	stuck    running のまま、撮っていた make（pid）が居ない（mtime で古さは見ない）
//	running  撮っている最中
//	norecord 記録が無い mp4（記録を書く前に撮った物）。撮れていないとは言わない
//
// 記録に flow（e2e/<名前>.flow）があれば、その先頭のコメントを題と一言にする。
// 無ければ題は空（読む側がファイル名で代用する）。
package videos

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

// Dir は動画の置き場（ゲームの根から）。
const Dir = "debug/video"

// CompareReport は make compare が書く表（ゲームの根から）。
const CompareReport = "debug/compare/report.tsv"

const recordSuffix = ".video.json"

// Video は動画 1 本ぶん。パスはどれもゲームの根から（無ければ空）。
type Video struct {
	Name          string  `json:"name"`
	State         string  `json:"state"`
	Make          string  `json:"make,omitempty"`
	Stage         string  `json:"stage,omitempty"`
	Failure       string  `json:"failure,omitempty"`
	Frames        int     `json:"frames,omitempty"`
	Fps           float64 `json:"fps,omitempty"`
	StartedAt     string  `json:"startedAt,omitempty"`
	Mp4           string  `json:"mp4,omitempty"`
	Mp4Bytes      int64   `json:"mp4Bytes,omitempty"`
	Mp4Mtime      int64   `json:"mp4Mtime,omitempty"`
	FramesDir     string  `json:"framesDir,omitempty"`
	LastFrame     string  `json:"lastFrame,omitempty"`
	Sfx           string  `json:"sfx,omitempty"`
	Flow          string  `json:"flow,omitempty"`
	Title         string  `json:"title"`
	Desc          string  `json:"desc"`
	Compare       string  `json:"compare,omitempty"`
	CompareDetail string  `json:"compareDetail,omitempty"`
}

// record は動画の口が書く記録の形（ゲームの bin/video-status.py と同じ欄）。
type record struct {
	State     string          `json:"state"`
	Make      string          `json:"make"`
	Pid       int             `json:"pid"`
	StartedAt string          `json:"startedAt"`
	Stage     string          `json:"stage"`
	Failure   string          `json:"failure"`
	Frames    int             `json:"frames"`
	Fps       json.RawMessage `json:"fps"`
	Flow      string          `json:"flow"`
}

// IsBroken は「撮れていない」か（failed と stuck）。
func (v Video) IsBroken() bool { return v.State == "failed" || v.State == "stuck" }

// List は root（ゲームの根）の動画を名前の順に返す。置き場が無ければ空。
// alive は pid が生きているか（テストで差し替える）。
func List(root string, alive func(int) bool) []Video {
	base := filepath.Join(root, filepath.FromSlash(Dir))
	byName := map[string]*Video{}
	get := func(name string) *Video {
		if v, ok := byName[name]; ok {
			return v
		}
		v := &Video{Name: name}
		byName[name] = v
		return v
	}
	filepath.Walk(base, func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		rel, _ := filepath.Rel(base, p)
		rel = filepath.ToSlash(rel)
		switch {
		case strings.HasSuffix(rel, recordSuffix):
			v := get(strings.TrimSuffix(rel, recordSuffix))
			applyRecord(v, p, alive)
		case strings.HasSuffix(rel, ".mp4") && !isFrameFolderFile(base, rel):
			v := get(strings.TrimSuffix(rel, ".mp4"))
			v.Mp4 = Dir + "/" + rel
			v.Mp4Bytes = info.Size()
			v.Mp4Mtime = info.ModTime().Unix()
		}
		return nil
	})
	compares := readCompare(filepath.Join(root, filepath.FromSlash(CompareReport)))
	out := make([]Video, 0, len(byName))
	for _, v := range byName {
		if v.State == "" {
			v.State = "norecord"
		}
		if dir := framesDirOf(base, v.Name); dir != "" {
			v.FramesDir = Dir + "/" + dir
			v.LastFrame = lastFrame(base, dir)
			if isFile(filepath.Join(base, filepath.FromSlash(dir), "sfx.txt")) {
				v.Sfx = v.FramesDir + "/sfx.txt"
			}
		}
		if v.Flow != "" {
			v.Title, v.Desc = flowHeading(filepath.Join(root, filepath.FromSlash(v.Flow)))
		}
		if c, ok := compares[v.Name+".mp4"]; ok {
			v.Compare, v.CompareDetail = c[0], c[1]
		}
		out = append(out, *v)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func applyRecord(v *Video, path string, alive func(int) bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var r record
	if json.Unmarshal(data, &r) != nil {
		v.State = "failed"
		v.Failure = "記録の JSON を読めない"
		return
	}
	v.Make, v.Stage, v.Failure, v.Frames, v.StartedAt, v.Flow = r.Make, r.Stage, r.Failure, r.Frames, r.StartedAt, r.Flow
	json.Unmarshal(r.Fps, &v.Fps)
	switch r.State {
	case "running":
		if alive(r.Pid) {
			v.State = "running"
		} else {
			v.State = "stuck"
		}
	case "ok", "failed":
		v.State = r.State
	default:
		v.State = "failed"
		v.Failure = fmt.Sprintf("記録の state が読めない（%q）", r.State)
	}
}

// isFrameFolderFile は連番のフォルダの中の物か（比べの写しなど、一覧に出さない）。
func isFrameFolderFile(base, rel string) bool {
	dir := filepath.Dir(filepath.FromSlash(rel))
	if dir == "." {
		return false
	}
	matches, _ := filepath.Glob(filepath.Join(base, dir, "f[0-9]*.png"))
	return len(matches) > 0
}

// framesDirOf は出力名の連番のフォルダ。出力名はフォルダ名の後ろに字を足した物
// （transition_sfx・fight_lizard_slow）があるので、名前そのもの → 末尾の _ 区切りを 1 つずつ落とした物の順に探す。
func framesDirOf(base, name string) string {
	for cand := name; cand != ""; {
		if isDir(filepath.Join(base, filepath.FromSlash(cand))) {
			return cand
		}
		i := strings.LastIndex(cand, "_")
		if i <= 0 || strings.Contains(cand[i:], "/") {
			return ""
		}
		cand = cand[:i]
	}
	return ""
}

func lastFrame(base, dir string) string {
	matches, _ := filepath.Glob(filepath.Join(base, filepath.FromSlash(dir), "f[0-9]*.png"))
	if len(matches) == 0 {
		return ""
	}
	sort.Strings(matches)
	rel, _ := filepath.Rel(base, matches[len(matches)-1])
	return Dir + "/" + filepath.ToSlash(rel)
}

// flowHeading は flow の先頭のコメント（# で始まる行の並び）の 1 行目を題、残りを一言にする。
func flowHeading(path string) (string, string) {
	f, err := os.Open(path)
	if err != nil {
		return "", ""
	}
	defer f.Close()
	var lines []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if !strings.HasPrefix(line, "#") {
			break
		}
		if text := strings.TrimSpace(strings.TrimPrefix(line, "#")); text != "" {
			lines = append(lines, text)
		}
	}
	if len(lines) == 0 {
		return "", ""
	}
	return lines[0], strings.Join(lines[1:], " ")
}

// readCompare は make compare の表から動画の行（名前 → state・detail）を読む。無ければ空。
func readCompare(path string) map[string][2]string {
	out := map[string][2]string{}
	data, err := os.ReadFile(path)
	if err != nil {
		return out
	}
	for _, line := range strings.Split(string(data), "\n") {
		cols := strings.Split(line, "\t")
		if len(cols) < 4 || cols[0] != "video" {
			continue
		}
		out[cols[1]] = [2]string{cols[2], cols[3]}
	}
	return out
}

// PidAlive は pid のプロセスが居るか（シグナル 0 を送る）。
func PidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	err = p.Signal(syscall.Signal(0))
	return err == nil || err == syscall.EPERM
}

// Text は人に見せる一覧（撮れていない物を先に）。
func Text(vs []Video) string {
	if len(vs) == 0 {
		return "動画はまだありません（" + Dir + "/）\n"
	}
	var b strings.Builder
	broken := 0
	for _, v := range vs {
		if v.IsBroken() {
			broken++
		}
	}
	for _, pass := range []bool{true, false} {
		for _, v := range vs {
			if v.IsBroken() != pass {
				continue
			}
			fmt.Fprintf(&b, "[%s] %s%s\n", label[v.State], v.Name, detailOf(v))
		}
	}
	if broken > 0 {
		fmt.Fprintf(&b, "撮れていない動画 %d 本 → %s/<名前>%s\n", broken, Dir, recordSuffix)
	}
	return b.String()
}

var label = map[string]string{
	"ok": "ok", "failed": "失敗", "stuck": "途中で止まった", "running": "撮影中", "norecord": "記録なし",
}

func detailOf(v Video) string {
	var parts []string
	switch v.State {
	case "failed":
		parts = append(parts, "段="+orDash(v.Stage))
		if v.Failure != "" {
			parts = append(parts, v.Failure)
		}
	case "stuck":
		parts = append(parts, "撮っていた make（"+orDash(v.Make)+"）が居ない")
	case "ok":
		parts = append(parts, fmt.Sprintf("%d コマ・%g fps", v.Frames, v.Fps))
	}
	if v.Compare == "diff" {
		parts = append(parts, "基準と違う（"+v.CompareDetail+"）")
	}
	if len(parts) == 0 {
		return ""
	}
	return "  " + strings.Join(parts, "・")
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func isDir(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

func isFile(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.Mode().IsRegular()
}

// Sound は sfx.txt の 1 行（コマ番号と音の名前）。
type Sound struct {
	Frame int
	Name  string
}

// ReadSfx は sfx.txt（「コマ番号 音の名前」の並び。# の行と空行は飛ばす）を読む。読めなければ nil と理由。
func ReadSfx(path string) ([]Sound, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var out []Sound
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 || strings.HasPrefix(fields[0], "#") {
			continue
		}
		var frame int
		if _, err := fmt.Sscanf(fields[0], "%d", &frame); err != nil {
			continue
		}
		out = append(out, Sound{Frame: frame, Name: fields[1]})
	}
	return out, nil
}

// SfxBesideMp4 は mp4（debug/video/<名前>.mp4 の絶対パスか相対パス）の連番のフォルダの sfx.txt。無ければ空。
func SfxBesideMp4(mp4 string) string {
	base := filepath.Dir(mp4)
	name := strings.TrimSuffix(filepath.Base(mp4), ".mp4")
	dir := framesDirOf(base, name)
	if dir == "" {
		return ""
	}
	p := filepath.Join(base, filepath.FromSlash(dir), "sfx.txt")
	if !isFile(p) {
		return ""
	}
	return p
}

// DiffSfx は 2 つの音の表を名前つきで比べた 1 行（同じなら空）。
// 「-名前@コマ」は基準だけで鳴った音・「+名前@コマ」は今だけで鳴った音（同じコマで同じ名前は対にして消す）。
func DiffSfx(base, cur []Sound) string {
	key := func(s Sound) string { return fmt.Sprintf("%s@%d", s.Name, s.Frame) }
	count := map[string]int{}
	for _, s := range base {
		count[key(s)]--
	}
	for _, s := range cur {
		count[key(s)]++
	}
	var gone, added []string
	for _, s := range base {
		if k := key(s); count[k] < 0 {
			gone = append(gone, "-"+k)
			count[k]++
		}
	}
	for _, s := range cur {
		if k := key(s); count[k] > 0 {
			added = append(added, "+"+k)
			count[k]--
		}
	}
	all := append(gone, added...)
	if len(all) == 0 {
		return ""
	}
	if len(all) > 8 {
		all = append(all[:8], fmt.Sprintf("…ほか %d", len(all)-8))
	}
	return "音 " + strings.Join(all, " ")
}
