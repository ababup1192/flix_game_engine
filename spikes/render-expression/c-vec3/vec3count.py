"""スパイク (c): ShaderDoc の Spec（JSON）の節の数と、vec3 の節を足した木での見積もり。

見積もりの決まり:
- 名前の 1 字だけが r・g・b で違う束ね 3 本（r0/g0/b0・pp_tr/pp_tg/pp_tb）は、
  chan と参照の名前をならして同じ形なら 1 本に括る。
- 色（rgb の Shade）の r・g・b が同じ形なら 1 本 + vec3 へ持ち上げる節 1 つ。
- luma の add(add(mul(k,X),mul(k,Y)),mul(k,Z)) で X・Y・Z が同じ形なら dot 1 + 定数の vec3 1。
使い方: python3 vec3count.py <SPEC 行の入った txt | FILE <path> 行>
"""
import json
import sys


def nodes(t):
    if isinstance(t, dict):
        return (1 if 'kind' in t else 0) + sum(nodes(v) for v in t.values())
    if isinstance(t, list):
        return sum(nodes(v) for v in t)
    return 0


def triplet_keys(name):
    for i, ch in enumerate(name):
        if ch in 'rgb':
            yield name[:i] + '#' + name[i + 1:], ch


def groups(names):
    by = {}
    for n in names:
        for k, ch in triplet_keys(n):
            by.setdefault(k, {})[ch] = n
    out = {}
    for k, m in by.items():
        if set(m) == {'r', 'g', 'b'}:
            for n in m.values():
                out[n] = k
    return out


def canon(t, g):
    if isinstance(t, dict):
        d = {}
        for k, v in t.items():
            if k == 'chan' and v in ('r', 'g', 'b'):
                d[k] = 'C'
            elif k == 'name' and t.get('kind') == 'use' and v in g:
                d[k] = g[v]
            else:
                d[k] = canon(v, g)
        return d
    if isinstance(t, list):
        return [canon(v, g) for v in t]
    return t


def same(a, b, c, g):
    ka = json.dumps(canon(a, g), sort_keys=True)
    return ka == json.dumps(canon(b, g), sort_keys=True) == json.dumps(canon(c, g), sort_keys=True)


def luma_arg(t, g):
    try:
        if t['kind'] == 'math2' and t['op'] == 'add' and t['a']['kind'] == 'math2' and t['a']['op'] == 'add':
            ms = [t['a']['a'], t['a']['b'], t['b']]
            if all(m['kind'] == 'math2' and m['op'] == 'mul' and m['a']['kind'] == 'const' for m in ms):
                xs = [m['b'] for m in ms]
                if same(xs[0], xs[1], xs[2], g):
                    return xs[0]
    except (KeyError, TypeError):
        pass
    return None


def is_rgb(t):
    return all(isinstance(t.get(c), dict) for c in 'rgb')


def vnodes(t, g):
    if isinstance(t, dict):
        if 'kind' in t:
            x = luma_arg(t, g)
            if x is not None:
                return 2 + vnodes(x, g)
        if is_rgb(t) and same(t['r'], t['g'], t['b'], g):
            return 1 + vnodes(t['r'], g) + sum(vnodes(v, g) for k, v in t.items() if k not in 'rgb')
        return (1 if 'kind' in t else 0) + sum(vnodes(v, g) for v in t.values())
    if isinstance(t, list):
        return sum(vnodes(v, g) for v in t)
    return 0


def bindings_of(s):
    b = s.get('bindings') or s.get('let') or s.get('shared') or []
    if isinstance(b, dict):
        return list(b.items())
    out = []
    for x in b:
        if isinstance(x, dict):
            out.append((x.get('name'), x.get('field', x.get('value', x))))
        else:
            out.append((x[0], x[1]))
    return out


def report(name, s):
    items = bindings_of(s)
    g = groups([n for n, _ in items])
    before = nodes(s.get('out')) + sum(nodes(v) for _, v in items)
    seen = set()
    after = vnodes(s.get('out'), g)
    for n, v in items:
        if n in g:
            if g[n] in seen:
                continue
            seen.add(g[n])
        after += vnodes(v, g)
    pct = 100 * (before - after) / max(before, 1)
    print(f"{name:24s} 節 {before:5d} -> vec3 {after:5d} ({pct:3.0f}% 減)  束ね {len(items)} -> {len(items) - 2 * len(seen)}")
    return before, after


def main():
    tb = ta = 0
    for line in open(sys.argv[1]):
        if line.startswith('SPEC '):
            _, n, j = line.split(' ', 2)
            b, a = report(n, json.loads(j))
        elif line.startswith('FILE '):
            p = line.split(' ', 1)[1].strip()
            b, a = report(p.split('/')[-1], json.load(open(p)))
        else:
            continue
        tb += b
        ta += a
    print(f"{'合計':24s} 節 {tb:5d} -> vec3 {ta:5d} ({100 * (tb - ta) / max(tb, 1):3.0f}% 減)")


main()
