// Package renderaudit は、描き出し (make render / render-all) が場面ごとに書いた測定の表 (TSV) を
// 後から読み直して止める 2 本の lint。表を書くのはゲームの Flix (字の置き場所・描画物の z を測る所)で、
// ここは表の読み方と止め方だけを持つ。
//
//	fge-go text-audit [--root DIR] [--tsv PATH] [--allow PATH]   字の被り・はみ出し (許す物の表を引く)
//	fge-go z-audit    [--root DIR] [--tsv PATH]                  描画物の z が描いてよい層の外
//
// 表が無いとき (まだ描き出していない) は 1 行知らせて通す。
//
// 規約は bin/lint-rules/<名前>.json (表の置き場・直し方の 1 行)。ゲームは <名前>.local.json に
// 同じ鍵を書けば上書きでき、text-audit の許す物 (allow) もそこに書く。
//
// WhyNot: 表を書く側 (測る所) を engine に持たないのは、どの字・どの層を見るかが画面の作りで決まるため。
// 読み方と許す物の照合は画面に依らないので、ゲームごとに台本を写さずここに置く。
package renderaudit

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// Config は 1 本の lint の規約。engine の <名前>.json に、ゲームの <名前>.local.json を重ねた物。
type Config struct {
	// Table は測定の表 (根からの相対)。
	Table string
	// Hint は見つけた件の後ろに出す直し方の 1 行。
	Hint string
	// Allow は許す物 (text-audit だけが使う)。
	Allow []AllowRule
	// AllowFrom は許す物を書く所 (知らせに名指しする)。
	AllowFrom string
}

// AllowRule は許す物 1 つ。書いた鍵だけで絞る (空の鍵は見ない)。
// Text と Other は「含むか」、TextMatch は字全体の正規表現、MaxExcess ははみ出しの上限 px。
type AllowRule struct {
	Kind      string   `json:"kind"`
	Shot      string   `json:"shot"`
	Text      string   `json:"text"`
	Other     string   `json:"other"`
	TextMatch string   `json:"textMatch"`
	MaxExcess *float64 `json:"maxExcess"`
	Reason    string   `json:"reason"`
	match     *regexp.Regexp
}

type configFile struct {
	Table *string     `json:"table"`
	Hint  *string     `json:"hint"`
	Allow []AllowRule `json:"allow"`
}

// Paths は規約ファイルとゲームの上書きの置き場 (根からの相対)。
func Paths(name string) (rules, local string) {
	return filepath.Join("bin", "lint-rules", name+".json"),
		filepath.Join("bin", "lint-rules", name+".local.json")
}

// LoadConfig は規約を読み、ゲームの上書きを重ねる。allowPath が空でなければ許す物はそこから読む。
// WhyNot: 壊れた JSON を空の表として続けないのは、許す物が黙って消えて全部鳴るか、
// 規約が消えて何も見なくなるかのどちらかになるため。
func LoadConfig(root, name, allowPath string) (*Config, error) {
	rulesRel, localRel := Paths(name)
	var base configFile
	if err := readJSON(filepath.Join(root, rulesRel), &base); err != nil {
		return nil, fmt.Errorf("規約ファイルを読めません (%s): %v", filepath.ToSlash(rulesRel), err)
	}
	if base.Table == nil || base.Hint == nil {
		return nil, fmt.Errorf("%s には table と hint が要ります", filepath.ToSlash(rulesRel))
	}
	if len(base.Allow) > 0 {
		return nil, fmt.Errorf("%s に allow を書かない (許す物はゲームの %s へ)", filepath.ToSlash(rulesRel), filepath.ToSlash(localRel))
	}
	cfg := &Config{Table: *base.Table, Hint: *base.Hint, AllowFrom: filepath.ToSlash(localRel)}
	var local configFile
	err := readJSON(filepath.Join(root, localRel), &local)
	switch {
	case errors.Is(err, os.ErrNotExist):
	case err != nil:
		return nil, fmt.Errorf("%s が壊れています: %v", filepath.ToSlash(localRel), err)
	default:
		if local.Table != nil {
			cfg.Table = *local.Table
		}
		if local.Hint != nil {
			cfg.Hint = *local.Hint
		}
		cfg.Allow = local.Allow
	}
	if allowPath != "" {
		var f configFile
		if err := readJSON(resolve(root, allowPath), &f); err != nil {
			return nil, fmt.Errorf("許す物の表を読めません (%s): %v", allowPath, err)
		}
		cfg.Allow, cfg.AllowFrom = f.Allow, allowPath
	}
	for i := range cfg.Allow {
		r := &cfg.Allow[i]
		if strings.TrimSpace(r.Reason) == "" {
			return nil, fmt.Errorf("%s の allow の %d 番目に reason がありません (許す物には理由を 1 行)", cfg.AllowFrom, i+1)
		}
		if r.TextMatch != "" {
			re, err := regexp.Compile(`^(?:` + r.TextMatch + `)$`)
			if err != nil {
				return nil, fmt.Errorf("%s の allow の %d 番目の textMatch が正規表現として壊れています: %v", cfg.AllowFrom, i+1, err)
			}
			r.match = re
		}
	}
	return cfg, nil
}

func readJSON(path string, v any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, v)
}

func resolve(root, p string) string {
	if filepath.IsAbs(p) {
		return p
	}
	return filepath.Join(root, filepath.FromSlash(p))
}

// Row は表の 1 行 (見出しの名前 → 値)。
type Row map[string]string

// ReadTable は 1 行目を見出しとするタブ区切りの表を読む。空の行は飛ばす。
// WhyNot: CSV として読まない (引用符を解かない) のは、表を書く側が引用符を付けず、
// 字の中の " をそのまま書くため。
func ReadTable(path string) ([]Row, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n")
	if len(lines) == 0 || lines[0] == "" {
		return nil, nil
	}
	head := strings.Split(lines[0], "\t")
	var rows []Row
	for _, line := range lines[1:] {
		if line == "" {
			continue
		}
		cells := strings.Split(line, "\t")
		row := Row{}
		for i, h := range head {
			if i < len(cells) {
				row[h] = cells[i]
			}
		}
		rows = append(rows, row)
	}
	return rows, nil
}

// Allowed は row が許す物のどれかに当たるか。
func Allowed(row Row, rules []AllowRule) bool {
	for _, r := range rules {
		if r.Kind != "" && r.Kind != row["kind"] {
			continue
		}
		if r.Shot != "" && r.Shot != row["shot"] {
			continue
		}
		if r.Text != "" && !strings.Contains(row["text"], r.Text) {
			continue
		}
		if r.Other != "" && !strings.Contains(row["other"], r.Other) {
			continue
		}
		if r.match != nil && !r.match.MatchString(row["text"]) {
			continue
		}
		if r.MaxExcess != nil {
			excess, err := strconv.ParseFloat(row["excess"], 64)
			if err != nil || excess > *r.MaxExcess {
				continue
			}
		}
		return true
	}
	return false
}

// Options はコマンドの引数から来る差し替え。
type Options struct {
	Root  string
	Table string
	Allow string
}

func (o Options) table(cfg *Config) string {
	if o.Table != "" {
		return o.Table
	}
	return cfg.Table
}

// RunText は字の被り・はみ出しの表を裁く。
func RunText(out io.Writer, o Options) (int, error) {
	const tag = "[text-audit]"
	cfg, err := LoadConfig(o.Root, "text-audit", o.Allow)
	if err != nil {
		return 2, err
	}
	table := o.table(cfg)
	rows, err := ReadTable(resolve(o.Root, table))
	if errors.Is(err, os.ErrNotExist) {
		fmt.Fprintf(out, "%s %s が無いので見ていません — make render-all の後に叩く\n", tag, table)
		return 0, nil
	}
	if err != nil {
		return 2, err
	}
	var found []Row
	for _, r := range rows {
		if !Allowed(r, cfg.Allow) {
			found = append(found, r)
		}
	}
	if len(found) == 0 {
		fmt.Fprintf(out, "%s OK（測った件 %d / 許した物 %d）\n", tag, len(rows), len(rows)-len(found))
		return 0, nil
	}
	fmt.Fprintf(out, "%s %d 件（許した物は %s の allow に理由つきで書く）\n", tag, len(found), cfg.AllowFrom)
	for _, r := range found {
		other := ""
		if r["other"] != "" {
			other = fmt.Sprintf(" ⇔ 「%s」", r["other"])
		}
		fmt.Fprintf(out, "  %-22s %-9s %6spx 「%s」%s\n", r["shot"], r["kind"], r["excess"], r["text"], other)
	}
	if cfg.Hint != "" {
		fmt.Fprintf(out, "%s %s\n", tag, cfg.Hint)
	}
	return 1, nil
}

// RunZ は描画物の z の表を裁く。表に 1 行でもあれば止める (書く側が外れた物だけを書く)。
func RunZ(out io.Writer, o Options) (int, error) {
	const tag = "[z-audit]"
	cfg, err := LoadConfig(o.Root, "z-audit", "")
	if err != nil {
		return 2, err
	}
	table := o.table(cfg)
	rows, err := ReadTable(resolve(o.Root, table))
	if errors.Is(err, os.ErrNotExist) {
		fmt.Fprintf(out, "%s %s が無いので見ていません — make render-all の後に叩く\n", tag, table)
		return 0, nil
	}
	if err != nil {
		return 2, err
	}
	if len(rows) == 0 {
		fmt.Fprintf(out, "%s OK — 描いた物の z はどの場面でも描いてよい層の中\n", tag)
		return 0, nil
	}
	for _, r := range rows {
		fmt.Fprintf(out, "%s %s: z=%s %s %s（描いてよい範囲: %s）\n", tag, r["shot"], r["z"], r["layer"], r["what"], r["allowed"])
	}
	fmt.Fprintf(out, "%s %d 件 — %s\n", tag, len(rows), cfg.Hint)
	return 1, nil
}
