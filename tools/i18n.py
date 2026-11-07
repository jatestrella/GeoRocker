# -*- coding: utf-8 -*-
# 抽出 mods/rockmech 裡所有 S("...") 字串，更新翻譯檔：
#   locale/template.txt          全部原文（英文），給新語言當範本
#   locale/rockmech.<lang>.tr    每種語言：保留已有的翻譯，補上新字串（翻譯留空），程式裡已經沒有的移到檔尾「not used」
# 用法：python tools/i18n.py            更新並列出各語言缺幾句
#       python tools/i18n.py --check    只檢查，有缺翻譯就回傳 1（測試用）
# Luanti 翻譯檔格式：一行一句「原文=翻譯」，原文和翻譯裡的 = 寫成 @=、換行寫成 @n
import glob, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "..", "mods", "rockmech")
LOC = os.path.join(MOD, "locale")
DOMAIN = "rockmech"

CALL = re.compile(r'(?<![\w.])S\(\s*"((?:[^"\\\n]|\\.)*)"')
LUA_ESC = {"n": "\n", "t": "\t", '"': '"', "'": "'", "\\": "\\"}

def unlua(s):
	return re.sub(r"\\(.)", lambda m: LUA_ESC.get(m.group(1), m.group(1)), s)
def esc(s):
	return s.replace("=", "@=").replace("\n", "@n")

# 拿掉 -- 註解（字串裡的 -- 不算）
def strip_comments(src):
	out = []
	for line in src.split("\n"):
		q, i = None, 0
		while i < len(line):
			c = line[i]
			if q:
				if c == "\\": i += 1
				elif c == q: q = None
			elif c in "\"'": q = c
			elif line.startswith("--", i): line = line[:i]; break
			i += 1
		out.append(line)
	return "\n".join(out)
def unesc(s):
	return s.replace("@n", "\n").replace("@=", "=")

def scan():
	order, seen = [], set()
	for f in sorted(glob.glob(os.path.join(MOD, "*.lua"))):
		src = strip_comments(open(f, encoding="utf-8").read())
		for m in CALL.finditer(src):
			s = unlua(m.group(1))
			if s not in seen:
				seen.add(s); order.append((os.path.basename(f), s))
	return order

def parse_tr(path):
	tr = {}
	if not os.path.exists(path): return tr
	for line in open(path, encoding="utf-8").read().split("\n"):
		if not line or line.startswith("#"): continue
		i = 0
		while True:
			i = line.find("=", i)
			if i < 0 or line[i - 1:i] != "@": break
			i += 1
		if i < 0: continue
		tr[unesc(line[:i])] = unesc(line[i + 1:])
	return tr

def write_tr(path, order, tr, with_trans=True):
	out = ["# textdomain: " + DOMAIN]
	cur = None
	for f, s in order:
		if f != cur:
			out.append(""); out.append("### " + f); cur = f
		out.append(esc(s) + "=" + (esc(tr.get(s, "")) if with_trans else ""))
	used = {s for _, s in order}
	old = [s for s in tr if s not in used and tr[s]]
	if old:
		out.append(""); out.append("##### not used anymore #####")
		for s in old: out.append(esc(s) + "=" + esc(tr[s]))
	open(path, "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")

def main():
	check = "--check" in sys.argv
	os.makedirs(LOC, exist_ok=True)
	order = scan()
	if not check:
		write_tr(os.path.join(LOC, "template.txt"), order, {}, with_trans=False)
	missing_any = False
	for path in sorted(glob.glob(os.path.join(LOC, DOMAIN + ".*.tr"))):
		tr = parse_tr(path)
		missing = [s for _, s in order if not tr.get(s)]
		if not check: write_tr(path, order, tr)
		print("%s：%d 句，缺 %d 句" % (os.path.basename(path), len(order), len(missing)))
		for s in missing[:10]: print("   缺：", s.replace("\n", "\\n")[:80])
		missing_any = missing_any or bool(missing)
	print("原文共 %d 句" % len(order))
	sys.exit(1 if check and missing_any else 0)

if __name__ == "__main__":
	main()
