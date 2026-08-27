import sys
try:
    from PIL import Image
except ImportError:
    print("NO_PIL")
    sys.exit(1)

pts = [(98,343),(93,430),(105,530),(102,610),(97,707),(82,878),(161,254),(130,243)]
names = ["purple","red","teal","green","orange","blue","black","white"]
for path in [r"C:\TrollAutoTouch\A.png", r"C:\TrollAutoTouch\B.png"]:
    im = Image.open(path).convert("RGB")
    w,h = im.size
    print(f"== {path} size={w}x{h}")
    for (x,y),n in zip(pts,names):
        try:
            print(f"  {n} ({x},{y}) = #{''.join('%02x'%c for c in im.getpixel((x,y)))} {im.getpixel((x,y))}")
        except Exception as e:
            print(f"  {n} ({x},{y}) ERR {e}")
