import sys, json; sys.path.insert(0, '.')
from pxlib import *
from ground import GROUND
from lake import LAKE_NAMES, lake_frames
from house import HOUSE
from spring import spring
from props import PROPS, forge
from indoor import INDOOR, fireplace

NOTES = {
 'grass': '草（地）。暗い草むらと明るい斑を塊で置き、四辺を回り込ませて継ぎ目を消す。grass_b と混ぜて敷く。',
 'grass_b': '草の変種。斑の密な所を grass と逆の角へ置いた物。',
 'flowers': '花の咲く草。桃色の花びら＋黄の芯。',
 'tall_grass': '背の高い草むら。地が暗い緑で、葉先が明るい。',
 'path': '土の道。明るい斑は左上・暗い礫は右下に寄せる。',
 'cobble': '石畳。不揃いな石（ボロノイ）で目地を灰、石の下の目地を墨で沈める。',
 'field': '畑の畝。4px ごとに畝と溝、芽の列をずらす。',
 'lake': '湖（沖）。波の印が f0→f1 で揺れる。',
 'spring_dry': '枯れた泉。32×32。石の縁＋奥の内壁の影＋ひび割れた泥の底＋中央の石の湧き口。',
 'spring_full': '水の戻った泉。32×32。波紋が湧き口から広がり、きらめきが 3 コマで移る。',
 'chimney': '煙突の付いた屋根の棟の段。roof_m と差し替えて置く（16×16 不透明）。',
 'sign_inn': '宿の看板（寝台の印）を掛けた壁。wall_m と差し替えて置く。',
 'sign_item': '道具屋の看板（袋の印）を掛けた壁。wall_m と差し替えて置く。',
 'door': '板の扉。壁の段に置く。扉の下の 1 行は敷居。',
 'forge': '鍛冶の炉。32×32。炉の口の火が 3 コマで揺れ、煙突から火の粉。',
 'fireplace': '暖炉。32×32。石積み＋木の棚板＋火 3 コマ。wall_in の段に置く（上半分が壁の高さ）。',
 'rug': '敷物。32×32。赤地に金の菱形と房。',
 'table': '机。32×16。天板に窓からの光の帯。手前の脚 2 本と床の影。',
 'bookshelf': '本棚。16×32。棚の段ごとに本の色を変える。',
 'bed': '寝台。16×32。枕と青い掛け布。',
 'wall_top': '屋内の壁の上端（暗い面）。青みの墨で床・壁の暖色から分ける。四辺で回る。',
 'wall_in': '屋内の壁の正面。漆喰＋腰板。横に続く。上に wall_top、下に床。',
 'window_in': '屋内の窓（wall_in と差し替え）。',
 'floor_wood': '板の床。広い面なので焦げ茶を地にして彩度を落とす。',
}
for s in ['n', 's', 'e', 'w']: NOTES['lake_' + s] = f'湖の岸の辺。{ {"n":"北","s":"南","e":"東","w":"西"}[s] }の辺が草の岸。'
for s in ['ne', 'nw', 'se', 'sw']: NOTES['lake_' + s] = f'湖の外角。{s} の 2 辺が草の岸。'
for s in ['ne', 'nw', 'se', 'sw']: NOTES['lake_in_' + s] = f'湖の内角。{s} の角だけが草。'

TILE = set(GROUND) | {'lake'} | {'lake_' + n for n in LAKE_NAMES} | set(HOUSE) | {'floor_wood', 'wall_in', 'wall_top', 'window_in'}

def collect():
    S = {}
    for n, f in GROUND.items(): S[n] = {'idle': f().rows()}
    S['lake'] = lake_frames('')
    for n in LAKE_NAMES: S['lake_' + n] = lake_frames(n)
    for n, f in HOUSE.items(): S[n] = {'idle': f().rows()}
    S['spring_dry'] = {'idle': spring('dry').rows()}
    S['spring_full'] = {f'f{i}': spring('full', i).rows() for i in range(3)}
    for n, f in PROPS.items(): S[n] = {'idle': f().rows()}
    S['forge'] = {f'f{i}': forge(i).rows() for i in range(3)}
    for n, f in INDOOR.items(): S[n] = {'idle': f().rows()}
    S['fireplace'] = {f'f{i}': fireplace(i).rows() for i in range(3)}
    return S

if __name__ == '__main__':
    S = collect()
    used = sorted({ch for fr in S.values() for rows in fr.values() for r in rows for ch in r} - {'.'})
    doc = {
        'version': 1,
        'title': '村と屋内のタイル',
        'note': '場面 village / quest / join / clear の地面・湖・家・泉・小物・屋内。光は左上から。地面と湖のタイルは 16×16 で四辺が回る。家は 3/4 の見下ろし（棟の段 roof_* → 軒の段 eave_* → 壁の段 wall_*/door/sign_*）。anchor はどれも左上 (0,0) で、タイルの升目に左上をそろえて置く。小物は透明の地に接地影まで描いてあり、草や床の上へ重ねる。湖は f0/f1、泉の水・炉・暖炉の火は f0/f1/f2。色は 1 タイル = 墨 + 3 色を目安（大きい物は 8×8 の升目ごと）。',
        'paletteFile': 'assets/rpg.palette.json',
        'legend': {ch: LEG[ch] for ch in used},
        'sprites': {},
    }
    for n, fr in S.items():
        e = {}
        if n in NOTES: e['note'] = NOTES[n]
        e['kind'] = 'tile' if n in TILE else 'prop'
        e['anchor'] = {'x': 0, 'y': 0}
        e['frames'] = fr
        doc['sprites'][n] = e
    open(ROOT + '/assets/rpg.town.sprite.json', 'w').write(json.dumps(doc, ensure_ascii=False, indent=2) + '\n')
    print(len(S), 'sprites', used)
