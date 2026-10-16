# テストの設計 — 例

`SKILL.md` の表から、困った節だけ引く。決まりそのものは `SKILL.md` が正。

## 1 テスト 1 アサートと bug!

```flix
// NG: assert を並べる（どれが落ちたか追いにくく、最初の失敗で残りが評価されない）
Assert.assertEq(expected = 4.0, r#x);
Assert.assertEq(expected = 6.0, r#y)

// OK: タプルにまとめる
Assert.assertEq(expected = (4.0, 6.0), (r#x, r#y))
```

```flix
// 期待の形にだけ match し、ほかは bug!。取り出した値をそのまま assert に使う
match lookup(key, container) {
    case Some(value) =>
        Assert.assertEq(expected = ..., extract(value))
    case _ => bug!("expected entry not found")
}
```

## Effect ハンドラのモック

```flix
// effect 多相で書く（呼び出し元のほかのエフェクトを ef で通す）
def withMockClock(f: Unit -> a \ ef + Clock): a \ ef =
    run f() with handler Clock {
        def currentTime(_, k) = k(0i64)
    }
```

- ハンドラは「決まった値を返す」「副作用を何もしない」など、テストに都合のよい振る舞いにする
- 1 つのモックに 2 つ以上のエフェクトが混ざるなら、1 つの `run` に `with handler X { ... } with handler Y { ... }` を連ねる
- 新しいモックは、集約用ファイルの既にあるヘルパーと同じ形で足す

## 区切りと意図コメント

Flix には `describe` が無いので、大きな ASCII コメントで区切る。

```flix
// ========================================================================
// 重力: 物体は重力で下方向に落下する
// ========================================================================

/// 0.5 秒分の動きを進めた後、y が 400 より大きくなる
/// （重力が下向きに効いていることを位置の変化で確認する）
@Test
def testFallsUnderGravity(): Unit \ {Assert, Fs.FileRead} = ...
```

複雑な座標計算・段階のある処理・難易度カーブは、数の出どころ（係数・補間・モックの値）が 1 画面で読めるよう
ASCII アートで図にする。

## 区切りの良い数

- NG: 「位置 (112, 331) から (234, 521) に動く」 — 数の意味が読めない
- OK: 「位置 (0, 0) から (50, 100) に動く」 — 速度 50/100 で 1 秒進めた、と一目で分かる

既にある定数（重力・フレームレート）はそのまま受け入れ、掛けてもきれいな数になる時間幅（0.1・0.5・1.0 秒）を選ぶ。

```flix
/// 速度 100 で 0.5 秒進めると x = 50 になる（100 × 0.5）
@Test
def testMovesAtConstantVelocity(): Unit \ Assert =
    let after = move({x = 0.0, y = 0.0}, {x = 100.0, y = 0.0}, 0.5);
    Assert.assertEq(expected = (50.0, 0.0), (after#x, after#y))
```
