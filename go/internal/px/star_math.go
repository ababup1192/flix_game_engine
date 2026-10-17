package px

// 台本の math は crmath（正しく丸めた値。snd の台本と共有）。ここは px の中の呼び名だけ。

import "github.com/ababup1192/flix_game_engine/go/internal/crmath"

var (
	crSin       = crmath.Sin
	crCos       = crmath.Cos
	crExp       = crmath.Exp
	crLog       = crmath.Log
	crPow       = crmath.Pow
	crAtan2     = crmath.Atan2
	crHypot     = crmath.Hypot
	hypot       = crmath.Hypot
	newStarMath = crmath.StarModule
)
