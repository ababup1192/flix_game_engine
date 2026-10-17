package carve

// 引数の読み取りと sprite.json の書き出し。
//
// WhyNot: 引数が間違っているとき (未知のオプション等) の字面はそろえていない。
// 使い方の案内には実行ファイル名が入るので、呼び口が変わると字面も変わる。

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

type options struct {
	image string
	flags map[string]string
}

func (o *options) str(name, def string) string {
	if v, ok := o.flags[name]; ok {
		return v
	}
	return def
}

func (o *options) num(name string, def int) (int, error) {
	v, ok := o.flags[name]
	if !ok {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("--%s には数を渡してください: %s", name, v)
	}
	return n, nil
}

func parseArgs(args []string, known map[string]bool) (*options, error) {
	out := &options{flags: map[string]string{}}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "--") {
			if out.image == "" {
				out.image = a
				continue
			}
			return nil, fmt.Errorf("受け取れない引数: %s", a)
		}
		name, value := strings.TrimPrefix(a, "--"), ""
		hasValue := false
		if at := strings.Index(name, "="); at >= 0 {
			name, value, hasValue = name[:at], name[at+1:], true
		}
		if !known[name] {
			return nil, fmt.Errorf("知らないオプション: --%s", name)
		}
		if !hasValue {
			if i+1 >= len(args) {
				return nil, fmt.Errorf("--%s には値が要ります", name)
			}
			i++
			value = args[i]
		}
		out.flags[name] = value
	}
	return out, nil
}

// applyProfile は体型のつまみを JSON で上書きする (書いたキーだけ)。
func applyProfile(profile *Profile, path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	for key, value := range raw {
		var err error
		switch key {
		case "feetShare":
			err = json.Unmarshal(value, &profile.FeetShare)
		case "headRatio":
			err = json.Unmarshal(value, &profile.HeadRatio)
		case "hipRatio":
			err = json.Unmarshal(value, &profile.HipRatio)
		case "coreTrimPct":
			err = json.Unmarshal(value, &profile.CoreTrimPct)
		case "tubeMargin":
			err = json.Unmarshal(value, &profile.TubeMargin)
		case "toneStep":
			err = json.Unmarshal(value, &profile.ToneStep)
		case "tool":
			err = json.Unmarshal(value, &profile.Tool)
		case "reach":
			err = json.Unmarshal(value, &profile.Reach)
		case "liftAt":
			err = json.Unmarshal(value, &profile.LiftAt)
		case "crumbLimit":
			err = json.Unmarshal(value, &profile.CrumbLimit)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

// writeSpriteDoc は sprite.json を字下げ 2 で書く。
func writeSpriteDoc(path, id, note string, palette, legend *pxlib.OMap[string, string],
	sprites *pxlib.OMap[string, *spriteEntry]) error {
	var b strings.Builder
	b.WriteString("{\n")
	b.WriteString("  \"version\": 1,\n")
	fmt.Fprintf(&b, "  \"entityId\": %s,\n", pxlib.JSONString(id))
	fmt.Fprintf(&b, "  \"note\": %s,\n", pxlib.JSONString(note))
	writeStringMap(&b, "palette", palette, "  ")
	b.WriteString(",\n")
	writeStringMap(&b, "legend", legend, "  ")
	b.WriteString(",\n")
	b.WriteString("  \"sprites\": {")
	names := sprites.Keys()
	for i, name := range names {
		entry, _ := sprites.Get(name)
		if i > 0 {
			b.WriteString(",")
		}
		fmt.Fprintf(&b, "\n    %s: {\n", pxlib.JSONString(name))
		b.WriteString("      \"anchor\": {\n")
		fmt.Fprintf(&b, "        \"x\": %d,\n", entry.anchorX)
		fmt.Fprintf(&b, "        \"y\": %d\n", entry.anchorY)
		b.WriteString("      },\n")
		b.WriteString("      \"frames\": {")
		poses := entry.frames.Keys()
		for j, pose := range poses {
			rows, _ := entry.frames.Get(pose)
			if j > 0 {
				b.WriteString(",")
			}
			fmt.Fprintf(&b, "\n        %s: [", pxlib.JSONString(pose))
			for k, row := range rows {
				if k > 0 {
					b.WriteString(",")
				}
				fmt.Fprintf(&b, "\n          %s", pxlib.JSONString(row))
			}
			if len(rows) == 0 {
				b.WriteString("]")
			} else {
				b.WriteString("\n        ]")
			}
		}
		if len(poses) == 0 {
			b.WriteString("}")
		} else {
			b.WriteString("\n      }")
		}
		b.WriteString("\n    }")
	}
	if len(names) == 0 {
		b.WriteString("}")
	} else {
		b.WriteString("\n  }")
	}
	b.WriteString("\n}\n")
	return os.WriteFile(path, []byte(b.String()), 0o644)
}

func writeStringMap(b *strings.Builder, name string, m *pxlib.OMap[string, string], indent string) {
	fmt.Fprintf(b, "%s%s: {", indent, pxlib.JSONString(name))
	keys := m.Keys()
	for i, k := range keys {
		v, _ := m.Get(k)
		if i > 0 {
			b.WriteString(",")
		}
		fmt.Fprintf(b, "\n%s  %s: %s", indent, pxlib.JSONString(k), pxlib.JSONString(v))
	}
	if len(keys) == 0 {
		b.WriteString("}")
		return
	}
	fmt.Fprintf(b, "\n%s}", indent)
}
