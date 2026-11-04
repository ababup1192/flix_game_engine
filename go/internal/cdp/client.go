package cdp

import (
	"encoding/json"
	"fmt"
	"time"
)

// client は 1 つの target（頁）の WebSocket に CDP の命令を送って返事を待つ。
//
// WhyNot: 返事を待つ間に届くイベントは捨てる。合図は Runtime.evaluate で頁を覗いて取るので、
// イベントの購読（Page.loadEventFired など）に頼らない — 頁の load と「絵が描けた」は別の時刻だから。
type client struct {
	ws     *wsConn
	nextID int64
}

type cdpError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    string `json:"data"`
}

type cdpMessage struct {
	ID     int64           `json:"id"`
	Method string          `json:"method"`
	Result json.RawMessage `json:"result"`
	Error  *cdpError       `json:"error"`
}

func (c *client) call(method string, params any, timeout time.Duration) (json.RawMessage, error) {
	c.nextID++
	id := c.nextID
	if params == nil {
		params = struct{}{}
	}
	req, err := json.Marshal(map[string]any{"id": id, "method": method, "params": params})
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(timeout)
	c.ws.conn.SetDeadline(deadline)
	defer c.ws.conn.SetDeadline(time.Time{})
	if err := c.ws.writeText(req); err != nil {
		return nil, fmt.Errorf("%s を送れない: %w", method, err)
	}
	for {
		raw, err := c.ws.readMessage()
		if err != nil {
			return nil, fmt.Errorf("%s の返事を読めない: %w", method, err)
		}
		var msg cdpMessage
		if err := json.Unmarshal(raw, &msg); err != nil {
			return nil, fmt.Errorf("CDP の返事が JSON でない: %w", err)
		}
		if msg.Method != "" || msg.ID != id {
			continue
		}
		if msg.Error != nil {
			return nil, fmt.Errorf("%s が失敗した: %s %s", method, msg.Error.Message, msg.Error.Data)
		}
		return msg.Result, nil
	}
}

type remoteObject struct {
	Type        string          `json:"type"`
	Subtype     string          `json:"subtype"`
	Value       json.RawMessage `json:"value"`
	Description string          `json:"description"`
}

type evaluateResult struct {
	Result           remoteObject `json:"result"`
	ExceptionDetails *struct {
		Text      string       `json:"text"`
		Exception remoteObject `json:"exception"`
	} `json:"exceptionDetails"`
}

// evaluate は頁の中で式を評価し、値を JSON のまま返す（Promise なら解けるまで待つ）。
func (c *client) evaluate(expr string, timeout time.Duration) (json.RawMessage, error) {
	raw, err := c.call("Runtime.evaluate", map[string]any{
		"expression":    expr,
		"returnByValue": true,
		"awaitPromise":  true,
	}, timeout)
	if err != nil {
		return nil, err
	}
	var res evaluateResult
	if err := json.Unmarshal(raw, &res); err != nil {
		return nil, err
	}
	if res.ExceptionDetails != nil {
		desc := res.ExceptionDetails.Exception.Description
		if desc == "" {
			desc = res.ExceptionDetails.Text
		}
		return nil, fmt.Errorf("頁の中で例外: %s", desc)
	}
	return res.Result.Value, nil
}
