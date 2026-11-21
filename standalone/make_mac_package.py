# Build the macOS package of this game: a zip with the game folder, an installer (.command) and a README.
# The engine is not included: Mac players install Luanti.app from luanti.org; the installer copies the game
# into Luanti's user folder and sets main_menu_script to standalone/mainmenu.lua (our start screen).
#
#   python -X utf8 games/georocker/standalone/make_mac_package.py [--name GeoRocker_mac] [--branch release] [--out DIR] [--class]
#
# Maps are filtered like make_package.ps1: class maps only with --class, dev maps left out on the release branch.
# The zip is written with Unix permissions so the .command stays executable after Archive Utility unpacks it.
import argparse, os, subprocess, sys, time, zipfile

here = os.path.dirname(os.path.abspath(__file__))       # games/georocker/standalone
game = os.path.dirname(here)                              # games/georocker
root = os.path.dirname(os.path.dirname(game))             # Luanti root

ap = argparse.ArgumentParser()
ap.add_argument("--name", default="GeoRocker_mac")
ap.add_argument("--branch", default="release")
ap.add_argument("--out", default=os.path.dirname(root))
ap.add_argument("--class", dest="cls", action="store_true")
a = ap.parse_args()

try:
	cur = subprocess.run(["git", "-C", game, "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True).stdout.strip()
	if cur != a.branch:
		print(f"[mac] warning: game folder is on branch {cur}, package is for {a.branch}")
except OSError:
	pass

def conf_has(path, key, val):
	try:
		with open(path, encoding="utf-8") as f:
			for line in f:
				k, _, v = line.partition("=")
				if k.strip() == key and v.strip() == val:
					return True
	except OSError:
		pass
	return False

skip_maps = set()
maps = os.path.join(here, "maps")
for m in os.listdir(maps):
	c = os.path.join(maps, m, "map.conf")
	if not a.cls and conf_has(c, "mode", "class"):
		skip_maps.add(m); print("[mac] leaving out class map", m)
	elif a.branch == "release" and conf_has(c, "dev", "true"):
		skip_maps.add(m); print("[mac] leaving out dev map", m)

SKIP_DIRS = {".git", "docs", "__pycache__"}
top = a.name + "/"
zpath = os.path.join(a.out, a.name + ".zip")
tmp = zpath + ".tmp"

def add(z, arc, data=None, src=None, mode=0o644):
	zi = zipfile.ZipInfo(arc, time.localtime(os.path.getmtime(src))[:6] if src else time.localtime()[:6])
	zi.create_system = 3
	zi.compress_type = zipfile.ZIP_DEFLATED
	zi.external_attr = ((0o040000 if arc.endswith("/") else 0o100000) | mode) << 16
	if src:
		with open(src, "rb") as f:
			data = f.read()
	z.writestr(zi, data or b"")

n = 0
with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
	add(z, top, mode=0o755)
	with open(os.path.join(here, "mac", "install.command"), "rb") as f:
		cmd = f.read().replace(b"\r\n", b"\n")
	add(z, top + "安裝遊戲.command", data=cmd, mode=0o755)
	with open(os.path.join(here, "mac", "README.txt"), "rb") as f:
		add(z, top + "說明.txt", data=f.read())
	for d, dirs, files in os.walk(game):
		rel = os.path.relpath(d, game).replace("\\", "/")
		dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS
			and not (rel == "standalone/maps" and x in skip_maps)
			and not (rel == "standalone" and x == "mac"))
		base = top + "georocker/" + ("" if rel == "." else rel + "/")
		add(z, base, mode=0o755)
		for fn in sorted(files):
			add(z, base + fn, src=os.path.join(d, fn)); n += 1
os.replace(tmp, zpath)
print(f"[mac] {zpath}: {n} game files, {os.path.getsize(zpath) / 1048576:.1f} MB")
