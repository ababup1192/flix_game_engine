package snd

import (
	"fmt"
	"os"
	"sort"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
)

// TestMain は snd のテスト全部が組み立てた違反を集め、どれも表にある code・表と同じ基準の向き・got と want を持つかを見る
// （「全部の code に got と want が入る」の確かめ。出なかった code は数だけ知らせる）。
func TestMain(m *testing.M) {
	seen := map[string][]finding{}
	seenProbe = func(v finding) { seen[v.code()] = append(seen[v.code()], v) }
	code := m.Run()
	seenProbe = nil
	rules, err := checkres.LoadRules(engineRoot)
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	bad := 0
	for c, vs := range seen {
		func() {
			defer func() {
				if r := recover(); r != nil {
					fmt.Printf("FAIL code %s: %v\n", c, r)
					bad++
				}
			}()
			for _, v := range vs {
				if r := v.result(rules); r.Want.Op == "" {
					panic("want が無い")
				}
			}
		}()
	}
	var missing []string
	for _, c := range checkres.All("snd.") {
		if _, ok := seen[c.Name]; !ok {
			missing = append(missing, c.Name)
		}
	}
	sort.Strings(missing)
	if testing.Verbose() || os.Getenv("CHECK_CODES_COVERAGE") == "1" {
		fmt.Printf("snd の code: テストで出た %d・出なかった %d %v\n", len(checkres.All("snd."))-len(missing), len(missing), missing)
	}
	if bad > 0 && code == 0 {
		code = 1
	}
	os.Exit(code)
}
