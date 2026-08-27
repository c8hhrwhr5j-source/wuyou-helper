from PIL import Image

for name in ['C:/TrollAutoTouch/A.png','C:/TrollAutoTouch/B.png']:
    im = Image.open(name)
    print(name, 'size=', im.size, 'mode=', im.mode)
    coords = [(98,343),(93,430),(105,530),(102,610),(97,707),(82,878),(161,254),(130,243)]
    for x,y in coords:
        p = im.getpixel((x,y))
        if isinstance(p, tuple):
            r,g,b = p[:3]
            print(f'  ({x},{y}) -> #{r:02X}{g:02X}{b:02X} {p}')
        else:
            print(f'  ({x},{y}) -> {p}')
    print()
