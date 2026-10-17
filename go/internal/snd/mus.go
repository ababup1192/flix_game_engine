package snd

// 台本の mus: 曲を Starlark で書く部品。出力は譜面（chip.json）のデータで、鳴らすのは今の song の op。
//
//	prog = mus.chords("G | C | Em D | G")             和音の進行を 1 回だけ書く（1 小節を | で区切る。2 つ書けば半分ずつ）
//	mel  = mus.mml("o5 l8 d. g. b4 a | g2 r4 e g", inst = "lead")   旋律は MML 風の短い記法（1 小節 = 16 段）
//	stab = mus.comp(prog, "..x...x...x...x.", inst = "stab")         伴奏の和音打ち（1 本の ARP で和音）
//	bass = mus.bass(prog, "x...x.x.x...x...", ["1", "8", "5", "~"], inst = "bass")
//	harp = mus.arp(prog, [0, 1, 2, 1], "x.x.x.x.x.x.x.x.", inst = "pluck")
//	beat = mus.drums({"kick": "x.......x.......", "snare": "....x.......x..."}, {"kick": "C-4 kick", "snare": "D-6 snare"})
//	snd.write_chip("town.chip.json", {"bpm": 112, "channels": [...], "body": {"lead": mel * 2, ...}})
//
// 段の並び（part）は Starlark の list（1 段 = 譜面の 1 段の文字列）。+ でつなぎ、* でくり返し、[a:b] で切り出す。
// 小節の長さが合わない（16 段でない）記法は呼んだ行で止める。

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/starbox"
	"go.starlark.net/starlark"
	"go.starlark.net/starlarkstruct"
)

// musFuncs は mus の関数の説明（docs に出す）。
var musFuncs = []struct{ Name, Sig, Summary string }{
	{"chords", "mus.chords(text)", "和音の進行（\"G | C | Em D | D7\"。| が小節・1 小節に 2 つで半分ずつ）。和音は C・Cm・C7・Cmaj7・Cm7・Cdim・Caug・Csus4・Csus2・C6・Cm6・Cadd9・C9・Cm7b5・Cdim7 と /E の低音。返すのは小節ごとの和音の並び"},
	{"mml", "mus.mml(text, inst=, octave=5, length=8, vol=, quantize=8, ticks=6)", "旋律の短い記法: c d e f g a b（+ か # で半音上・- で下）・長さ 1 2 4 8 16 と付点 .・r 休み（音を離す）・^ で前の音をのばす・o 音域・< >・l 既定の長さ・v 音量・@ 楽器・q n（長さの n/8 の tick で離す。CUT を付ける・ticks は 1 段の tick）・{SLD 2} は次の音にコマンド・| は小節の線（長さを確かめる）"},
	{"comp", "mus.comp(chords, rhythm, inst=, octave=4, vol=, tones=3)", "和音打ち: rhythm（16 字。x 打つ・- のばす・. 離す。並びなら小節ごとに回す）の x で和音の根を ARP で鳴らす"},
	{"bass", "mus.bass(chords, rhythm, shape=[\"1\"], inst=, octave=2, vol=)", "ベース: rhythm の x ごとに shape の度数を順に（1 根・3・5・7・8 オクターブ上・-5 下の 5 度・~ 次の小節の根へ半音下から）"},
	{"arp", "mus.arp(chords, pattern, rhythm=\"xxxxxxxxxxxxxxxx\", inst=, octave=4, vol=)", "分散和音: rhythm の x ごとに pattern の番号（和音の音を下から 0・1・2…。音の数を超えると 1 オクターブ上）を順に"},
	{"drums", "mus.drums(pattern, kit)", "1 小節の太鼓: pattern = {楽器の役: 16 字（x 打つ・1〜9 と a〜f は音量つき）}・kit = {役: 段の文字（\"C-4 kick\"）}。重なれば pattern の先の役が勝つ"},
	{"transpose", "mus.transpose(part, n)", "半音 n だけ上げ下げ（音のある段だけ）"},
	{"echo", "mus.echo(part, steps=3, vol=-4, inst=, transpose=0)", "機種の中のエコー: steps 段遅らせた写し（はみ出した尾は頭へ回す）。音量は vol 段下げる（別のチャンネルに置く）"},
	{"with_inst", "mus.with_inst(part, inst)", "音のある段の楽器を替える（B で音色を替える）"},
	{"rest", "mus.rest(bars=1)", "休みの小節（頭の段で前の音を離し OFF・残りは空の段。16 × bars）"},
	{"bars", "mus.bars(part)", "小節の数"},
}

// writeChipKeys は snd.write_chip に渡す dict の鍵。
var writeChipKeys = []struct{ Key, Summary string }{
	{"bpm", "速さ（4 分音符/分）"},
	{"ticks", "1 段の tick（既定 6）"},
	{"groove", "段ごとの tick の並び（跳ねる）"},
	{"gain", "全体の倍率"},
	{"channels", "チャンネルの並び [{name, part, vol, pan, cents, sub, duck, send}]"},
	{"instruments", "楽器（表の形 vol・arp・pitch・duty か rows）"},
	{"waves", "波形メモリの形（32 段 × 0〜15）"},
	{"fx", "機種の外の厚み {reverb, delay, sidechain}"},
	{"intro", "頭（1 回だけ鳴らす）{チャンネル: part}"},
	{"body", "本編（ループする）{チャンネル: part}。intro と body の頭の段が空なら OFF に替える（前の周の最後の音を残さない。継ぎ目をまたいで伸ばすなら頭を \"---\"）"},
}

func musModule() *starlarkstruct.Module {
	fns := map[string]func(*starlark.Thread, *starlark.Builtin, starlark.Tuple, []starlark.Tuple) (starlark.Value, error){
		"chords": musChords, "mml": musMML, "comp": musComp, "bass": musBass, "arp": musArp, "drums": musDrums,
		"transpose": musTranspose, "echo": musEcho, "with_inst": musWithInst, "rest": musRest, "bars": musBars,
	}
	m := &starlarkstruct.Module{Name: "mus", Members: starlark.StringDict{}}
	for _, f := range musFuncs {
		m.Members[f.Name] = starlark.NewBuiltin("mus."+f.Name, fns[f.Name])
	}
	return m
}

// ── 和音 ──

type chord struct {
	root  int   // 0〜11（C = 0）
	tones []int // 根からの半音（低い順）
	bass  int   // 低音（0〜11。/ が無ければ root）
	name  string
}

var chordQualities = map[string][]int{
	"": {0, 4, 7}, "m": {0, 3, 7}, "7": {0, 4, 7, 10}, "maj7": {0, 4, 7, 11}, "M7": {0, 4, 7, 11}, "m7": {0, 3, 7, 10},
	"dim": {0, 3, 6}, "aug": {0, 4, 8}, "sus4": {0, 5, 7}, "sus2": {0, 2, 7}, "6": {0, 4, 7, 9}, "m6": {0, 3, 7, 9},
	"add9": {0, 4, 7, 14}, "9": {0, 4, 7, 10, 14}, "m9": {0, 3, 7, 10, 14}, "m7b5": {0, 3, 6, 10}, "dim7": {0, 3, 6, 9},
	"7sus4": {0, 5, 7, 10},
}

var noteClass = map[byte]int{'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}

func parseRoot(s string) (int, string, bool) {
	if s == "" {
		return 0, "", false
	}
	pc, ok := noteClass[s[0]]
	if !ok {
		return 0, "", false
	}
	rest := s[1:]
	if strings.HasPrefix(rest, "#") {
		pc, rest = pc+1, rest[1:]
	} else if strings.HasPrefix(rest, "b") && !strings.HasPrefix(rest, "b5") {
		pc, rest = pc-1, rest[1:]
	}
	return (pc + 12) % 12, rest, true
}

func parseChord(sym string) (chord, error) {
	main, slash, hasSlash := strings.Cut(sym, "/")
	root, q, ok := parseRoot(main)
	if !ok {
		return chord{}, fmt.Errorf("和音 %q の根が読めない（C D E F G A B と # か b）", sym)
	}
	tones, ok := chordQualities[q]
	if !ok {
		keys := make([]string, 0, len(chordQualities))
		for k := range chordQualities {
			keys = append(keys, "C"+k)
		}
		sort.Strings(keys)
		return chord{}, fmt.Errorf("和音 %q の種類 %q を知らない（%s）", sym, q, strings.Join(keys, " "))
	}
	c := chord{root: root, tones: tones, bass: root, name: sym}
	if hasSlash {
		b, rest, ok := parseRoot(slash)
		if !ok || rest != "" {
			return chord{}, fmt.Errorf("和音 %q の / の後の低音が読めない", sym)
		}
		c.bass = b
	}
	return c, nil
}

// progBars は mus.chords の返り値（小節ごとの和音の並び）を読み直す。
func progBars(v starlark.Value) ([][]chord, error) {
	l, ok := v.(*starlark.List)
	if !ok {
		return nil, fmt.Errorf("和音の進行は mus.chords(…) の返り値で渡す（got %s）", v.Type())
	}
	var out [][]chord
	for i := 0; i < l.Len(); i++ {
		bar, ok := l.Index(i).(*starlark.List)
		if !ok {
			return nil, fmt.Errorf("和音の進行の %d 小節目が並びでない", i+1)
		}
		var cs []chord
		for j := 0; j < bar.Len(); j++ {
			s, ok := starlark.AsString(bar.Index(j))
			if !ok {
				return nil, fmt.Errorf("和音の進行の %d 小節目の和音は文字列", i+1)
			}
			c, err := parseChord(s)
			if err != nil {
				return nil, err
			}
			cs = append(cs, c)
		}
		if len(cs) == 0 {
			return nil, fmt.Errorf("和音の進行の %d 小節目が空", i+1)
		}
		out = append(out, cs)
	}
	return out, nil
}

// chordAt は小節 bar の段 i（0〜15）の和音。
func chordAt(prog [][]chord, bar, i int) chord {
	cs := prog[bar%len(prog)]
	return cs[min(len(cs)-1, i*len(cs)/phraseSteps)]
}

func musChords(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var text string
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "text", &text); err != nil {
		return nil, err
	}
	var bars []starlark.Value
	for i, bar := range strings.Split(text, "|") {
		var cs []starlark.Value
		for _, w := range wordsOf(bar) {
			if _, err := parseChord(w); err != nil {
				return nil, fmt.Errorf("%s: %d 小節目: %v", b.Name(), i+1, err)
			}
			cs = append(cs, starlark.String(w))
		}
		if len(cs) == 0 {
			return nil, fmt.Errorf("%s: %d 小節目に和音が無い", b.Name(), i+1)
		}
		if phraseSteps%len(cs) != 0 {
			return nil, fmt.Errorf("%s: %d 小節目の和音 %d 個は 16 段を割り切れない（1・2・4 個）", b.Name(), i+1, len(cs))
		}
		bars = append(bars, starlark.NewList(cs))
	}
	return starlark.NewList(bars), nil
}

// ── 段の文字 ──

var noteNames = []string{"C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"}

func noteText(n int) string {
	n = max(0, min(119, n))
	return fmt.Sprintf("%s%d", noteNames[n%12], n/12-1)
}

// stepText は音のある段の文字（"C#5 lead v12 SLD 2"）。
func stepText(note int, inst string, vol int, cmds string) string {
	parts := []string{noteText(note)}
	if inst != "" {
		parts = append(parts, inst)
	}
	if vol >= 0 {
		parts = append(parts, fmt.Sprintf("v%d", vol))
	}
	if cmds = strings.TrimSpace(cmds); cmds != "" {
		parts = append(parts, cmds)
	}
	return strings.Join(parts, " ")
}

func partList(steps []string) *starlark.List {
	vs := make([]starlark.Value, len(steps))
	for i, s := range steps {
		vs[i] = starlark.String(s)
	}
	return starlark.NewList(vs)
}

func partOf(fn string, v starlark.Value) ([]string, error) {
	l, ok := v.(*starlark.List)
	if !ok {
		return nil, fmt.Errorf("%s: 段の並びは list（got %s）", fn, v.Type())
	}
	out := make([]string, l.Len())
	for i := range out {
		s, ok := starlark.AsString(l.Index(i))
		if !ok {
			return nil, fmt.Errorf("%s: 段 %d が文字列でない", fn, i)
		}
		out[i] = s
	}
	return out, nil
}

// ── mml ──

type mmlState struct {
	octave, length, vol, quantize, ticks int
	inst                                 string
}

func musMML(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var text, inst string
	octave, length, quantize, ticks := 5, 8, 8, 6
	vol := starlark.Value(starlark.None)
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "text", &text, "inst?", &inst, "octave?", &octave,
		"length?", &length, "vol?", &vol, "quantize?", &quantize, "ticks?", &ticks); err != nil {
		return nil, err
	}
	st := mmlState{octave: octave, length: length, vol: -1, quantize: quantize, ticks: max(1, ticks), inst: inst}
	if v, ok := vol.(starlark.Int); ok {
		n, _ := v.Int64()
		st.vol = int(n)
	}
	steps, err := parseMML(text, st)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", b.Name(), err)
	}
	return partList(steps), nil
}

func stepsOfLength(n int, dots int) (int, bool) {
	base := map[int]int{1: 16, 2: 8, 4: 4, 8: 2, 16: 1}[n]
	if base == 0 {
		return 0, false
	}
	total, add := base, base
	for d := 0; d < dots; d++ {
		if add%2 != 0 {
			return 0, false
		}
		add /= 2
		total += add
	}
	return total, true
}

func parseMML(text string, st mmlState) ([]string, error) {
	var out []string
	r := []rune(text)
	i := 0
	bar := 1
	pending := ""     // 次の音に付けるコマンド
	lastNote := -1    // 最後に鳴らした音の頭の段（^ でのばす）
	sounding := false // 今の段で音が鳴っているか（r の OFF を 1 回だけ書く）
	var last struct {
		note, vol, steps int
		inst, cmds       string
	}
	// put は最後の音を書き直す。q が 8 未満なら長さ × q/8 の tick で離す（CUT。段の格子より細かく切れる）。
	put := func() {
		cmds := last.cmds
		if st.quantize < 8 {
			cmds = strings.TrimSpace(cmds + fmt.Sprintf(" CUT %d", max(1, last.steps*st.ticks*st.quantize/8)))
		}
		out[lastNote] = stepText(last.note, last.inst, last.vol, cmds)
	}
	readInt := func() (int, bool) {
		j := i
		if j < len(r) && r[j] == '-' {
			j++
		}
		k := j
		for k < len(r) && r[k] >= '0' && r[k] <= '9' {
			k++
		}
		if k == j {
			return 0, false
		}
		n, _ := atoi(string(r[i:k]))
		i = k
		return n, true
	}
	readLen := func() (int, error) {
		n, ok := readInt()
		if !ok {
			n = st.length
		}
		dots := 0
		for i < len(r) && r[i] == '.' {
			dots++
			i++
		}
		s, ok := stepsOfLength(n, dots)
		if !ok {
			return 0, fmt.Errorf("%d 小節目: 長さ %d%s は 16 分の格子に乗らない", bar, n, strings.Repeat(".", dots))
		}
		return s, nil
	}
	for i < len(r) {
		c := r[i]
		i++
		switch {
		case c == ' ' || c == '\t' || c == '\n':
		case c == '|':
			if len(out) != bar*phraseSteps {
				return nil, fmt.Errorf("%d 小節目の長さが %d 段（16 段のはず）", bar, len(out)-(bar-1)*phraseSteps)
			}
			bar++
		case c == 'o':
			n, ok := readInt()
			if !ok {
				return nil, fmt.Errorf("%d 小節目: o の後に数", bar)
			}
			st.octave = n
		case c == '<':
			st.octave--
		case c == '>':
			st.octave++
		case c == 'l':
			n, ok := readInt()
			if _, good := stepsOfLength(n, 0); !ok || !good {
				return nil, fmt.Errorf("%d 小節目: l の後は 1 2 4 8 16", bar)
			}
			st.length = n
		case c == 'v':
			n, ok := readInt()
			if !ok || n < 0 || n > 15 {
				return nil, fmt.Errorf("%d 小節目: v の後は 0〜15", bar)
			}
			st.vol = n
		case c == 'q':
			n, ok := readInt()
			if !ok || n < 1 || n > 8 {
				return nil, fmt.Errorf("%d 小節目: q の後は 1〜8", bar)
			}
			st.quantize = n
		case c == '@':
			j := i
			for i < len(r) && r[i] != ' ' && r[i] != '|' && r[i] != '\t' && r[i] != '\n' {
				i++
			}
			st.inst = string(r[j:i])
		case c == '{':
			j := i
			for i < len(r) && r[i] != '}' {
				i++
			}
			if i >= len(r) {
				return nil, fmt.Errorf("%d 小節目: { が閉じていない", bar)
			}
			pending = strings.TrimSpace(pending + " " + string(r[j:i]))
			i++
		case c == 'r':
			n, err := readLen()
			if err != nil {
				return nil, err
			}
			for k := 0; k < n; k++ {
				if k == 0 && sounding {
					out = append(out, "OFF")
				} else {
					out = append(out, "")
				}
			}
			sounding, lastNote = false, -1
		case c == '^':
			if lastNote < 0 {
				return nil, fmt.Errorf("%d 小節目: ^ の前に音が無い", bar)
			}
			n, err := readLen()
			if err != nil {
				return nil, err
			}
			out = append(out, make([]string, n)...)
			last.steps += n
			put()
		case strings.ContainsRune("cdefgab", c):
			pc := noteClass[byte(c-'a'+'A')]
			for i < len(r) && (r[i] == '+' || r[i] == '#' || r[i] == '-') {
				if r[i] == '-' {
					pc--
				} else {
					pc++
				}
				i++
			}
			n, err := readLen()
			if err != nil {
				return nil, err
			}
			lastNote = len(out)
			out = append(out, make([]string, n)...)
			last.note, last.vol, last.steps, last.inst, last.cmds = 12*(st.octave+1)+pc, st.vol, n, st.inst, pending
			put()
			pending, sounding = "", true
		default:
			return nil, fmt.Errorf("%d 小節目: 知らない字 %q", bar, string(c))
		}
	}
	if len(out)%phraseSteps != 0 {
		return nil, fmt.Errorf("全体が %d 段（16 段 = 1 小節の倍数でない。最後の小節が %d 段）", len(out), len(out)%phraseSteps)
	}
	return out, nil
}

// ── 進行から作る部品 ──

type rhythmArgs struct {
	rhythms []string
	inst    string
	octave  int
	vol     int
}

func readRhythms(fn string, v starlark.Value) ([]string, error) {
	var rs []string
	switch x := v.(type) {
	case starlark.String:
		rs = []string{string(x)}
	case *starlark.List:
		for i := 0; i < x.Len(); i++ {
			s, ok := starlark.AsString(x.Index(i))
			if !ok {
				return nil, fmt.Errorf("%s: rhythm の並びは文字列", fn)
			}
			rs = append(rs, s)
		}
	default:
		return nil, fmt.Errorf("%s: rhythm は 16 字の文字列か、その並び（小節ごとに回す）", fn)
	}
	for _, s := range rs {
		s = strings.ReplaceAll(s, " ", "")
		if len(s) != phraseSteps || strings.Trim(s, "x-.") != "" {
			return nil, fmt.Errorf("%s: rhythm %q は x（打つ）・-（のばす）・.（離す）で 16 字", fn, s)
		}
	}
	for i := range rs {
		rs[i] = strings.ReplaceAll(rs[i], " ", "")
	}
	return rs, nil
}

func volOf(v starlark.Value) int {
	if n, ok := v.(starlark.Int); ok {
		x, _ := n.Int64()
		return int(max(0, min(15, x)))
	}
	return -1
}

// voiced は和音の根の高さ（octave の C からの高さ。低音を使うなら bass の音）。
func rootNote(c chord, octave int, useBass bool) int {
	pc := c.root
	if useBass {
		pc = c.bass
	}
	return 12*(octave+1) + pc
}

// fromRhythm は進行の小節ごとに rhythm の x を打ち、hit(小節, 段, 何回目) の文字を置く（. は離す・- と空はのばす）。
func fromRhythm(prog [][]chord, rs []string, hit func(bar, i, k int) string) []string {
	var out []string
	for bar := range prog {
		r := rs[bar%len(rs)]
		k := 0
		for i := 0; i < phraseSteps; i++ {
			switch r[i] {
			case 'x':
				out = append(out, hit(bar, i, k))
				k++
			case '.':
				if i == 0 || r[i-1] != '.' {
					out = append(out, "OFF")
				} else {
					out = append(out, "")
				}
			default:
				out = append(out, "")
			}
		}
	}
	return out
}

func unpackProg(b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple, extra ...any) ([][]chord, rhythmArgs, error) {
	var progV, rhythmV starlark.Value
	ra := rhythmArgs{octave: 4}
	volV := starlark.Value(starlark.None)
	pairs := append([]any{"chords", &progV, "rhythm", &rhythmV}, extra...)
	pairs = append(pairs, "inst?", &ra.inst, "octave?", &ra.octave, "vol?", &volV)
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, pairs...); err != nil {
		return nil, ra, err
	}
	prog, err := progBars(progV)
	if err != nil {
		return nil, ra, fmt.Errorf("%s: %v", b.Name(), err)
	}
	if ra.rhythms, err = readRhythms(b.Name(), rhythmV); err != nil {
		return nil, ra, err
	}
	ra.vol = volOf(volV)
	return prog, ra, nil
}

func musComp(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	tones := 3
	prog, ra, err := unpackProg(b, args, kwargs, "tones?", &tones)
	if err != nil {
		return nil, err
	}
	steps := fromRhythm(prog, ra.rhythms, func(bar, i, _ int) string {
		c := chordAt(prog, bar, i)
		ts := c.tones[:min(len(c.tones), max(1, tones))]
		arp := make([]string, len(ts))
		for k, t := range ts {
			arp[k] = fmt.Sprint(t)
		}
		return stepText(rootNote(c, ra.octave, false), ra.inst, ra.vol, "ARP "+strings.Join(arp, " "))
	})
	return partList(steps), nil
}

func musBass(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	shapeV := starlark.Value(starlark.NewList([]starlark.Value{starlark.String("1")}))
	prog, ra, err := unpackProg(b, args, kwargs, "shape?", &shapeV)
	if err != nil {
		return nil, err
	}
	if !hasKw(kwargs, "octave") {
		ra.octave = 2
	}
	shape, err := partOf(b.Name()+" の shape", shapeV)
	if err != nil {
		return nil, err
	}
	for _, s := range shape {
		if !map[string]bool{"1": true, "3": true, "5": true, "7": true, "8": true, "-5": true, "~": true}[s] {
			return nil, fmt.Errorf("%s: shape の %q を知らない（1 3 5 7 8 -5 ~）", b.Name(), s)
		}
	}
	steps := fromRhythm(prog, ra.rhythms, func(bar, i, k int) string {
		c := chordAt(prog, bar, i)
		root := rootNote(c, ra.octave, true)
		third, fifth := c.tones[min(1, len(c.tones)-1)], c.tones[min(2, len(c.tones)-1)]
		var n int
		switch shape[k%len(shape)] {
		case "1":
			n = root
		case "3":
			n = rootNote(c, ra.octave, false) + third
		case "5":
			n = rootNote(c, ra.octave, false) + fifth
		case "7":
			n = rootNote(c, ra.octave, false) + 12
			if len(c.tones) > 3 {
				n = rootNote(c, ra.octave, false) + c.tones[3]
			}
		case "8":
			n = root + 12
		case "-5":
			n = rootNote(c, ra.octave, false) + fifth - 12
		case "~":
			next := chordAt(prog, bar+1, 0)
			n = rootNote(next, ra.octave, true) - 1
		}
		return stepText(n, ra.inst, ra.vol, "")
	})
	return partList(steps), nil
}

func hasKw(kwargs []starlark.Tuple, name string) bool {
	for _, kv := range kwargs {
		if s, _ := starlark.AsString(kv[0]); s == name {
			return true
		}
	}
	return false
}

func musArp(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var progV, patV starlark.Value
	rhythmV := starlark.Value(starlark.String(strings.Repeat("x", phraseSteps)))
	ra := rhythmArgs{octave: 4}
	volV := starlark.Value(starlark.None)
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "chords", &progV, "pattern", &patV, "rhythm?", &rhythmV,
		"inst?", &ra.inst, "octave?", &ra.octave, "vol?", &volV); err != nil {
		return nil, err
	}
	prog, err := progBars(progV)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", b.Name(), err)
	}
	if ra.rhythms, err = readRhythms(b.Name(), rhythmV); err != nil {
		return nil, err
	}
	ra.vol = volOf(volV)
	pl, ok := patV.(*starlark.List)
	if !ok || pl.Len() == 0 {
		return nil, fmt.Errorf("%s: pattern は和音の音の番号の並び（[0, 1, 2, 1]）", b.Name())
	}
	var pat []int
	for i := 0; i < pl.Len(); i++ {
		n, err := starlark.AsInt32(pl.Index(i))
		if err != nil {
			return nil, fmt.Errorf("%s: pattern は整数の並び", b.Name())
		}
		pat = append(pat, n)
	}
	steps := fromRhythm(prog, ra.rhythms, func(bar, i, k int) string {
		c := chordAt(prog, bar, i)
		idx := pat[k%len(pat)]
		oct := idx / len(c.tones)
		if idx < 0 {
			oct = (idx - len(c.tones) + 1) / len(c.tones)
		}
		t := c.tones[((idx%len(c.tones))+len(c.tones))%len(c.tones)]
		return stepText(rootNote(c, ra.octave, false)+t+12*oct, ra.inst, ra.vol, "")
	})
	return partList(steps), nil
}

func musDrums(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var pat, kit *starlark.Dict
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "pattern", &pat, "kit", &kit); err != nil {
		return nil, err
	}
	out := make([]string, phraseSteps)
	for _, item := range pat.Items() {
		role, _ := starlark.AsString(item[0])
		line, ok := starlark.AsString(item[1])
		line = strings.ReplaceAll(line, " ", "")
		if !ok || len(line) != phraseSteps {
			return nil, fmt.Errorf("%s: %s の並びは 16 字", b.Name(), role)
		}
		kv, found, _ := kit.Get(item[0])
		text, _ := starlark.AsString(kv)
		if !found || text == "" {
			return nil, fmt.Errorf("%s: kit に %s の段の文字が無い", b.Name(), role)
		}
		for i, ch := range line {
			if out[i] != "" || ch == '.' || ch == '-' {
				continue
			}
			vol := ""
			switch {
			case ch == 'x':
			case ch >= '1' && ch <= '9':
				vol = fmt.Sprintf(" v%d", ch-'0')
			case ch >= 'a' && ch <= 'f':
				vol = fmt.Sprintf(" v%d", ch-'a'+10)
			default:
				return nil, fmt.Errorf("%s: %s の字 %q（x・. と 1〜9・a〜f の音量）", b.Name(), role, string(ch))
			}
			out[i] = text + vol
		}
	}
	return partList(out), nil
}

// ── 並びを変える ──

// mapNotes は音のある段の（音・楽器・音量・コマンド）を f で替える。
func mapNotes(steps []string, f func(note int, inst string, vol int, cmds string) string) []string {
	out := make([]string, len(steps))
	for i, s := range steps {
		words := wordsOf(s)
		if len(words) == 0 {
			continue
		}
		if p, n := parsePitch(words[0]); p == pitchNote {
			inst, vol := "", -1
			k := 1
			for k < len(words) && !cmdWords[words[k]] {
				if isVolumeWord(words[k]) {
					vol, _ = atoi(words[k][1:])
				} else if inst == "" {
					inst = words[k]
				}
				k++
			}
			out[i] = f(n, inst, vol, strings.Join(words[k:], " "))
			continue
		}
		out[i] = s
	}
	return out
}

func musTranspose(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var pv starlark.Value
	var n int
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "part", &pv, "n", &n); err != nil {
		return nil, err
	}
	steps, err := partOf(b.Name(), pv)
	if err != nil {
		return nil, err
	}
	return partList(mapNotes(steps, func(note int, inst string, vol int, cmds string) string {
		return stepText(note+n, inst, vol, cmds)
	})), nil
}

func musWithInst(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var pv starlark.Value
	var inst string
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "part", &pv, "inst", &inst); err != nil {
		return nil, err
	}
	steps, err := partOf(b.Name(), pv)
	if err != nil {
		return nil, err
	}
	return partList(mapNotes(steps, func(note int, _ string, vol int, cmds string) string {
		return stepText(note, inst, vol, cmds)
	})), nil
}

func musEcho(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var pv starlark.Value
	steps, vol, transpose := 3, -4, 0
	inst := ""
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "part", &pv, "steps?", &steps, "vol?", &vol, "inst?", &inst, "transpose?", &transpose); err != nil {
		return nil, err
	}
	src, err := partOf(b.Name(), pv)
	if err != nil {
		return nil, err
	}
	if len(src) == 0 || steps < 0 {
		return partList(src), nil
	}
	moved := mapNotes(src, func(note int, in string, v int, cmds string) string {
		if inst != "" {
			in = inst
		}
		if v < 0 {
			v = 15
		}
		return stepText(note+transpose, in, max(0, min(15, v+vol)), cmds)
	})
	k := steps % len(moved)
	out := append(append([]string{}, moved[len(moved)-k:]...), moved[:len(moved)-k]...)
	return partList(out), nil
}

func musRest(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	bars := 1
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "bars?", &bars); err != nil {
		return nil, err
	}
	steps := make([]string, phraseSteps*max(0, bars))
	if len(steps) > 0 {
		steps[0] = "OFF" // 休みは前の音を離す（空の段だけだと、持続のループを持つ楽器は次の音まで鳴り続ける）
	}
	return partList(steps), nil
}

func musBars(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var pv starlark.Value
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "part", &pv); err != nil {
		return nil, err
	}
	steps, err := partOf(b.Name(), pv)
	if err != nil {
		return nil, err
	}
	return starlark.MakeInt(len(steps) / phraseSteps), nil
}

// ── snd.write_chip ──

// buildChip は write_chip の dict（part の並びで書いた曲）を譜面の JSON にする。
// 同じ中身の小節は 1 つの phrase にまとめ、チャンネルごとに intro・body の chain を作る（intro があれば rows の 1 行目・loop は body）。
func buildChip(v map[string]any) (map[string]any, error) {
	for k := range v {
		found := false
		for _, w := range writeChipKeys {
			found = found || w.Key == k
		}
		if !found && k != "note" && k != "version" {
			keys := make([]string, len(writeChipKeys))
			for i, w := range writeChipKeys {
				keys[i] = w.Key
			}
			return nil, fmt.Errorf("知らない鍵 %q（%s）", k, strings.Join(keys, " "))
		}
	}
	body, ok := v["body"].(map[string]any)
	if !ok || len(body) == 0 {
		return nil, fmt.Errorf("body（ループする本編 {チャンネル: 段の並び}）が無い")
	}
	out := map[string]any{"version": 1}
	for _, k := range []string{"note", "bpm", "ticks", "groove", "gain", "channels", "instruments", "waves", "fx"} {
		if x, ok := v[k]; ok {
			out[k] = x
		}
	}
	phrases := map[string]any{}
	byContent := map[string]string{}
	chains := map[string]any{}
	var rows []any
	count := map[string]int{}
	for _, sec := range []string{"intro", "body"} {
		parts, ok := v[sec].(map[string]any)
		if !ok {
			continue
		}
		bars := 0
		names := sortedKeys(parts)
		lists := map[string][]string{}
		for _, ch := range names {
			steps := stringsOf(parts[ch])
			if steps == nil && parts[ch] != nil {
				if l, ok := parts[ch].([]any); !ok || len(l) > 0 {
					return nil, fmt.Errorf("%s.%s は段の文字列の並び", sec, ch)
				}
			}
			if len(steps)%phraseSteps != 0 {
				return nil, fmt.Errorf("%s.%s は %d 段（16 段 = 1 小節の倍数でない）", sec, ch, len(steps))
			}
			lists[ch] = steps
			bars = max(bars, len(steps)/phraseSteps)
		}
		for _, ch := range names {
			if n := len(lists[ch]) / phraseSteps; n != bars && n > 0 {
				var lens []string
				for _, c := range names {
					lens = append(lens, fmt.Sprintf("%s %d", c, len(lists[c])/phraseSteps))
				}
				return nil, fmt.Errorf("%s の小節の数がそろっていない（%s。空の並びは休みで埋める）", sec, strings.Join(lens, "・"))
			}
		}
		row := map[string]any{}
		for _, ch := range names {
			steps := lists[ch]
			for len(steps) < bars*phraseSteps {
				steps = append(steps, make([]string, phraseSteps)...)
			}
			if len(steps) > 0 && steps[0] == "" { // 部分の頭が空なら前の音を離す（ループの 2 周目に 1 周目の最後の音を残さない）
				steps = append([]string{"OFF"}, steps[1:]...)
			}
			var chain []any
			for bar := 0; bar < bars; bar++ {
				ph := steps[bar*phraseSteps : (bar+1)*phraseSteps]
				end := len(ph)
				for end > 0 && ph[end-1] == "" {
					end--
				}
				key := strings.Join(ph[:end], "\x00")
				name, ok := byContent[key]
				if !ok {
					count[ch]++
					name = fmt.Sprintf("%s%d", ch, count[ch])
					if end == 0 {
						name = "_"
					}
					byContent[key] = name
					cells := make([]any, end)
					for i, s := range ph[:end] {
						cells[i] = s
					}
					phrases[name] = cells
				}
				chain = append(chain, name)
			}
			cname := sec + "_" + ch
			chains[cname] = chain
			row[ch] = cname
		}
		rows = append(rows, row)
	}
	out["phrases"] = phrases
	out["chains"] = chains
	out["rows"] = rows
	out["loop"] = len(rows) - 1
	return out, nil
}

func (st *starState) writeChip(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var path string
	var value starlark.Value
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "path", &path, "value", &value); err != nil {
		return nil, err
	}
	if _, ok := value.(*starlark.Dict); !ok {
		return nil, fmt.Errorf("%s: 値は dict（got %s）", b.Name(), value.Type())
	}
	clean, err := st.OutPath(b.Name(), path, ".chip.json")
	if err != nil {
		return nil, err
	}
	js, err := starbox.JSON(value, -1)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", b.Name(), err)
	}
	var v map[string]any
	if err := json.Unmarshal([]byte(js), &v); err != nil {
		return nil, fmt.Errorf("%s: %v", b.Name(), err)
	}
	chip, err := buildChip(v)
	if err != nil {
		return nil, fmt.Errorf("%s(%q): %v", b.Name(), path, err)
	}
	data, err := chipJSON(chip)
	if err != nil {
		return nil, err
	}
	probe := &rctx{rate: 44100, files: map[string][]byte{clean: data}}
	sp, err := loadSong(probe, clean)
	if err == nil {
		_, err = loadInstruments(probe, "", sp.inline)
	}
	if err != nil {
		return nil, fmt.Errorf("%s(%q): 譜面として読めない: %v", b.Name(), path, err)
	}
	st.put(clean, data)
	return starlark.String(path), nil
}

// chipJSON は譜面を読みやすい形で書く: 上の鍵は決まった順に 1 行ずつ、phrases・chains・instruments などの中身は 1 つ 1 行。
func chipJSON(chip map[string]any) ([]byte, error) {
	var b strings.Builder
	b.WriteString("{\n")
	order := []string{"version", "note", "bpm", "ticks", "groove", "gain", "loop", "channels", "fx", "instruments", "waves", "phrases", "chains", "rows"}
	first := true
	for _, k := range order {
		v, ok := chip[k]
		if !ok {
			continue
		}
		if !first {
			b.WriteString(",\n")
		}
		first = false
		key, _ := json.Marshal(k)
		b.WriteString(" ")
		b.Write(key)
		b.WriteString(": ")
		switch x := v.(type) {
		case map[string]any:
			if k == "fx" {
				break
			}
			b.WriteString("{")
			for i, name := range sortedKeys(x) {
				one, err := json.Marshal(x[name])
				if err != nil {
					return nil, err
				}
				nk, _ := json.Marshal(name)
				if i > 0 {
					b.WriteString(",")
				}
				fmt.Fprintf(&b, "\n  %s: %s", nk, one)
			}
			b.WriteString("\n }")
			continue
		case []any:
			if k == "channels" || k == "rows" {
				b.WriteString("[")
				for i, e := range x {
					one, err := json.Marshal(e)
					if err != nil {
						return nil, err
					}
					if i > 0 {
						b.WriteString(",")
					}
					fmt.Fprintf(&b, "\n  %s", one)
				}
				b.WriteString("\n ]")
				continue
			}
		}
		one, err := json.Marshal(v)
		if err != nil {
			return nil, err
		}
		b.Write(one)
	}
	b.WriteString("\n}\n")
	return []byte(b.String()), nil
}
