package carve

// JSON を、鍵の並びと字面を保ったまま読む（中身は pxlib.DecodeOrdered）。

import (
	"os"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// readJSONOrdered は JSON を読む。オブジェクトは *pxlib.OMap[string, any] になる。
func readJSONOrdered(path string) (*pxlib.OMap[string, any], error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	v, err := pxlib.DecodeOrdered(data)
	if err != nil {
		return nil, err
	}
	obj, ok := v.(*pxlib.Obj)
	if !ok {
		return pxlib.NewOMap[string, any](), nil
	}
	return obj, nil
}

// jsonString は文字列を JSON の字面にする。非 ASCII は逃がさずそのまま出す。
func jsonString(s string) string { return pxlib.JSONString(s) }
