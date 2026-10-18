package snd

import "testing"

// 外れる例: テストのほかの所で出ない code（alias・style.duty・style.noise-kind）も、got と want つきで出る。
func TestRareCodesFire(t *testing.T) {
	for _, c := range []struct{ name, js, code string }{
		{"パルスの 3 倍音が折り返す", `{"target": "debug/x.wav", "voices": [{"ops": [{"pulse": {"hz": 9000, "ms": 50, "amp": 0.2}}]}]}`, "snd.alias"},
		{"gb の外の duty", `{"style": "gb", "target": "debug/x.wav", "voices": [{"ops": [{"pulse": {"hz": 440, "duty": 0.3, "ms": 50, "amp": 0.2}}]}]}`, "snd.style.duty"},
		{"gb の外の雑音", `{"style": "gb", "target": "debug/x.wav", "voices": [{"ops": [{"noise": {"kind": "hash", "ms": 50, "amp": 0.2}}]}]}`, "snd.style.noise-kind"},
	} {
		br := check(t, c.js)
		found := false
		for _, r := range br.Check.Results {
			if r.Code == c.code {
				found = true
				if len(r.Fix.Try) == 0 || r.Fix.Try[0].Expect == nil {
					t.Errorf("%s: 数の候補と見込みが無い: %+v", c.name, r.Fix)
				}
			}
		}
		if !found {
			t.Errorf("%s: %s が出ない: %v", c.name, c.code, br.Findings)
		}
	}
}
