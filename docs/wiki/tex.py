# -*- coding: utf-8 -*-
# 照 Luanti 的貼圖指令（texture modifier）把物品圖示畫成 PNG，給 wiki 用。
#   支援：檔名、^ 疊圖、( ) 分組、[fill:WxH:color、[fill:WxH:X,Y:color、[colorize:color[:ratio]、[mask:file、
#        [transformR90／R180／R270／FX／FY、[opacity:n、[resize:WxH
#   方塊沒有 inventory_image 的：用頂面和側面貼圖畫成立體小方塊（跟遊戲物品欄的方塊圖一樣的視角）
# 用法：python tex.py <wiki_tex.json> <輸出資料夾> <貼圖資料夾>...
import json, os, sys
from PIL import Image

SEARCH = []

def color(s):
	s = s.strip()
	if s.startswith("#"):
		h = s[1:]
		if len(h) in (3, 4): h = "".join(c * 2 for c in h)
		r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
		a = int(h[6:8], 16) if len(h) >= 8 else 255
		return (r, g, b, a)
	named = {"white": (255, 255, 255, 255), "black": (0, 0, 0, 255), "red": (255, 0, 0, 255)}
	return named.get(s, (255, 0, 255, 255))

def load(name):
	for d in SEARCH:
		p = os.path.join(d, name)
		if os.path.exists(p): return Image.open(p).convert("RGBA")
	print("  找不到貼圖", name)
	return Image.new("RGBA", (16, 16), (255, 0, 255, 255))

def split_top(s, sep):
	out, depth, cur = [], 0, ""
	for ch in s:
		if ch == "(": depth += 1
		elif ch == ")": depth -= 1
		if ch == sep and depth == 0:
			out.append(cur); cur = ""
		else: cur += ch
	out.append(cur)
	return out

def overlay(base, top):
	if top.size != base.size:
		w, h = max(base.size[0], top.size[0]), max(base.size[1], top.size[1])
		base = base.resize((w, h), Image.NEAREST); top = top.resize((w, h), Image.NEAREST)
	return Image.alpha_composite(base, top)

def modifier(img, m):
	name, _, arg = m[1:].partition(":")
	if name == "fill":
		parts = arg.split(":")
		w, h = [int(v) for v in parts[0].split("x")]
		if len(parts) == 3:
			x, y = [int(v) for v in parts[1].split(",")]; col = color(parts[2])
		else:
			x, y, col = 0, 0, color(parts[1])
		if img is None:
			return Image.new("RGBA", (w, h), col)
		img = img.copy()
		rect = Image.new("RGBA", (w, h), col)
		if col[3] == 255: img.paste(rect, (x, y))
		else:
			layer = Image.new("RGBA", img.size, (0, 0, 0, 0)); layer.paste(rect, (x, y))
			img = Image.alpha_composite(img, layer)
		return img
	if name == "colorize":
		parts = arg.split(":")
		c = color(parts[0])
		ratio = (int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else c[3]) / 255
		px = img.load()
		out = img.copy(); po = out.load()
		for y in range(img.size[1]):
			for x in range(img.size[0]):
				r, g, b, a = px[x, y]
				po[x, y] = (round(r + (c[0] - r) * ratio), round(g + (c[1] - g) * ratio), round(b + (c[2] - b) * ratio), a)
		return out
	if name == "mask":
		mk = render(arg).resize(img.size, Image.NEAREST)
		out = img.copy(); po, pm = out.load(), mk.load()
		for y in range(img.size[1]):
			for x in range(img.size[0]):
				p, q = po[x, y], pm[x, y]
				po[x, y] = tuple(p[i] & q[i] for i in range(4))
		return out
	if name.startswith("transform"):
		t = name[len("transform"):]
		ops = {"R90": Image.ROTATE_90, "R180": Image.ROTATE_180, "R270": Image.ROTATE_270,
			"FX": Image.FLIP_LEFT_RIGHT, "FY": Image.FLIP_TOP_BOTTOM}
		return img.transpose(ops[t]) if t in ops else img
	if name == "opacity":
		out = img.copy(); a = out.getchannel("A").point(lambda v: v * int(arg) // 255); out.putalpha(a); return out
	if name == "resize":
		w, h = [int(v) for v in arg.split("x")]; return img.resize((w, h), Image.NEAREST)
	print("  不支援的指令", m[:40])
	return img

def render(s):
	img = None
	for part in split_top(s, "^"):
		part = part.strip()
		if not part: continue
		if part.startswith("(") and part.endswith(")"):
			sub = render(part[1:-1]); img = sub if img is None else overlay(img, sub)
		elif part.startswith("["):
			img = modifier(img, part)
		else:
			sub = load(part); img = sub if img is None else overlay(img, sub)
	return img if img is not None else Image.new("RGBA", (16, 16), (0, 0, 0, 0))

def cube(top, side, size=128):
	# 等角視角的立體方塊：頂面菱形、左右兩個側面（左亮右暗）
	top = top.convert("RGBA").resize((16, 16), Image.NEAREST)
	side = side.convert("RGBA").resize((16, 16), Image.NEAREST)
	out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
	s = size / 2
	def face(img, coef, mapf, shade):
		src = img.load(); dst = out.load()
		for py in range(size):
			for px in range(size):
				uv = mapf(px + 0.5, py + 0.5)
				if uv is None: continue
				u, v = uv
				if 0 <= u < 1 and 0 <= v < 1:
					r, g, b, a = src[int(u * 16), int(v * 16)]
					if a: dst[px, py] = (int(r * shade), int(g * shade), int(b * shade), 255)
	cx = size / 2
	h = s / 2           # 頂面菱形的半高
	def top_map(x, y):
		# 菱形頂點：上 (cx, 0)、右 (size, h)、下 (cx, 2h)、左 (0, h)
		a = ((x - cx) / s + (y / h - 1)) / 2 + 0.5
		b = (-(x - cx) / s + (y / h - 1)) / 2 + 0.5
		return (a, b) if 0 <= a < 1 and 0 <= b < 1 else None
	def left_map(x, y):
		if x > cx: return None
		u = x / cx; v = (y - h - u * h) / s
		return (u, v)
	def right_map(x, y):
		if x < cx: return None
		u = (x - cx) / cx; v = (y - 2 * h + u * h) / s
		return (u, v)
	face(side, None, left_map, 0.85)
	face(side, None, right_map, 0.65)
	face(top, None, top_map, 1.0)
	return out

def main():
	data = json.load(open(sys.argv[1], encoding="utf-8"))
	outdir = sys.argv[2]
	SEARCH.extend(sys.argv[3:])
	os.makedirs(outdir, exist_ok=True)
	for k, v in sorted(data.items()):
		if v.get("missing"): continue
		tiles = v.get("tiles") or []
		if v.get("inv"):
			img = render(v["inv"]).resize((128, 128), Image.NEAREST)
		elif tiles:
			top = render(tiles[0]); side = render(tiles[2] if len(tiles) > 2 else tiles[-1])
			img = cube(top, side)
		else:
			continue
		img.save(os.path.join(outdir, k + ".png"))
		print("ok", k)

if __name__ == "__main__":
	main()
