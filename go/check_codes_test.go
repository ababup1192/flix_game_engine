package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
)

// docs/check-codes.md は表から書き出した物のまま（bin/fge check codes --md）。checkfmt.json の near の code は表にある。
func TestCheckCodesDocAndRules(t *testing.T) {
	root := filepath.Join("..")
	cur, err := os.ReadFile(filepath.Join(root, "docs", "check-codes.md"))
	if err != nil || string(cur) != checkres.Markdown() {
		t.Error("docs/check-codes.md が code の表とずれている（bin/fge check codes --md）")
	}
	r, err := checkres.LoadRules(root)
	if err != nil {
		t.Fatal(err)
	}
	for code := range r.Near {
		if _, ok := checkres.Lookup(code); !ok {
			t.Errorf("checkfmt.json の near に表に無い code %q", code)
		}
	}
}
