#!/bin/sh
# install.sh — 全体の fge を ${FGE_HOME:-~/.flix_ge}/bin/fge に入れる（Release に添える）。
#
#   curl -fsSL https://github.com/ababup1192/flix_game_engine/releases/latest/download/install.sh | sh
#
# FGE_VERSION の行は make release-publish（release-fge-assets）が添える時に埋める。空なら latest の Release から取る。
# FGE_DOWNLOAD_URL で取り先（fge-<os>-<arch> と fge-SHA256SUMS.txt を置いた所）を替えられる。
#
# WhyNot: raw.githubusercontent の main から配らない — 版が付かない。Release に添えれば install.sh と fge の版がそろう。
# WhyNot: シェルの設定ファイルに PATH を書き足さない — 利用者の dotfiles を勝手に触らない（足す 1 行を出すだけ）。
# WhyNot: bash に頼らない — `curl … | sh` の sh は Debian 系では dash。
set -eu

FGE_VERSION=

say() { printf '%s\n' "$*"; }
die() {
    printf 'install.sh: %s\n' "$*" >&2
    exit 1
}

case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) die "この OS（$(uname -s)）には対応していません（macOS と Linux だけ）" ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 ;;
    arm64 | aarch64) arch=arm64 ;;
    *) die "この CPU（$(uname -m)）には対応していません（amd64 と arm64 だけ）" ;;
esac

releases=https://github.com/ababup1192/flix_game_engine/releases
if [ -n "${FGE_DOWNLOAD_URL:-}" ]; then
    base=${FGE_DOWNLOAD_URL%/}
elif [ -n "$FGE_VERSION" ]; then
    base=$releases/download/v$FGE_VERSION
else
    base=$releases/latest/download
fi

command -v curl >/dev/null 2>&1 || die "curl が要ります"
if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
    die "sha256sum か shasum が要ります"
fi

home=${FGE_HOME:-$HOME/.flix_ge}
name=fge-$os-$arch
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fge-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM

say "fge ${FGE_VERSION:-（最新）}（${os}/${arch}）を取ります: $base/$name"
curl -fsSL -o "$tmp/$name" "$base/$name" || die "取れませんでした: $base/$name"
curl -fsSL -o "$tmp/sums" "$base/fge-SHA256SUMS.txt" || die "取れませんでした: $base/fge-SHA256SUMS.txt"
want=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' "$tmp/sums")
[ -n "$want" ] || die "fge-SHA256SUMS.txt に $name の行がありません"
got=$(sha256 "$tmp/$name")
[ "$want" = "$got" ] || die "SHA256 が合いません（$name: 期待 ${want}・実際 ${got}）"

# WhyNot: 一時フォルダから直に mv しない — 別のファイルシステムだと写している途中の fge が見える。隣に置いてから差し替える。
mkdir -p "$home/bin"
cp "$tmp/$name" "$home/bin/.fge.new"
chmod 755 "$home/bin/.fge.new"
mv -f "$home/bin/.fge.new" "$home/bin/fge"
say "入れました: $home/bin/fge"

case ":$PATH:" in
    *":$home/bin:"*) ;;
    *)
        say ""
        say "PATH に足してください（シェルの設定ファイル ~/.zshrc や ~/.bashrc に 1 行）:"
        say "  export PATH=\"$home/bin:\$PATH\""
        ;;
esac
if [ "$home" != "$HOME/.flix_ge" ]; then
    say "置き場を替えたので、これも同じ所に足してください（make と fge が環境から読む）:"
    say "  export FGE_HOME=\"$home\""
fi
say ""
say "次: fge dashboard"
if ! command -v claude >/dev/null 2>&1; then
    say "Claude Code が無ければ先に入れてください: curl -fsSL https://claude.ai/install.sh | bash"
fi
