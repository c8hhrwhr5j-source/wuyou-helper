from PIL import Image

for path in [r"C:\TrollAutoTouch\A.png", r"C:\TrollAutoTouch\B.png"]:
    im = Image.open(path).convert("RGB")
    w,h = im.size
    px = im.load()
    black=white=near=0
    total=w*h
    rmin=gmin=bmin=255; rmax=gmax=bmax=0
    for y in range(0,h,3):
        for x in range(0,w,3):
            r,g,b = px[x,y]
            rmin=min(rmin,r); gmin=min(gmin,g); bmin=min(bmin,b)
            rmax=max(rmax,r); gmax=max(gmax,g); bmax=max(bmax,b)
            if r==0 and g==0 and b==0: black+=1
            if r==255 and g==255 and b==255: white+=1
            if r<30 and g<30 and b<30: near+=1
    print(f"== {path} sampled={total//9}")
    print(f"   RGB min=({rmin},{gmin},{bmin}) max=({rmax},{gmax},{bmax})")
    print(f"   pure black px={black}  pure white px={white}  near-black(<30)={near}")
