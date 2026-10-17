package pxlib

// Oklab（Björn Ottosson, 2020）: 人の目の明るさ・彩度に近い色の座標。
// L が明るさ（0 黒 〜 1 白）。ランプの明るさの並び・地との明度差を測るのに使う。

import (
	"fmt"
	"math"
)

// Oklab は [L, a, b]。
type Oklab [3]float64

func srgbToLinear(c float64) float64 {
	if c <= 0.04045 {
		return c / 12.92
	}
	return math.Pow((c+0.055)/1.055, 2.4)
}

func linearToSrgb(c float64) float64 {
	if c <= 0.0031308 {
		return c * 12.92
	}
	return 1.055*math.Pow(c, 1/2.4) - 0.055
}

// OklabOfRGBA は 8bit の色を Oklab にする。
func OklabOfRGBA(c RGBA) Oklab {
	r := srgbToLinear(float64(c[0]) / 255)
	g := srgbToLinear(float64(c[1]) / 255)
	b := srgbToLinear(float64(c[2]) / 255)
	l := math.Cbrt(0.4122214708*r + 0.5363325363*g + 0.0514459929*b)
	m := math.Cbrt(0.2119034982*r + 0.6806995451*g + 0.1073969566*b)
	s := math.Cbrt(0.0883024619*r + 0.2817188376*g + 0.6299787005*b)
	return Oklab{
		0.2104542553*l + 0.7936177850*m - 0.0040720468*s,
		1.9779984951*l - 2.4285922050*m + 0.4505937099*s,
		0.0259040371*l + 0.7827717662*m - 0.8086757660*s,
	}
}

// OklabOfHex は "#rrggbb" を Oklab にする。読めなければ ok=false。
func OklabOfHex(hex string) (Oklab, bool) {
	if !IsHexColor(hex) {
		return Oklab{}, false
	}
	return OklabOfRGBA(rgbaOfHex(hex)), true
}

// HexOfOklab は Oklab を "#rrggbb" に戻す（sRGB の外は端で切る）。
func HexOfOklab(c Oklab) string {
	l := c[0] + 0.3963377774*c[1] + 0.2158037573*c[2]
	m := c[0] - 0.1055613458*c[1] - 0.0638541728*c[2]
	s := c[0] - 0.0894841775*c[1] - 1.2914855480*c[2]
	l, m, s = l*l*l, m*m*m, s*s*s
	rgb := [3]float64{
		+4.0767416621*l - 3.3077115913*m + 0.2309699292*s,
		-1.2684380046*l + 2.6097574011*m - 0.3413193965*s,
		-0.0041960863*l - 0.7034186147*m + 1.7076147010*s,
	}
	var out [3]int
	for i, v := range rgb {
		n := math.Round(linearToSrgb(math.Max(0, math.Min(1, v))) * 255)
		out[i] = int(n)
	}
	return fmt.Sprintf("#%02x%02x%02x", out[0], out[1], out[2])
}

// Lightness は "#rrggbb" の Oklab の L。読めなければ ok=false。
func Lightness(hex string) (float64, bool) {
	c, ok := OklabOfHex(hex)
	return c[0], ok
}

// HexOfRGBA は "#rrggbb"。
func HexOfRGBA(c RGBA) string { return fmt.Sprintf("#%02x%02x%02x", c[0], c[1], c[2]) }
