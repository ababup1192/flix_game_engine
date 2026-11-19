package main

import (
	"bytes"
	"testing"
)

func wasmSection(id byte, body []byte) []byte {
	return append([]byte{id, byte(len(body))}, body...)
}

func customSection(name string, payload []byte) []byte {
	return wasmSection(0, append(append([]byte{byte(len(name))}, name...), payload...))
}

func tinyWasm(sections ...[]byte) []byte {
	out := []byte("\x00asm\x01\x00\x00\x00")
	for _, s := range sections {
		out = append(out, s...)
	}
	return out
}

func TestSplitWasmNamesDropsOnlyNameSection(t *testing.T) {
	types := wasmSection(1, []byte{0})
	other := customSection("teavm.imports", []byte{7})
	stripped, _, err := splitWasmNames(tinyWasm(types, customSection("name", []byte{1, 2, 3}), other))
	if err != nil || !bytes.Equal(stripped, tinyWasm(types, other)) {
		t.Fatalf("got % x, %v", stripped, err)
	}
}

func TestSplitWasmNamesReturnsNamePayload(t *testing.T) {
	_, names, _ := splitWasmNames(tinyWasm(customSection("name", []byte{1, 2, 3})))
	if !bytes.Equal(names, []byte{1, 2, 3}) {
		t.Fatalf("got % x", names)
	}
}

func TestSplitWasmNamesWithoutNameSectionReturnsNil(t *testing.T) {
	_, names, err := splitWasmNames(tinyWasm(wasmSection(1, []byte{0})))
	if err != nil || names != nil {
		t.Fatalf("got % x, %v", names, err)
	}
}

func TestSplitWasmNamesRejectsTruncatedSection(t *testing.T) {
	if _, _, err := splitWasmNames(tinyWasm([]byte{1, 9, 0})); err == nil {
		t.Fatal("切れた区画を通した")
	}
}

func TestSplitWasmNamesReadsTwoByteSectionSize(t *testing.T) {
	payload := bytes.Repeat([]byte{9}, 200)
	body := append([]byte{4}, "name"...)
	body = append(body, payload...)
	size := len(body)
	named := append([]byte{0, byte(size&0x7f | 0x80), byte(size >> 7)}, body...)
	_, names, err := splitWasmNames(tinyWasm(named))
	if err != nil || !bytes.Equal(names, payload) {
		t.Fatalf("got %d バイト, %v", len(names), err)
	}
}
