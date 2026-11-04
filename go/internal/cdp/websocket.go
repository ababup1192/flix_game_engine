// Package cdp はヘッドレスの Chrome を Chrome DevTools Protocol（CDP）で動かし、頁の canvas の画素を受け取る。
//
// 入口は Capture（Chrome を起こす → 頁を開く → 頁の合図を待つ → 画素を受け取る → Chrome を止める）。
// 頁の側の約束は docs/web-capture.md。
package cdp

import (
	"bufio"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"time"
)

// wsConn は CDP に要る分だけの WebSocket クライアント（RFC 6455・テキストのフレームだけ）。
//
// WhyNot: golang.org/x/net/websocket や gorilla を足さないのは、CDP は相手が手元の Chrome 1 つで、
// 要るのがテキストの送受と ping/close だけだから。go.mod の依存を増やすほどの面が無い。
type wsConn struct {
	conn net.Conn
	r    *bufio.Reader
}

const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

func dialWebSocket(rawURL string, timeout time.Duration) (*wsConn, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	if u.Scheme != "ws" {
		return nil, fmt.Errorf("ws:// でない URL は扱わない: %s", rawURL)
	}
	conn, err := net.DialTimeout("tcp", u.Host, timeout)
	if err != nil {
		return nil, err
	}
	keyRaw := make([]byte, 16)
	if _, err := rand.Read(keyRaw); err != nil {
		conn.Close()
		return nil, err
	}
	key := base64.StdEncoding.EncodeToString(keyRaw)
	req := "GET " + u.RequestURI() + " HTTP/1.1\r\n" +
		"Host: " + u.Host + "\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: " + key + "\r\n" +
		"Sec-WebSocket-Version: 13\r\n\r\n"
	conn.SetDeadline(time.Now().Add(timeout))
	if _, err := io.WriteString(conn, req); err != nil {
		conn.Close()
		return nil, err
	}
	r := bufio.NewReaderSize(conn, 1<<16)
	resp, err := http.ReadResponse(r, &http.Request{Method: "GET"})
	if err != nil {
		conn.Close()
		return nil, err
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		conn.Close()
		return nil, fmt.Errorf("WebSocket の握手が断られた: %s", resp.Status)
	}
	if resp.Header.Get("Sec-WebSocket-Accept") != acceptKey(key) {
		conn.Close()
		return nil, errors.New("WebSocket の握手の鍵が合わない")
	}
	conn.SetDeadline(time.Time{})
	return &wsConn{conn: conn, r: r}, nil
}

func acceptKey(key string) string {
	h := sha1.Sum([]byte(key + wsGUID))
	return base64.StdEncoding.EncodeToString(h[:])
}

// writeText はクライアントからのフレームなので必ずマスクする（RFC 6455 5.3。マスクの無いフレームは相手が切る）。
func (c *wsConn) writeText(payload []byte) error {
	return c.writeFrame(0x1, payload)
}

func (c *wsConn) writeFrame(opcode byte, payload []byte) error {
	header := []byte{0x80 | opcode}
	n := len(payload)
	switch {
	case n < 126:
		header = append(header, 0x80|byte(n))
	case n <= 0xFFFF:
		header = append(header, 0x80|126, byte(n>>8), byte(n))
	default:
		header = append(header, 0x80|127)
		header = binary.BigEndian.AppendUint64(header, uint64(n))
	}
	mask := make([]byte, 4)
	if _, err := rand.Read(mask); err != nil {
		return err
	}
	header = append(header, mask...)
	masked := make([]byte, n)
	for i := range payload {
		masked[i] = payload[i] ^ mask[i%4]
	}
	_, err := c.conn.Write(append(header, masked...))
	return err
}

// readMessage は次のテキストのメッセージを 1 つ返す。分割されたフレームはつなぎ、ping には pong を返す。
func (c *wsConn) readMessage() ([]byte, error) {
	var msg []byte
	for {
		fin, opcode, payload, err := c.readFrame()
		if err != nil {
			return nil, err
		}
		switch opcode {
		case 0x9:
			if err := c.writeFrame(0xA, payload); err != nil {
				return nil, err
			}
			continue
		case 0xA:
			continue
		case 0x8:
			return nil, io.EOF
		case 0x1, 0x2, 0x0:
			msg = append(msg, payload...)
			if fin {
				return msg, nil
			}
		default:
			return nil, fmt.Errorf("知らない WebSocket の opcode: %d", opcode)
		}
	}
}

func (c *wsConn) readFrame() (fin bool, opcode byte, payload []byte, err error) {
	var head [2]byte
	if _, err = io.ReadFull(c.r, head[:]); err != nil {
		return
	}
	fin = head[0]&0x80 != 0
	opcode = head[0] & 0x0F
	masked := head[1]&0x80 != 0
	n := uint64(head[1] & 0x7F)
	switch n {
	case 126:
		var ext [2]byte
		if _, err = io.ReadFull(c.r, ext[:]); err != nil {
			return
		}
		n = uint64(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err = io.ReadFull(c.r, ext[:]); err != nil {
			return
		}
		n = binary.BigEndian.Uint64(ext[:])
	}
	// WhyNot: 上限を置くのは、壊れた長さを信じて数 GB を確保しないため。1 枚の画素（4K の RGBA の base64）でも 64MB に届かない。
	if n > 256<<20 {
		err = fmt.Errorf("WebSocket のフレームが大きすぎる: %d byte", n)
		return
	}
	var mask [4]byte
	if masked {
		if _, err = io.ReadFull(c.r, mask[:]); err != nil {
			return
		}
	}
	payload = make([]byte, n)
	if _, err = io.ReadFull(c.r, payload); err != nil {
		return
	}
	if masked {
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
	}
	return
}

func (c *wsConn) close() error {
	_ = c.writeFrame(0x8, nil)
	return c.conn.Close()
}
