"""Cut the climber and spotter out of the app icon for the screenshot art.

Usage: python3 key_icon.py <app icon png> <art dir>
Removes the flat orange background (flood fill from the edges, plus enclosed gaps)
and writes art_climber.png and art_spotter.png.
"""
from PIL import Image, ImageFilter
import numpy as np, sys
im=Image.open(sys.argv[1]).convert('RGB')
a=np.array(im).astype(int)
d=np.sqrt(((a-np.array([253,108,2]))**2).sum(-1))
def grow(m,lim,steps=10**6):
    for _ in range(steps):
        g=m.copy(); g[1:]|=m[:-1]; g[:-1]|=m[1:]; g[:,1:]|=m[:,:-1]; g[:,:-1]|=m[:,1:]; g&=lim
        if (g==m).all(): break
        m=g
    return m
def erode(m,steps):
    for _ in range(steps):
        g=m.copy(); g[1:]&=m[:-1]; g[:-1]&=m[1:]; g[:,1:]&=m[:,:-1]; g[:,:-1]&=m[:,1:]; m=g
    return m
near=d<60
m=np.zeros_like(near); m[0,:]=m[-1,:]=m[:,0]=m[:,-1]=True
m=grow(m&near,near)
seed=erode((d<9)&~m,4)
e=grow(seed,d<40,10)
bgm=m|e
alpha=np.where(bgm, np.clip((d-20)*6,0,255), 255).astype('uint8')
alpha=np.array(Image.fromarray(alpha).filter(ImageFilter.GaussianBlur(0.8)))
rgba=Image.fromarray(np.dstack([a.astype('uint8'),alpha]),'RGBA')
o=sys.argv[2]
A=np.array(rgba)
climber=A.copy(); climber[500:,600:,3]=0          # drop the spotter from the climber's crop
spotter=A.copy(); spotter[:500,:770,3]=0          # drop the climber's ponytail from the spotter's crop
spotter[:,:600,3]=0
Image.fromarray(climber).crop((60,90,770,930)).save(f'{o}/art_climber.png')
Image.fromarray(spotter).crop((590,380,960,930)).save(f'{o}/art_spotter.png')
p=Image.new('RGBA',rgba.size,(40,120,200,255)); p.alpha_composite(rgba); p.resize((512,512)).save(f'{o}/keyed_prev.png')
