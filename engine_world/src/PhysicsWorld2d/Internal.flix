// PhysicsWorld2d.Internal — PhysicsWorld2d の中身（形・当たり・解き手・1 刻み・欄）を置く子のモジュールの親。
// ゲームが呼ぶ関数は全部 PhysicsWorld2d・RigidBody2d・Collider2d に残し、ここの子はゲームの src と test から呼ばない（lint-forbid の app-internal が止める）。
// WhyNot: 子の関数を非 pub にしない — Flix では親から子の関数を呼ぶには pub が要り、パッケージの中だけで見える pub が無い。
pub mod PhysicsWorld2d.Internal {
}
