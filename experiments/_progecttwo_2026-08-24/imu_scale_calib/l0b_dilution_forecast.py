#!/usr/bin/env python3
"""L0b: predict the offline-IMU-oracle's regression-dilution floor from MEASURED
real-capture geometry -- no IMU needed.

Measured inputs (from existing host backups):
  dp   = inter-keyframe camera displacement (ARKit metric), the design-matrix column
  sig  = per-axis camera-center noise, from the Sim3 residual BA<->ARKit
Attenuation of the linear scale solve (errors-in-variables):
  s_hat/s ~= E|dp|^2 / (E|dp|^2 + E|noise_dp|^2),  noise_dp = 2 independent centers -> 6*sig^2
"""
import json,glob,os,numpy as np
def q2R(q):
    w,x,y,z=q; n=(w*w+x*x+y*y+z*z)**.5; w,x,y,z=w/n,x/n,y/n,z/n
    return np.array([[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],
                     [2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],
                     [2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]])
def ume(A,B):
    ma,mb=A.mean(0),B.mean(0); Ac,Bc=A-ma,B-mb
    H=Ac.T@Bc/len(A); U,D,Vt=np.linalg.svd(H); S=np.eye(3)
    if np.linalg.det(U)*np.linalg.det(Vt)<0: S[2,2]=-1
    R=Vt.T@S@U.T; s=(D*np.diag(S)).sum()/((Ac**2).sum()/len(A))
    return s,np.linalg.norm(B-(s*(R@A.T).T+(mb-s*R@ma)),axis=1)
rows=[]
for meta in glob.glob('/Users/kaidongwang/Developer/pocketworld_artifacts/device_backups/**/official_sfm_sparse_meta.json',recursive=True)+ \
            glob.glob('/Users/kaidongwang/Documents/progecttwo/_host_fixtures/**/official_sfm_sparse_meta.json',recursive=True):
    d=os.path.dirname(meta); fed=os.path.join(d,'official_sfm_fed_frames.jsonl')
    if not os.path.exists(fed): continue
    ark={};ts={}
    for L in open(fed):
        L=L.strip()
        if not L: continue
        j=json.loads(L)
        if j.get('arkitCameraCenterWorld'): ark[j['frameId']]=np.array(j['arkitCameraCenterWorld'],float); ts[j['frameId']]=j.get('captureTimestamp')
    m=json.load(open(meta)); A=[];B=[];T=[]
    for p in m.get('poses',[]):
        if not p.get('registered') or p['frame_id'] not in ark: continue
        R=q2R(p['quat_wxyz']); A.append(-R.T@np.array(p['t'],float)); B.append(ark[p['frame_id']]); T.append(ts[p['frame_id']])
    if len(A)<10: continue
    A=np.array(A);B=np.array(B);T=np.array([t if t else np.nan for t in T],float)
    o=np.argsort(T); B=B[o];A=A[o];T=T[o]
    s,res=ume(A,B)
    sig=np.median(res)/1.5382          # per-axis sigma from median of 3D norm
    dp=np.linalg.norm(np.diff(B,axis=0),axis=1)
    dt=np.diff(T)
    Edp2=float(np.mean(dp**2)); noise2=6*sig**2
    att=Edp2/(Edp2+noise2)
    # what spacing would be needed for <1% dilution?
    need=(99*noise2)**.5
    rows.append((os.path.basename(d),len(A),float(np.median(dp)),float(np.median(dt)),sig*1000,
                 (att-1)*100, need, float(np.linalg.norm(B-B.mean(0),axis=1).max()*2)))
seen={}
for r in rows:
    if r[0] not in seen or r[1]>seen[r[0]][1]: seen[r[0]]=r
print(f"{'capture':>24} {'n':>3} {'dp_med_m':>9} {'dt_med_s':>8} {'sig_mm':>7} {'dilution%':>10} {'dp_need_1%_m':>13} {'span_m':>7}")
for r in sorted(seen.values(),key=lambda x:-x[1]):
    print(f"{r[0]:>24} {r[1]:>3} {r[2]:9.3f} {r[3]:8.2f} {r[4]:7.2f} {r[5]:10.2f} {r[6]:13.2f} {r[7]:7.2f}")
