pub mod EngineSentinel {}

// engine fpkg のロードを consumer 側で trigger するためのモジュール。
//
// Flix 0.72.0 では cross-package use がほぼ全パターンで fail する (PR #12663) が、
// flix-json と同じ形式 (`pub mod X {}` 親 + `pub mod X.Y { pub <kind> Y { ... } }` 子) で
// 1 つだけ動く matching-name pattern を engine に同梱しておけば、
// consumer 側で `use EngineSentinel.Marker` 1 行が通り、
// それをきっかけに engine fpkg 全体が lazy-load される。
//
// 親 `pub mod EngineSentinel {}` は空。中身は `EngineSentinel.Marker` 側に。
//
// 重要: `///` (ドキュメントコメント) を `pub mod X {}` の前に置くと
//   Flix 0.72.0 では parser が混乱し、mod 宣言が認識されず cross-package use が
//   "Undefined use 'X.Y'" として fail する。通常コメント `//` を使うか、
//   コメントを `pub mod` の後に置くこと。
