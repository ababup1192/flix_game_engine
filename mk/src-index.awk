# ゲームの src/*.flix から pub の定義（def / enum / type / trait / eff / struct）と mod を
# 「ファイル:行: 定義」の 1 行ずつ引き出す（正規表現だけの最小版。型検査はしない）。
# mk/game.mk の src（grep で絞る）から呼ぶ。
/^[ \t]*(pub[ \t]+((opaque|lawful|sealed)[ \t]+)*(def|enum|type|trait|eff|struct)|mod)[ \t]/ {
    d = $0
    sub(/^[ \t]+/, "", d)
    sub(/[ \t]*(=|\{)[ \t]*$/, "", d)
    if (length(d) > 160) d = substr(d, 1, 157) "..."
    printf "%s:%d: %s\n", FILENAME, FNR, d
}
