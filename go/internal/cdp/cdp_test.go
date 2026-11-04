package cdp

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"image/color"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestAcceptKeyMatchesRFC6455Example(t *testing.T) {
	if got := acceptKey("dGhlIHNhbXBsZSBub25jZQ=="); got != "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" {
		t.Fatalf("got %q", got)
	}
}

// serverFrame はサーバーから送る（マスクの無い）フレームを組む。
func serverFrame(opcode byte, fin bool, payload []byte) []byte {
	b0 := opcode
	if fin {
		b0 |= 0x80
	}
	n := len(payload)
	var head []byte
	switch {
	case n < 126:
		head = []byte{b0, byte(n)}
	case n <= 0xFFFF:
		head = []byte{b0, 126, byte(n >> 8), byte(n)}
	default:
		head = []byte{b0, 127, 0, 0, 0, 0, byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n)}
	}
	return append(head, payload...)
}

func TestReadMessageJoinsFragmentsAndAnswersPing(t *testing.T) {
	cli, srv := net.Pipe()
	defer cli.Close()
	defer srv.Close()
	c := &wsConn{conn: cli, r: bufio.NewReader(cli)}
	big := strings.Repeat("x", 70000)
	go func() {
		srv.Write(serverFrame(0x9, true, []byte("hi")))
		pong := make([]byte, 2+4+2)
		io.ReadFull(srv, pong)
		srv.Write(serverFrame(0x1, false, []byte("ab")))
		srv.Write(serverFrame(0x0, true, []byte(big)))
	}()
	msg, err := c.readMessage()
	if err != nil {
		t.Fatal(err)
	}
	if string(msg) != "ab"+big {
		t.Fatalf("len %d", len(msg))
	}
}

func TestWriteTextIsMaskedAndDecodable(t *testing.T) {
	cli, srv := net.Pipe()
	defer cli.Close()
	defer srv.Close()
	c := &wsConn{conn: cli, r: bufio.NewReader(cli)}
	payload := []byte(strings.Repeat("y", 300))
	go c.writeText(payload)
	s := &wsConn{conn: srv, r: bufio.NewReader(srv)}
	fin, op, got, err := s.readFrame()
	if err != nil || !fin || op != 0x1 || string(got) != string(payload) {
		t.Fatalf("fin=%v op=%d err=%v len=%d", fin, op, err, len(got))
	}
}

func payloadJSON(t *testing.T, w, h int, pix []byte, origin string) json.RawMessage {
	t.Helper()
	raw, _ := json.Marshal(pixelPayload{Width: w, Height: h, RGBA: base64.StdEncoding.EncodeToString(pix), Origin: origin})
	return raw
}

func TestDecodePayloadFlipsBottomLeftRows(t *testing.T) {
	pix := []byte{1, 1, 1, 255, 2, 2, 2, 255}
	img, _, err := decodePayload(payloadJSON(t, 1, 2, pix, ""))
	if err != nil {
		t.Fatal(err)
	}
	if img.Pix[0] != 2 {
		t.Fatalf("top row = %d, want the last row of readPixels", img.Pix[0])
	}
}

func TestDecodePayloadKeepsTopLeftRows(t *testing.T) {
	pix := []byte{1, 1, 1, 255, 2, 2, 2, 255}
	img, _, err := decodePayload(payloadJSON(t, 1, 2, pix, "top-left"))
	if err != nil {
		t.Fatal(err)
	}
	if img.Pix[0] != 1 {
		t.Fatalf("top row = %d", img.Pix[0])
	}
}

func TestDecodePayloadRejectsWrongLength(t *testing.T) {
	if _, _, err := decodePayload(payloadJSON(t, 2, 2, []byte{0, 0, 0, 0}, "")); err == nil {
		t.Fatal("want error")
	}
}

func TestDecodePayloadRejectsNull(t *testing.T) {
	if _, _, err := decodePayload(json.RawMessage("null")); err == nil {
		t.Fatal("want error")
	}
}

func TestCaptureStopsOnPageError(t *testing.T) {
	if testing.Short() {
		t.Skip("-short")
	}
	if _, err := FindChrome(); err != nil {
		t.Skip(err)
	}
	_, err := Capture(Options{URL: "data:text/html,<script>window.fgeCaptureError='no webgl2'</script>", Wait: 10 * time.Second})
	if err == nil || !strings.Contains(err.Error(), "no webgl2") {
		t.Fatalf("err = %v", err)
	}
}

// 本物の Chrome で testdata/webgl2_known.html を撮る。Chrome が無い機械と -short では飛ばす。
func TestCaptureKnownWebGL2Picture(t *testing.T) {
	if testing.Short() {
		t.Skip("-short")
	}
	if _, err := FindChrome(); err != nil {
		t.Skip(err)
	}
	srv := httptest.NewServer(http.FileServer(http.Dir("testdata")))
	defer srv.Close()
	res, err := Capture(Options{URL: srv.URL + "/webgl2_known.html", Width: 64, Height: 48, Wait: 20 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("chrome=%s renderer=%s", res.Version, res.Renderer)
	img := res.Image
	if img.Bounds().Dx() != 64 || img.Bounds().Dy() != 48 {
		t.Fatalf("size %v", img.Bounds())
	}
	bg := color.NRGBA{32, 64, 96, 255}
	red := color.NRGBA{255, 0, 0, 255}
	green := color.NRGBA{0, 255, 128, 255}
	bad := 0
	for y := 0; y < 48; y++ {
		for x := 0; x < 64; x++ {
			want := bg
			if x < 16 && y >= 36 {
				want = red
			}
			if x >= 32 && x < 48 && y >= 8 && y < 24 {
				want = green
			}
			if got := img.NRGBAAt(x, y); got != want {
				if bad < 5 {
					t.Errorf("(%d,%d) = %v, want %v", x, y, got, want)
				}
				bad++
			}
		}
	}
	if bad > 0 {
		t.Fatalf("%d px differ", bad)
	}
}
