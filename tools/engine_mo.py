# -*- coding: utf-8 -*-
# 改 Luanti 引擎翻譯檔（locale/zh_TW/LC_MESSAGES/luanti.mo）裡太長的幾句：
# 字型 22 px 之後，Esc 選單（引擎內建、按鈕大小改不了）的按鈕放不下「離開，回到作業系統」。
# 用法：python tools/engine_mo.py          改 luanti 根目錄的 luanti.mo（第一次會留 luanti.mo.orig）
# 打包（standalone/make_package.ps1）會複製根目錄的 locale，所以安裝包也是改過的。引擎升級後要再跑一次。
import os, shutil, struct, gettext

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
MO = os.path.join(ROOT, "locale", "zh_TW", "LC_MESSAGES", "luanti.mo")

OVERRIDES = {
	"Exit to Menu": "回主選單",
	"Exit to OS": "離開遊戲",
}

def write_mo(path, catalog):
	keys = sorted(catalog.keys())
	ids = [k.encode("utf-8") for k in keys]
	strs = [catalog[k].encode("utf-8") for k in keys]
	n = len(keys)
	koff = 7 * 4
	voff = koff + n * 8
	start = voff + n * 8
	data, ktab, vtab = b"", [], []
	for s in ids:
		ktab.append((len(s), start + len(data))); data += s + b"\0"
	for s in strs:
		vtab.append((len(s), start + len(data))); data += s + b"\0"
	out = struct.pack("<7I", 0x950412de, 0, n, koff, voff, 0, 0)
	for l, o in ktab: out += struct.pack("<2I", l, o)
	for l, o in vtab: out += struct.pack("<2I", l, o)
	with open(path, "wb") as f: f.write(out + data)

def main():
	orig = MO + ".orig"
	if not os.path.exists(orig): shutil.copyfile(MO, orig)
	with open(orig, "rb") as f: t = gettext.GNUTranslations(f)
	cat = {}
	for k, v in t._catalog.items():
		if isinstance(k, tuple):       # 複數形式：照原本的格式（msgid\0msgid_plural → 各形式用 \0 接起來）
			continue
		cat[k] = v
	# 複數形式直接從原始檔搬（GNUTranslations 已經拆開了，這裡從原始表重建）
	with open(orig, "rb") as f: raw = f.read()
	n, ko, vo = struct.unpack("<I", raw[8:12])[0], struct.unpack("<I", raw[12:16])[0], struct.unpack("<I", raw[16:20])[0]
	for i in range(n):
		kl, kp = struct.unpack("<2I", raw[ko + i * 8: ko + i * 8 + 8])
		vl, vp = struct.unpack("<2I", raw[vo + i * 8: vo + i * 8 + 8])
		k = raw[kp:kp + kl].decode("utf-8")
		if "\0" in k or k == "": cat[k] = raw[vp:vp + vl].decode("utf-8")
	for k, v in OVERRIDES.items(): cat[k] = v
	write_mo(MO, cat)
	print("ok:", MO)

main()
