# 台本の関数の答えを並べる。arm64 と amd64（make go-test-amd64）で golden.json とバイトで同じになる
rows = []
for i in range(200):
    x = -20 + i * 0.1337
    rows.append([
        x,
        math.sin(x),
        math.cos(x),
        math.tan(x),
        math.exp(x / 4),
        math.log(abs(x) + 0.01),
        math.pow(abs(x) + 0.1, 1.37),
        math.atan2(x, 3.1 - i * 0.05),
        math.hypot(x, i * 0.3),
        px.noise1(x / 3, i),
        px.hash01(i, -i, 7),
        px.round(x, 2),
        px.round(x * 3),
    ])
r = px.rng(42)
draws = [r.random() for _ in range(20)] + [r.uniform(6, 14) for _ in range(20)] + [r.randint(-4, 9) for _ in range(20)]
px.write_json("out/golden.json", {"rows": rows, "rng": draws})
