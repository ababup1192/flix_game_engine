# staticGroup の draw call の見込み（engine の StaticBatch の決まりを写した近似）
import json,struct,sys,collections,hashlib,glob,os
root=sys.argv[1]; MINUSE=int(sys.argv[4]) if len(sys.argv)>4 else 2
quant=int(sys.argv[2]) if len(sys.argv)>2 else 0; atlas=len(sys.argv)>3 and sys.argv[3]=='atlas'
def glb(f):
    d=open(f,'rb').read(); n=struct.unpack('<I',d[12:16])[0]; js=json.loads(d[20:20+n]); binc=d[20+n+8:]
    return js,binc
nodes={}  # name -> list of (matkey, verts)
for f in sorted(glob.glob(root+'/assets/school/bundle/*.glb')):
    js,b=glb(f)
    def imgkey(i):
        im=js['images'][i]; bv=js['bufferViews'][im['bufferView']]
        return hashlib.sha1(b[bv.get('byteOffset',0):bv.get('byteOffset',0)+bv['byteLength']]).hexdigest()[:8]
    def matkey(mi):
        if mi is None: return 'plain'
        m=js['materials'][mi]; pbr=m.get('pbrMetallicRoughness',{})
        t=pbr.get('baseColorTexture'); 
        tk=imgkey(js['textures'][t['index']]['source']) if t else 'none'
        if atlas: tk='ATLAS'
        return (tk,json.dumps(pbr.get('baseColorFactor')),m.get('alphaMode'),json.dumps(m.get('emissiveFactor')))
    for nd in js['nodes']:
        if 'mesh' not in nd: continue
        prims=js['meshes'][nd['mesh']]['primitives']
        nodes[nd['name']]=[(matkey(p.get('material')), js['accessors'][p['attributes']['POSITION']]['count']) for p in prims]
l=json.load(open(root+'/assets/school/layout.json'))
def q(c):
    if quant<=0: return tuple(c)
    if quant==1: return (1,1,1)
    lum=sum(c)/3; k=round(lum*quant)/quant; return (k,k,k)
spawnfloor=1
def floordraws(fi):
    draws=0; units=collections.defaultdict(int)
    b=nodes.get(f'school_floor{fi}',[])
    for mk,v in b: units[(mk,(1,1,1))]+=v
    props=[p for p in l['props'] if p['floor']==fi]
    cnt=collections.Counter(p['prop'] for p in props)
    for name,c in cnt.items():
        parts=nodes.get('prop_'+name)
        if parts is None: continue
        if c>=MINUSE: draws+=len(parts)   # 同じ形を instanced
        else:
            for p in [x for x in props if x['prop']==name]:
                for mk,v in parts: units[(mk,q(p.get('shade',[1,1,1])))]+=v
    chunks=sum(max(1,-(-v//8192)) for v in units.values())
    return draws+chunks, draws, chunks, len(props)
tot=0
for fi in sorted(set(f['index'] for f in l['floors'])):
    r=floordraws(fi); print('floor',fi,'draws',r[0],'(instanced',r[1],'joined',r[2],') props',r[3])
missing=set('prop_'+p['prop'] for p in l['props'])-set(nodes); print('missing nodes',len(missing),list(missing)[:5])
print('1F+2F =',floordraws(1)[0]+floordraws(2)[0])
