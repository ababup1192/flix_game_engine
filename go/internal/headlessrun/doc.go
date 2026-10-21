// Package headlessrun は bin/headless-run（bash）を外から確かめるテストだけを置く。
//
// headless-run は jar を作る鍵（build/headless/.lock）を取ってから jar を作る。テストは偽の flix
// （build-fatjar で小さな jar を置くだけ）を FLIX_CMD で渡して --build-only / --status で流し、
// 鍵が空・作り手が居ない・作り手が生きている時の振る舞いを見る。あわせて bin/ と Makefile の
// シェルで、変数の直後に全角の字が続く所（bash が変数名の続きと読んで落ちる）が無いかを見る。
package headlessrun
