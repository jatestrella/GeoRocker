# Build the macOS package of this game: download, unzip, double-click "開始遊戲.command" and play.
#
#   python -X utf8 games/georocker/standalone/make_mac_package.py [--name GeoRocker_mac] [--branch release] [--out DIR] [--class]
#       [--engine DIR]   folder with the official Luanti macOS zips (default: <out>/mac_engine):
#                        luanti_<ver>-macos<os>_arm64.zip and luanti_<ver>-macos<os>_x86_64.zip from
#                        https://github.com/luanti-org/luanti/releases (same version as the Windows engine)
#
# Package layout (the zip has Unix permissions, so the .command stays executable after Archive Utility):
#   <name>/開始遊戲.command        start script (standalone/mac/start.command)
#   <name>/說明.txt                 standalone/mac/README.txt
#   <name>/LICENSE-NOTICE.txt
#   <name>/engine/<arch>/luanti.app copied entry by entry from the official zips, unchanged (code signature intact)
#   <name>/data/                    Luanti user folder (MINETEST_USER_PATH): games/georocker, worlds/, minetest.conf
# Maps are filtered like make_package.ps1: class maps only with --class, dev maps left out on the release branch.
import argparse, glob, os, subprocess, time, zipfile

here = os.path.dirname(os.path.abspath(__file__))       # games/georocker/standalone
game = os.path.dirname(here)                              # games/georocker
root = os.path.dirname(os.path.dirname(game))             # Luanti root

ap = argparse.ArgumentParser()
ap.add_argument("--name", default="GeoRocker_mac")
ap.add_argument("--branch", default="release")
ap.add_argument("--out", default=os.path.dirname(root))
ap.add_argument("--engine", default=None)
ap.add_argument("--class", dest="cls", action="store_true")
a = ap.parse_args()
engine_dir = a.engine or os.path.join(a.out, "mac_engine")

engines = {}
for arch in ("arm64", "x86_64"):
	found = sorted(glob.glob(os.path.join(engine_dir, f"luanti_*-macos*_{arch}.zip")))
	if not found:
		raise SystemExit(f"[mac] missing Luanti macOS engine zip for {arch} in {engine_dir}")
	engines[arch] = found[-1]

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

def text(path):
	with open(path, "rb") as f:
		return f.read().replace(b"\r\n", b"\n")

CONF = "\n".join([
	"menu_last_game = georocker", "creative_mode = false", "enable_damage = true", "enable_server = false",
	"server_announce = false", "sound_volume = 0.8", "name = player", "enable_esc_dialog = false", "language = zh_TW", ""])
NOTICE = "\n".join([
	"engine/ holds the official Luanti engine (https://www.luanti.org) builds for macOS, unchanged,",
	"licensed under the GNU LGPL 2.1 or later. Source code: https://github.com/luanti-org/luanti",
	"Mods taken from Minetest Game keep their own license files inside data/games/georocker/mods/<mod>.",
	"Font: Cubic 11 by ACh-K (https://github.com/ACh-K/Cubic-11), SIL Open Font License,",
	"see data/games/georocker/fonts/Cubic_11_OFL.txt.", ""])

n = 0
with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
	add(z, top, mode=0o755)
	add(z, top + "開始遊戲.command", data=text(os.path.join(here, "mac", "start.command")), mode=0o755)
	add(z, top + "說明.txt", data=text(os.path.join(here, "mac", "README.txt")))
	add(z, top + "LICENSE-NOTICE.txt", data=NOTICE.encode())
	# engines: copy every entry as it is (permissions, AppleDouble files under __MACOSX/ moved to the new path)
	add(z, top + "engine/", mode=0o755)
	for arch, zf in engines.items():
		add(z, top + f"engine/{arch}/", mode=0o755)
		with zipfile.ZipFile(zf) as src:
			for i in src.infolist():
				if i.filename.startswith("__MACOSX/"):
					name = "__MACOSX/" + top + f"engine/{arch}/" + i.filename[len("__MACOSX/"):]
				else:
					name = top + f"engine/{arch}/" + i.filename
				zi = zipfile.ZipInfo(name, i.date_time)
				zi.create_system, zi.external_attr, zi.compress_type = i.create_system, i.external_attr, zipfile.ZIP_DEFLATED
				z.writestr(zi, src.read(i))
		print(f"[mac] engine {arch}: {os.path.basename(zf)}")
	# user folder with the game
	for d in ("data/", "data/worlds/", "data/games/"):
		add(z, top + d, mode=0o755)
	add(z, top + "data/minetest.conf", data=CONF.encode())
	for d, dirs, files in os.walk(game):
		rel = os.path.relpath(d, game).replace("\\", "/")
		dirs[:] = sorted(x for x in dirs if x not in (".git", "docs", "__pycache__")
			and not (rel == "standalone/maps" and x in skip_maps))
		base = top + "data/games/georocker/" + ("" if rel == "." else rel + "/")
		add(z, base, mode=0o755)
		for fn in sorted(files):
			add(z, base + fn, src=os.path.join(d, fn)); n += 1
os.replace(tmp, zpath)
print(f"[mac] {zpath}: {n} game files, {os.path.getsize(zpath) / 1048576:.1f} MB")
