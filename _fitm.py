# -*- coding: utf-8 -*-
"""用多组同元素样本拟合 A = encode(M @ lin(C)) 的 3x3 矩阵 M"""
import sys

# 样本: (C_8bit, A_8bit)  来自 _fit.py 实测
S = [
    # 金色横幅
    ((255,197,116), (255,154,13)),
    ((255,194,109), (255,149,0)),
    # 蓝色块 (80,1296..1328)
    ((166,165,232), (147,146,228)),
    ((164,163,232), (101,99,217)),
    ((163,162,232), (95,93,215)),
    ((161,160,231), (91,89,214)),
    ((162,161,231), (96,94,216)),
    # 蓝色块 (40,1304..1328)
    ((165,164,232), (112,110,219)),
    ((159,158,231), (88,86,214)),
    ((107,105,218), (107,105,218)),  # 注: 此条是 C 位置, 但实际 C=(163,162,232) A=(107,105,218)? 修正
]
# 修正: (40,1320) C=(163,162,232) A=(107,105,218); (40,1328) C=(170,169,233) A=(108,106,219)
S = [
    ((255,197,116), (255,154,13)),
    ((255,194,109), (255,149,0)),
    ((166,165,232), (147,146,228)),
    ((164,163,232), (101,99,217)),
    ((163,162,232), (95,93,215)),
    ((161,160,231), (91,89,214)),
    ((162,161,231), (96,94,216)),
    ((165,164,232), (112,110,219)),
    ((159,158,231), (88,86,214)),
    ((163,162,232), (107,105,218)),
    ((170,169,233), (108,106,219)),
    # 中性色(近似, 差异≈0)
    ((253,253,253), (252,252,253)),
    ((251,251,253), (250,251,253)),
    ((242,242,247), (242,242,247)),
]
GAMMA = 2.2

def lin(v): return (v/255.0) ** GAMMA
def enc(v):
    if v <= 0: return 0
    if v >= 1: return 255
    return max(0, min(255, round(255.0 * (v ** (1.0/GAMMA)))))

def lin_v(p): return tuple(lin(c) for c in p)

# 构建最小二乘: 对每个通道 ch, M[ch] 是 3 向量, 使 M[ch]·linC ≈ linA[ch]
# 方程: 3 未知数每通道, 3 通道独立 -> 用 normal equations
import math
def solve(rows, b):
    # rows: list of 3-vectors; b: list
    n = len(rows)
    ATA = [[0.0]*3 for _ in range(3)]
    ATb = [0.0]*3
    for i in range(n):
        r = rows[i]; bi = b[i]
        for a in range(3):
            ATb[a] += r[a]*bi
            for c in range(3):
                ATA[a][c] += r[a]*r[c]
    # Gauss-Jordan
    m = [ATA[i][:] + [ATb[i]] for i in range(3)]
    for col in range(3):
        piv = max(range(col,3), key=lambda r: abs(m[r][col]))
        m[col], m[piv] = m[piv], m[col]
        pv = m[col][col]
        for j in range(4): m[col][j] /= pv
        for r in range(3):
            if r == col: continue
            f = m[r][col]
            if abs(f) < 1e-12: continue
            for j in range(4): m[r][j] -= f*m[col][j]
    return [m[r][3] for r in range(3)]

rows = [lin_v(c) for c,_ in S]
print('== 拟合线性域矩阵 M (A_lin = M @ C_lin) ==')
M = []
for ch in range(3):
    b = [lin(a[ch]) for _,a in S]
    coef = solve(rows, b)
    M.append(coef)
    print('  M[%s] = [%.4f %.4f %.4f]' % ('RGB'[ch], coef[0], coef[1], coef[2]))

print('== 拟合质量 (预测 vs 实际) ==')
tot = 0.0
for c, a in S:
    lc = lin_v(c)
    pred_l = [sum(M[ch][k]*lc[k] for k in range(3)) for ch in range(3)]
    pred = tuple(enc(x) for x in pred_l)
    d = sum(abs(pred[i]-a[i]) for i in range(3))
    tot += d*d
    flag = '  <-- 差大' if d > 30 else ''
    print('  C=%s -> 预测%s 实际%s (Δ=%d)%s' % (c, pred, a, d, flag))
print('总误差² = %.1f' % tot)

# 也试 gamma=2.4 (sRGB 精确) 对比
print()
print('== 另试: 直接用 8bit 值拟合 (不做 gamma, 看是否更接近) ==')
rows2 = [tuple(v/255.0 for v in c) for c,_ in S]
M2 = []
for ch in range(3):
    b = [a[ch]/255.0 for _,a in S]
    coef = solve(rows2, b)
    M2.append(coef)
    print('  M2[%s] = [%.4f %.4f %.4f]' % ('RGB'[ch], coef[0], coef[1], coef[2]))
tot2 = 0.0
for c, a in S:
    lc = [v/255.0 for v in c]
    pred = tuple(max(0,min(255,round(255.0*sum(M2[ch][k]*lc[k] for k in range(3))))) for ch in range(3))
    d = sum(abs(pred[i]-a[i]) for i in range(3))
    tot2 += d*d
    flag = '  <-- 差大' if d > 30 else ''
    print('  C=%s -> 预测%s 实际%s (Δ=%d)%s' % (c, pred, a, d, flag))
print('总误差² = %.1f' % tot2)
