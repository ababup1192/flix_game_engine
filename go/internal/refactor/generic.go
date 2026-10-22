package refactor

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// 汎用の AST（flixlint の Generic が索引と同じ走行で書く facts/generic/ の列）を読む所。
//
// 列は big endian の Int32 の並び（<表>.<列>.i32）と、1 行 1 値の字のファイル（strings.txt・files.txt・kinds.txt・meta.txt）。
// 節（node）は宣言ごとに親が先・子は欄の順。各節は種類（Expr.ApplyDef など）・親・親の中の欄（slot）・欄の中の位置（index）・
// 位置（行と列は 1 から、終わりの列は最後の字の次・UTF-16）・型（typed の段の推論した型。type の表の行）を持ち、
// 葉（attr）は名前（symUse・label など）と字か型。
//
// 欄（slot）と葉（attr）の名前の番号は flixlint の shim/AstNames.scala（make ast-kinds が作る物）から読み、
// meta.txt の schemaHash と同じかを確かめる（違う版の shim の列を、違う番号のまま読まない）。
//
// WhyNot: 書き換えの当たりを spans の行（名前の位置）だけで決めないのは、式の形（引数の木・match の腕・欄の読み）と
// 式の型（--where）が要るため。spans は名前の位置だけで、式の型を持たない。

// GenericDir は索引の段 s と同じ走行で書いた汎用の AST の写しの置き場（build/refactor/generic-<段>）。
func (b Builder) GenericDir(s Stage) string { return filepath.Join(b.Dir(), "generic-"+string(s)) }

// factsGenericDir は flixlint が書く汎用の AST の置き場（--build-dir の facts/generic）。
func (b Builder) factsGenericDir() string {
	return filepath.Join(b.Dir(), "flixlint", "facts", "generic")
}

// keepGeneric は索引を作った直後に、同じ走行の汎用の AST を段ごとの置き場へ写し、索引の鍵を key.txt に書く
// （別の段の走行が facts/generic を上書きするため。読む側は鍵が索引と同じ時だけ使う）。
func (b Builder) keepGeneric(s Stage, key string) {
	src := b.factsGenericDir()
	meta, err := os.ReadFile(filepath.Join(src, "meta.txt"))
	if err != nil || !strings.Contains(string(meta), "stage="+string(s)+"\n") {
		return
	}
	dst := b.GenericDir(s)
	tmp := dst + ".tmp"
	os.RemoveAll(tmp)
	if os.MkdirAll(tmp, 0o755) != nil {
		return
	}
	entries, err := os.ReadDir(src)
	if err != nil {
		return
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		// 写すのは同じ disk の中なので、hard link で足りる（30 MB を写さない）。できなければ写す。
		from, to := filepath.Join(src, e.Name()), filepath.Join(tmp, e.Name())
		if os.Link(from, to) != nil {
			data, err := os.ReadFile(from)
			if err != nil || os.WriteFile(to, data, 0o644) != nil {
				os.RemoveAll(tmp)
				return
			}
		}
	}
	if os.WriteFile(filepath.Join(tmp, "key.txt"), []byte(key+"\n"), 0o644) != nil {
		os.RemoveAll(tmp)
		return
	}
	os.RemoveAll(dst)
	os.Rename(tmp, dst)
}

// genericKey は段 s の汎用の AST の写しを作った時の索引の鍵（無ければ ""）。
func (b Builder) genericKey(s Stage) string {
	data, err := os.ReadFile(filepath.Join(b.GenericDir(s), "key.txt"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// Ast は読んだ汎用の AST。
type Ast struct {
	Stage string
	Files []string // files.txt（宣言の file の番号 → パス）

	kinds, slots, attrs []string
	kindNo, slotNo      map[string]int32
	attrNo              map[string]int32

	Kind, Parent, Slot, Index, Root, Line, Col, EndLine, EndCol, Synth, Type []int32
	Effect                                                                   []int32 // 式の効果の型の行（-1 は無し。列の無い古い写しでは nil）

	aName, aValue, aType []int32
	aStart               []int32 // 節 i の葉は aStart[i]..aStart[i+1]

	tForm, tName, tArgStart, tArgs, tExpands []int32
	strs                                     []string

	declFile map[int32]int32 // 宣言の節 → files の番号

	fxRaw, fxPretty map[int32]fxMemo           // FlixType の控え
	aliasByKey      map[string]map[string]bool // 閉じた record の欄の組 → 型 alias の名前
	children        [][]int32
	aligned         bool // record の式の範囲を字の上の { 〜 } に揃えたか（spanfix.go）
}

// LoadAst は dir（facts/generic の写し）を読む。flixlint は flixlint の前面（shim/AstNames.scala を探す）。
func LoadAst(dir, flixlint string) (*Ast, error) {
	meta, err := readLines(filepath.Join(dir, "meta.txt"))
	if err != nil {
		return nil, fmt.Errorf("汎用の AST（%s）が無い: %v", rel(dir), err)
	}
	kv := map[string]string{}
	for _, l := range meta {
		if k, v, ok := strings.Cut(l, "="); ok {
			kv[k] = v
		}
	}
	if kv["format"] != "1" {
		return nil, fmt.Errorf("汎用の AST の形の版が %q（読めるのは 1）", kv["format"])
	}
	names, err := loadAstNames(flixlint)
	if err != nil {
		return nil, err
	}
	if names.hash != kv["schemaHash"] {
		return nil, fmt.Errorf("汎用の AST の schemaHash %s が flixlint の AstNames.scala（%s）と違う（作った flixlint と読む flixlint が違う。bin/fge refactor index --stage typed --rebuild）", kv["schemaHash"], names.hash)
	}
	a := &Ast{Stage: kv["stage"], kinds: names.kinds, slots: names.slots, attrs: names.attrs}
	if kinds, err := readLines(filepath.Join(dir, "kinds.txt")); err == nil && strings.Join(kinds, "\n") != strings.Join(names.kinds, "\n") {
		return nil, fmt.Errorf("汎用の AST の kinds.txt が flixlint の AstNames.scala と違う")
	}
	a.kindNo, a.slotNo, a.attrNo = numbers(a.kinds), numbers(a.slots), numbers(a.attrs)
	col := func(name string) []int32 {
		if err != nil {
			return nil
		}
		var xs []int32
		xs, err = readI32(filepath.Join(dir, name+".i32"))
		return xs
	}
	a.Kind, a.Parent, a.Slot, a.Index, a.Root = col("node.kind"), col("node.parent"), col("node.slot"), col("node.index"), col("node.root")
	a.Line, a.Col, a.EndLine, a.EndCol, a.Synth, a.Type = col("node.line"), col("node.col"), col("node.endLine"), col("node.endCol"), col("node.synthetic"), col("node.type")
	if xs, e := readI32(filepath.Join(dir, "node.effect.i32")); e == nil && len(xs) == len(a.Kind) {
		a.Effect = xs
	}
	aNode := col("attr.node")
	a.aName, a.aValue, a.aType = col("attr.name"), col("attr.value"), col("attr.type")
	a.tForm, a.tName, a.tArgStart, a.tArgs, a.tExpands = col("type.form"), col("type.name"), col("type.argStart"), col("type.args"), col("type.expands")
	declNode, declFile := col("decl.node"), col("decl.file")
	if err != nil {
		return nil, fmt.Errorf("汎用の AST の列が読めない: %v", err)
	}
	if a.strs, err = readLines(filepath.Join(dir, "strings.txt")); err != nil {
		return nil, err
	}
	for i, s := range a.strs {
		if strings.Contains(s, `\`) {
			a.strs[i] = unescapeLine(s)
		}
	}
	if a.Files, err = readLines(filepath.Join(dir, "files.txt")); err != nil {
		return nil, err
	}
	n := len(a.Kind)
	a.aStart = make([]int32, n+1)
	for _, x := range aNode {
		a.aStart[x+1]++
	}
	for i := 0; i < n; i++ {
		a.aStart[i+1] += a.aStart[i]
	}
	a.declFile = map[int32]int32{}
	for i, d := range declNode {
		a.declFile[d] = declFile[i]
	}
	a.children = make([][]int32, n)
	for i := 0; i < n; i++ {
		if p := a.Parent[i]; p >= 0 {
			a.children[p] = append(a.children[p], int32(i))
		}
	}
	return a, nil
}

func numbers(xs []string) map[string]int32 {
	m := make(map[string]int32, len(xs))
	for i, x := range xs {
		m[x] = int32(i)
	}
	return m
}

func readI32(path string) ([]int32, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(data)%4 != 0 {
		return nil, fmt.Errorf("%s の大きさが 4 の倍数でない", path)
	}
	out := make([]int32, len(data)/4)
	for i := range out {
		out[i] = int32(binary.BigEndian.Uint32(data[4*i:]))
	}
	return out, nil
}

func readLines(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<24)
	var out []string
	for sc.Scan() {
		out = append(out, sc.Text())
	}
	return out, sc.Err()
}

// unescapeLine は strings.txt の 1 行（\ と改行を \\ \n \r と書いた物）を元の字にする。
func unescapeLine(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) {
			switch s[i+1] {
			case '\\':
				b.WriteByte('\\')
				i++
				continue
			case 'n':
				b.WriteByte('\n')
				i++
				continue
			case 'r':
				b.WriteByte('\r')
				i++
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

type astNames struct {
	hash                string
	kinds, slots, attrs []string
}

var (
	astNamesHash   = regexp.MustCompile(`val schemaHash: String = "([0-9a-f]+)"`)
	astNamesVector = regexp.MustCompile(`(?s)val (kinds|slots|attrs): Vector\[String\] = Vector\((.*?)\)`)
	astNamesString = regexp.MustCompile(`"((?:[^"\\]|\\.)*)"`)
)

// loadAstNames は flixlint の shim/AstNames.scala（make ast-kinds の生成物）から、種類・欄・葉の名前の番号の順を読む。
func loadAstNames(flixlint string) (astNames, error) {
	var n astNames
	real, err := filepath.EvalSymlinks(flixlint)
	if err != nil {
		real = flixlint
	}
	path := filepath.Join(filepath.Dir(filepath.Dir(real)), "shim", "AstNames.scala")
	data, err := os.ReadFile(path)
	if err != nil {
		return n, fmt.Errorf("flixlint の shim/AstNames.scala が読めない（汎用の AST の欄の名前の番号が要る。flixlint 0.8.0 以上）: %v", err)
	}
	text := string(data)
	if m := astNamesHash.FindStringSubmatch(text); m != nil {
		n.hash = m[1]
	}
	for _, m := range astNamesVector.FindAllStringSubmatch(text, -1) {
		var xs []string
		for _, s := range astNamesString.FindAllStringSubmatch(m[2], -1) {
			xs = append(xs, s[1])
		}
		switch m[1] {
		case "kinds":
			n.kinds = xs
		case "slots":
			n.slots = xs
		case "attrs":
			n.attrs = xs
		}
	}
	if n.hash == "" || len(n.kinds) == 0 || len(n.slots) == 0 || len(n.attrs) == 0 {
		return n, fmt.Errorf("%s の形が読めない（schemaHash・kinds・slots・attrs）", path)
	}
	return n, nil
}

// ---- 引く口 ----

// KindOf は節の種類の名前（Expr.ApplyDef など）。
func (a *Ast) KindOf(n int32) string { return a.kinds[a.Kind[n]] }

// SlotOf は節が親のどの欄にあるか（宣言なら ""）。
func (a *Ast) SlotOf(n int32) string {
	if a.Slot[n] < 0 {
		return ""
	}
	return a.slots[a.Slot[n]]
}

// Children は節の子（欄の順）。
func (a *Ast) Children(n int32) []int32 { return a.children[n] }

// ChildrenIn は欄 slot の子（index の順）。
func (a *Ast) ChildrenIn(n int32, slot string) []int32 {
	no, ok := a.slotNo[slot]
	if !ok {
		return nil
	}
	var out []int32
	for _, c := range a.children[n] {
		if a.Slot[c] == no {
			out = append(out, c)
		}
	}
	return out
}

// Child は欄 slot の最初の子（無ければ -1）。
func (a *Ast) Child(n int32, slot string) int32 {
	if cs := a.ChildrenIn(n, slot); len(cs) > 0 {
		return cs[0]
	}
	return -1
}

// Attr は節の葉 name の字（無ければ ""・false）。
func (a *Ast) Attr(n int32, name string) (string, bool) {
	no, ok := a.attrNo[name]
	if !ok {
		return "", false
	}
	for i := a.aStart[n]; i < a.aStart[n+1]; i++ {
		if a.aName[i] == no && a.aValue[i] >= 0 {
			return a.strs[a.aValue[i]], true
		}
	}
	return "", false
}

// AttrTypes は節の葉 name の型（型の表の行。無ければ nil）。
func (a *Ast) AttrTypes(n int32, name string) []int32 {
	no, ok := a.attrNo[name]
	if !ok {
		return nil
	}
	var out []int32
	for i := a.aStart[n]; i < a.aStart[n+1]; i++ {
		if a.aName[i] == no && a.aType[i] >= 0 {
			out = append(out, a.aType[i])
		}
	}
	return out
}

// EffectOf は式の効果の型の行（無ければ -1）。
func (a *Ast) EffectOf(n int32) int32 {
	if a.Effect == nil || n < 0 || int(n) >= len(a.Effect) {
		return -1
	}
	return a.Effect[n]
}

// File は節のファイル（宣言の files の行）。
func (a *Ast) File(n int32) string {
	if f, ok := a.declFile[a.Root[n]]; ok && f >= 0 && int(f) < len(a.Files) {
		return a.Files[f]
	}
	return ""
}

// SpanOf は節の範囲を索引の行の形にする（Kind は節の種類）。
func (a *Ast) SpanOf(n int32) Row {
	return Row{Kind: a.KindOf(n), File: a.File(n), Line: int(a.Line[n]), Col: int(a.Col[n]), EndLine: int(a.EndLine[n]), EndCol: int(a.EndCol[n])}
}

// RootName は節を囲む宣言の名前（def の sym。読めなければ ""）。
func (a *Ast) RootName(n int32) string {
	r := a.Root[n]
	for _, k := range []string{"sym", "symUse"} {
		if s, ok := a.Attr(r, k); ok {
			return s
		}
	}
	return ""
}

// OfKind は種類 kind の節の全部。
func (a *Ast) OfKind(kind string) []int32 {
	no, ok := a.kindNo[kind]
	if !ok {
		return nil
	}
	var out []int32
	for i, k := range a.Kind {
		if k == no {
			out = append(out, int32(i))
		}
	}
	return out
}

// TypeText は型の表の行 t を字にする（List[Int32]・Option[World]・a -> b の形の近い物）。alias は名前のまま。
func (a *Ast) TypeText(t int32) string {
	if t < 0 || int(t) >= len(a.tForm) {
		return "?"
	}
	head, args := a.applied(t)
	name := ""
	if nm := a.tName[head]; nm >= 0 {
		name = a.strs[nm]
	}
	switch Forms[a.tForm[head]] {
	case "Alias":
		return a.withArgs(name, a.tArgList(head))
	case "Cst":
		return a.withArgs(name, args)
	case "Var":
		return "'" + name
	}
	return a.withArgs(Forms[a.tForm[head]]+name, args)
}

func (a *Ast) withArgs(name string, args []int32) string {
	if len(args) == 0 {
		return name
	}
	parts := make([]string, len(args))
	for i, x := range args {
		parts[i] = a.TypeText(x)
	}
	return name + "[" + strings.Join(parts, ", ") + "]"
}

func (a *Ast) tArgList(t int32) []int32 { return a.tArgs[a.tArgStart[t]:a.tArgStart[t+1]] }

// applied は Apply の入れ子をほどいた頭と引数（Option[Int32] は Apply(Cst Option, Cst Int32)）。
func (a *Ast) applied(t int32) (int32, []int32) {
	var args []int32
	for Forms[a.tForm[t]] == "Apply" {
		xs := a.tArgList(t)
		if len(xs) != 2 {
			break
		}
		args = append([]int32{xs[1]}, args...)
		t = xs[0]
	}
	return t, args
}

// TypeHeads は型 t の頭の名前（alias なら alias の名前と開いた先の頭の名前の両方）。--where の当てに使う。
func (a *Ast) TypeHeads(t int32) []string {
	var out []string
	for depth := 0; t >= 0 && int(t) < len(a.tForm) && depth < 16; depth++ {
		head, _ := a.applied(t)
		if nm := a.tName[head]; nm >= 0 {
			out = append(out, a.strs[nm])
		}
		if Forms[a.tForm[head]] != "Alias" {
			break
		}
		t = a.tExpands[head]
	}
	return out
}

// AliasOf は型 t が名前 name（修飾つきか終わりの名前）の型 alias の開いた先と同じ型か。
// 推論した型では alias が開かれる（`let (a, b) = …` で束ねた record など）ので、alias の行の開いた先の型の番号と比べる。
// 型の表は同じ形の型を 1 行にする（hash-consing）ので、番号が同じなら同じ型。
func (a *Ast) AliasOf(t int32, name string) bool {
	if t < 0 {
		return false
	}
	labels := a.recordLabels(t)
	for i, f := range a.tForm {
		if Forms[f] != "Alias" || a.tName[i] < 0 {
			continue
		}
		d := displaySym(a.strs[a.tName[i]])
		if d != name && !strings.HasSuffix(d, "."+name) {
			continue
		}
		if a.tExpands[i] == t {
			return true
		}
		// 閉じた record は欄の並びと中の alias の開き方で行が別になるので、欄の名前の組で比べる（spans の owner の why=row と同じ見方）。
		if labels != "" && a.recordLabels(a.tExpands[i]) == labels {
			return true
		}
	}
	return false
}

// recordLabels は閉じた record の型の欄の名前を並べた物（record でないか開いた row なら ""）。
func (a *Ast) recordLabels(t int32) string {
	for depth := 0; t >= 0 && Forms[a.tForm[t]] == "Alias" && depth < 16; depth++ {
		t = a.tExpands[t]
	}
	if t < 0 {
		return ""
	}
	head, args := a.applied(t)
	if Forms[a.tForm[head]] != "Record" || len(args) != 1 {
		return ""
	}
	var labels []string
	row := args[0]
	for depth := 0; depth < 4096; depth++ {
		for Forms[a.tForm[row]] == "Alias" {
			row = a.tExpands[row]
		}
		h, xs := a.applied(row)
		switch {
		case Forms[a.tForm[h]] == "RecordRow" && len(xs) == 2 && a.tName[h] >= 0:
			labels = append(labels, a.strs[a.tName[h]])
			row = xs[1]
			continue
		case Forms[a.tForm[h]] == "Cst" && a.tName[h] >= 0 && a.strs[a.tName[h]] == "RecordRowEmpty":
			sort.Strings(labels)
			return strings.Join(labels, ",")
		}
		return "" // 開いた row（型の変数）など
	}
	return ""
}

// Forms は型の表の form の名前（flixlint の Generic.Forms と同じ順）。
var Forms = []string{"Cst", "Apply", "Alias", "Var", "Arrow", "Record", "RecordRow", "Schema", "Effect", "EffUnion", "Other"}
