# -*- coding: utf-8 -*-
# 外觀調整器：產生遊戲裡幾個畫面的實際 formspec（中文），連同用到的貼圖嵌進一個 HTML 檔，
# 在瀏覽器裡點選、拖曳、改顏色，把改動複製給 Claude 改回程式。
# 用法：python tools/ui_tuner/build.py [輸出的 html 路徑]
#   預設輸出 tools/ui_tuner/out/ui_tuner.html（不進 git）
# 做法：在 tools/ui_tuner/_world 開一個暫時世界（不進 git），worldmods 放 uidump.lua，
#       跑無頭伺服器產生 ui_screens.json，再把 template.html 填好
import base64, glob, json, os, re, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
GAME = os.path.normpath(os.path.join(HERE, "..", ".."))
ROOT = os.path.normpath(os.path.join(GAME, "..", ".."))          # Luanti 安裝目錄
EXE = os.path.join(ROOT, "bin", "luanti.exe")
WORLD = os.path.join(HERE, "_world")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "out", "ui_tuner.html")

def make_world():
	if os.path.isdir(WORLD): shutil.rmtree(WORLD)
	os.makedirs(os.path.join(WORLD, "worldmods", "uidump"))
	with open(os.path.join(WORLD, "world.mt"), "w", encoding="utf-8") as f:
		f.write("gameid = mining_sim\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\n")
	conf = os.path.join(ROOT, "worlds", "class_coal", "rockmech.conf")
	if os.path.isfile(conf): shutil.copy(conf, os.path.join(WORLD, "rockmech.conf"))
	shutil.copy(os.path.join(HERE, "uidump.lua"), os.path.join(WORLD, "worldmods", "uidump", "init.lua"))
	with open(os.path.join(WORLD, "worldmods", "uidump", "mod.conf"), "w") as f:
		f.write("name = uidump\ndepends = rockmech\n")

def run_server():
	log = os.path.join(WORLD, "server.log")
	with open(log, "w", encoding="utf-8") as lf:
		subprocess.run([EXE, "--server", "--world", WORLD, "--gameid", "mining_sim", "--port", "30199"],
			stdout=lf, stderr=subprocess.STDOUT, timeout=240, cwd=ROOT)
	path = os.path.join(WORLD, "ui_screens.json")
	if not os.path.isfile(path):
		txt = open(log, encoding="utf-8", errors="replace").read()
		sys.exit("沒有產生 ui_screens.json，伺服器紀錄最後幾行：\n" + "\n".join(txt.splitlines()[-25:]))
	return json.load(open(path, encoding="utf-8"))

def texture_dirs():
	dirs = [os.path.join(ROOT, "textures", "base", "pack"), os.path.join(WORLD, "rockmech_media")]
	dirs += glob.glob(os.path.join(GAME, "mods", "*", "textures"))
	return dirs

def collect_textures(screens):
	names = set()
	for s in screens:
		names.update(re.findall(r"[A-Za-z0-9_\-]+\.png", s["fs"]))
	found = {}
	dirs = texture_dirs()
	for n in sorted(names):
		for d in dirs:
			p = os.path.join(d, n)
			if os.path.isfile(p):
				found[n] = "data:image/png;base64," + base64.b64encode(open(p, "rb").read()).decode()
				break
	missing = sorted(names - set(found))
	if missing: print("找不到的貼圖：", ", ".join(missing))
	return found

def main():
	make_world()
	data = run_server()
	data["textures"] = collect_textures(data["screens"])
	tpl = open(os.path.join(HERE, "template.html"), encoding="utf-8").read()
	blob = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
	html = tpl.replace("/*__DATA__*/null", blob)
	os.makedirs(os.path.dirname(os.path.abspath(OUT)), exist_ok=True)
	with open(OUT, "w", encoding="utf-8") as f: f.write(html)
	print("寫好：", OUT, "（畫面 %d 個、貼圖 %d 張）" % (len(data["screens"]), len(data["textures"])))

if __name__ == "__main__":
	main()
