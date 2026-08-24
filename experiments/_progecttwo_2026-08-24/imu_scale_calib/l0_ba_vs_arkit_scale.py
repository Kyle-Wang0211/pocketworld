#!/usr/bin/env python3
"""L0: BA gauge vs ARKit metric scale, measured from EXISTING host backups.

Reproduces gravity_align.dart:231-325 scaleAnchorFactor exactly:
    s = median_i( |C_ark_i - centroid_ark| / |C_ba_i - centroid_ba| )
plus an Umeyama Sim3 cross-check (which also yields rotation/translation residual).

Inputs per capture dir (already on host, no device pull needed):
  official_sfm_fed_frames.jsonl -> frameId, arkitCameraCenterWorld  (ARKit metric)
  official_sfm_sparse_meta.json -> poses[].frame_id, quat_wxyz, t   (delivered BA gauge)
"""
import json, glob, os, sys
import numpy as np

def quat_to_R(q):  # wxyz
    w,x,y,z = q
    n = np.sqrt(w*w+x*x+y*y+z*z); w,x,y,z = w/n,x/n,y/n,z/n
    return np.array([
        [1-2*(y*y+z*z), 2*(x*y-z*w),   2*(x*z+y*w)],
        [2*(x*y+z*w),   1-2*(x*x+z*z), 2*(y*z-x*w)],
        [2*(x*z-y*w),   2*(y*z+x*w),   1-2*(x*x+y*y)]])

def umeyama_scale(A, B):
    """scale s s.t. B ~= s*R*A + t  (A=BA centers, B=ARKit centers)."""
    ma, mb = A.mean(0), B.mean(0)
    Ac, Bc = A-ma, B-mb
    H = Ac.T @ Bc / len(A)
    U,D,Vt = np.linalg.svd(H)
    S = np.eye(3)
    if np.linalg.det(U)*np.linalg.det(Vt) < 0: S[2,2] = -1
    R = Vt.T @ S @ U.T
    var_a = (Ac**2).sum()/len(A)
    s = (D*np.diag(S)).sum()/var_a
    t = mb - s*R@ma
    resid = np.linalg.norm(B - (s*(R@A.T).T + t), axis=1)
    return s, resid

def analyze(capdir):
    fed = os.path.join(capdir,'official_sfm_fed_frames.jsonl')
    meta = os.path.join(capdir,'official_sfm_sparse_meta.json')
    if not (os.path.exists(fed) and os.path.exists(meta)): return None
    ark = {}
    for line in open(fed):
        line=line.strip()
        if not line: continue
        d=json.loads(line)
        c=d.get('arkitCameraCenterWorld')
        if c is not None: ark[d['frameId']] = np.array(c,float)
    m=json.load(open(meta))
    A,B,ids=[],[],[]
    for p in m.get('poses',[]):
        if not p.get('registered'): continue
        fid=p['frame_id']
        if fid not in ark: continue
        R=quat_to_R(p['quat_wxyz']); t=np.array(p['t'],float)
        C=-R.T@t                      # CamFromWorld -> camera center in BA world
        A.append(C); B.append(ark[fid]); ids.append(fid)
    if len(A)<3: return dict(cap=os.path.basename(capdir), n=len(A), err='too few pairs')
    A=np.array(A); B=np.array(B)
    ca,cb=A.mean(0),B.mean(0)
    ra=np.linalg.norm(A-ca,axis=1); rb=np.linalg.norm(B-cb,axis=1)
    ok=ra>1e-6
    ratios=rb[ok]/ra[ok]
    s_med=float(np.median(ratios))
    s_um,resid=umeyama_scale(A,B)
    return dict(cap=os.path.basename(capdir), n=len(A),
                s_median=s_med, s_umeyama=float(s_um),
                ratio_p10=float(np.percentile(ratios,10)), ratio_p90=float(np.percentile(ratios,90)),
                ratio_iqr_rel=float((np.percentile(ratios,75)-np.percentile(ratios,25))/s_med),
                sim3_resid_mm_median=float(np.median(resid)*1000),
                sim3_resid_mm_p95=float(np.percentile(resid,95)*1000),
                span_ark_m=float(np.linalg.norm(B-cb,axis=1).max()*2),
                rejected=bool(abs(s_med-1.0)>0.15))

roots = sys.argv[1:] or [
 '/Users/kaidongwang/Developer/pocketworld_artifacts/device_backups',
 '/Users/kaidongwang/Developer/device-backups',
 '/Users/kaidongwang/Documents/progecttwo/_host_fixtures']
seen={}
for r in roots:
    for meta in glob.glob(os.path.join(r,'**','official_sfm_sparse_meta.json'), recursive=True):
        d=os.path.dirname(meta)
        res=analyze(d)
        if res is None: continue
        key=res['cap']
        # keep the run with most pairs per cap id (dedupe across backup snapshots)
        if key not in seen or res.get('n',0)>seen[key].get('n',0): seen[key]=res
rows=sorted(seen.values(), key=lambda r:-r.get('n',0))
print(f"{'capture':>22} {'n':>3} {'s_median':>9} {'s_umeyama':>10} {'|s-1|%':>8} {'ratio_IQR%':>10} {'sim3_resid_mm(med/p95)':>24} {'span_m':>7} rej")
for r in rows:
    if 'err' in r: print(f"{r['cap']:>22} {r['n']:>3}  {r['err']}"); continue
    print(f"{r['cap']:>22} {r['n']:>3} {r['s_median']:9.5f} {r['s_umeyama']:10.5f} "
          f"{abs(r['s_median']-1)*100:8.2f} {r['ratio_iqr_rel']*100:10.2f} "
          f"{r['sim3_resid_mm_median']:11.1f}/{r['sim3_resid_mm_p95']:<11.1f} {r['span_ark_m']:7.2f} {'YES' if r['rejected'] else '-'}")
good=[r for r in rows if 's_median' in r and r['n']>=10]
if good:
    ss=np.array([r['s_median'] for r in good])
    print(f"\nN(captures>=10 frames)={len(good)}  s_median: min={ss.min():.5f} max={ss.max():.5f} "
          f"mean={ss.mean():.5f} std={ss.std():.5f}")
    print(f"|s-1| : median={np.median(np.abs(ss-1))*100:.2f}%  max={np.abs(ss-1).max()*100:.2f}%")
    print(f"SCALE-ANCHOR reject (|s-1|>0.15) rate: {sum(r['rejected'] for r in good)}/{len(good)}")
