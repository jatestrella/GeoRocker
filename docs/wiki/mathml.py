# -*- coding: utf-8 -*-
# 一小套 TeX → MathML（瀏覽器原生排版，跟維基百科一樣的公式；不用外部程式庫）。
#   支援：^ _ { }、\frac、\dfrac、\sqrt、\sqrt[n]、\text、\mathrm、\operatorname、\left \right、\bar、\hat、\dot、
#        \sum \prod \int（顯示式裡上下限放在上下）、希臘字母、常用運算子與函數名（sin、ln、max…）、\quad \qquad \, \; \!
#   數字 → <mn>，單一英文字母 → 斜體 <mi>，中文等其他字 → <mtext>。
# 用法：render(html) 把 \[ … \]（獨立一行、置中）和 \( … \)（文中）換成 <math>。
import html as _html
import re

GREEK = {
	"alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
	"theta": "θ", "vartheta": "ϑ", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ",
	"sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
	"Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ",
	"Psi": "Ψ", "Omega": "Ω",
}
OPS = {
	"cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥",
	"ne": "≠", "neq": "≠", "approx": "≈", "sim": "∼", "equiv": "≡", "propto": "∝", "to": "→", "rightarrow": "→",
	"leftarrow": "←", "gets": "←", "Rightarrow": "⇒", "infty": "∞", "partial": "∂", "nabla": "∇", "prime": "′",
	"lt": "&lt;", "gt": "&gt;", "ldots": "…", "cdots": "⋯", "in": "∈", "circ": "∘", "deg": "°", "mid": "|",
	"{": "{", "}": "}", "|": "‖", "%": "%",
}
BIG = {"sum": "∑", "prod": "∏", "int": "∫"}
FUNCS = {"sin", "cos", "tan", "cot", "ln", "log", "exp", "max", "min", "lim", "arctan", "sinh", "cosh", "tanh", "sgn"}
SPACES = {"quad": "1em", "qquad": "2em", ",": "0.167em", ";": "0.278em", ":": "0.222em", " ": "0.278em", "!": "-0.167em"}
ACCENTS = {"bar": "¯", "hat": "^", "dot": "˙", "tilde": "~", "vec": "→", "overline": "¯"}


def _esc(s):
	return _html.escape(s, quote=False)


class _P:
	def __init__(self, src, display):
		self.s, self.i, self.display = src, 0, display

	def peek(self):
		self._ws()
		return self.s[self.i] if self.i < len(self.s) else None

	def _ws(self):
		while self.i < len(self.s) and self.s[self.i] in " \t\r\n":
			self.i += 1

	def cmd(self):
		# self.s[self.i] == "\\"
		self.i += 1
		if self.i < len(self.s) and self.s[self.i].isalpha():
			j = self.i
			while j < len(self.s) and self.s[j].isalpha():
				j += 1
			name, self.i = self.s[self.i:j], j
		else:
			name = self.s[self.i]
			self.i += 1
		return name

	def raw_group(self):
		# {…} 的原文（不解析）
		self._ws()
		if self.peek() != "{":
			raise ValueError("要 { ：" + self.s[self.i:self.i + 20])
		depth, j = 0, self.i
		while j < len(self.s):
			if self.s[j] == "{": depth += 1
			elif self.s[j] == "}":
				depth -= 1
				if depth == 0: break
			j += 1
		out = self.s[self.i + 1:j]
		self.i = j + 1
		return out

	def arg(self):
		# 一個參數：{…} 或單一記號
		self._ws()
		if self.peek() == "{":
			self.i += 1
			r = self.expr("}")
			self.i += 1
			return r
		return self.atom()

	def expr(self, end=None):
		items = []
		while True:
			c = self.peek()
			if c is None or (end and c == end): break
			if c == "\\" and self.s.startswith("\\right", self.i): break
			items.append(self.scripted())
		return "".join(items) if len(items) == 1 else "<mrow>" + "".join(items) + "</mrow>"

	def scripted(self):
		base, big = self.atom()
		sub = sup = None
		while True:
			c = self.peek()
			if c == "_" and sub is None:
				self.i += 1; sub = self.arg_plain()
			elif c == "^" and sup is None:
				self.i += 1; sup = self.arg_plain()
			elif c == "'":
				self.i += 1; sup = (sup or "") + "<mo>′</mo>"
				if sup.count("<mo>′</mo>") == 1 and not sup.startswith("<mrow>"): pass
			else:
				break
		if sub is None and sup is None: return base
		under = big and self.display
		if sub is not None and sup is not None:
			tag = "munderover" if under else "msubsup"
			return f"<{tag}>{base}{sub}{_wrap(sup)}</{tag}>"
		if sub is not None:
			tag = "munder" if under else "msub"
			return f"<{tag}>{base}{sub}</{tag}>"
		tag = "mover" if under else "msup"
		return f"<{tag}>{base}{_wrap(sup)}</{tag}>"

	def arg_plain(self):
		r = self.arg()
		return r[0] if isinstance(r, tuple) else r

	def atom(self):
		# 回傳 (MathML, 是不是 ∑ 這類大運算子)
		self._ws()
		c = self.s[self.i]
		if c == "{":
			self.i += 1
			r = self.expr("}")
			self.i += 1
			return ("<mrow>" + r + "</mrow>", False)
		if c == "\\":
			name = self.cmd()
			if name in ("frac", "dfrac", "tfrac"):
				a, b = self.arg_plain(), self.arg_plain()
				return (f"<mfrac>{a}{b}</mfrac>", False)
			if name == "sqrt":
				self._ws()
				if self.peek() == "[":
					j = self.s.index("]", self.i)
					idx = _P(self.s[self.i + 1:j], self.display).expr()
					self.i = j + 1
					return (f"<mroot>{_wrap(self.arg_plain())}{idx}</mroot>", False)
				return (f"<msqrt>{self.arg_plain()}</msqrt>", False)
			if name == "text":
				return (f"<mtext>{_esc(self.raw_group())}</mtext>", False)
			if name in ("mathrm", "operatorname", "rm"):
				t = self.raw_group()
				return (f'<mi mathvariant="normal">{_esc(t)}</mi>' if t.isalpha() or len(t) > 1 else f'<mi mathvariant="normal">{_esc(t)}</mi>', False)
			if name in ("left", "right"):
				self._ws()
				d = self.s[self.i]
				if d == "\\":
					dn = self.cmd()
					d = OPS.get(dn, dn)
				else:
					self.i += 1
				if d == ".": return ("", False)
				if name == "left":
					inner = self.expr()
					self._ws()
					closing = ""
					if self.s.startswith("\\right", self.i):
						self.cmd()
						self._ws()
						e = self.s[self.i]
						if e == "\\":
							en = self.cmd(); e = OPS.get(en, en)
						else:
							self.i += 1
						closing = "" if e == "." else f'<mo stretchy="true">{_esc(e)}</mo>'
					return (f'<mrow><mo stretchy="true">{_esc(d)}</mo>{inner}{closing}</mrow>', False)
				return (f'<mo stretchy="true">{_esc(d)}</mo>', False)
			if name in ACCENTS:
				a = self.arg_plain()
				return (f'<mover accent="true">{a}<mo>{ACCENTS[name]}</mo></mover>', False)
			if name in GREEK:
				g = GREEK[name]
				return ((f'<mi mathvariant="normal">{g}</mi>' if name[0].isupper() else f"<mi>{g}</mi>"), False)
			if name in BIG:
				return (f'<mo largeop="true" movablelimits="true">{BIG[name]}</mo>', True)
			if name in FUNCS:
				return (f'<mrow><mspace width="0.167em"></mspace><mi>{name}</mi><mo>&#x2061;</mo></mrow>', False)
			if name in SPACES:
				return (f'<mspace width="{SPACES[name]}"></mspace>', False)
			if name in OPS:
				return (f"<mo>{OPS[name]}</mo>", False)
			raise ValueError("不認得的指令 \\" + name)
		self.i += 1
		if c.isdigit() or (c == "." and self.i < len(self.s) and self.s[self.i].isdigit()):
			j = self.i
			while j < len(self.s) and (self.s[j].isdigit() or (self.s[j] in ".," and j + 1 < len(self.s) and self.s[j + 1].isdigit())):
				j += 1
			num = c + self.s[self.i:j]
			self.i = j
			return (f"<mn>{num}</mn>", False)
		if c.isascii() and c.isalpha():
			return (f"<mi>{c}</mi>", False)
		if c in "αβγδεζηθικλμνξπρστυφχψωϕ":
			return (f"<mi>{c}</mi>", False)
		if c in "+-−=<>()[]|,;:/!·×÷≤≥≈→←∞°%′≠∑*":
			m = {"-": "−", "<": "&lt;", ">": "&gt;"}.get(c, c)
			if c in "()[]|":
				return (f'<mo stretchy="false">{m}</mo>', False)
			return (f"<mo>{m}</mo>", False)
		return (f"<mtext>{_esc(c)}</mtext>", False)


def _wrap(x):
	return x if x.startswith("<mrow>") else "<mrow>" + x + "</mrow>"


def tex2mathml(src, display=True):
	p = _P(src.strip(), display)
	body = p.expr()
	if p.i < len(p.s):
		raise ValueError("沒讀完：" + p.s[p.i:p.i + 30])
	d = ' display="block"' if display else ""
	return f'<math{d}>{body}</math>'


def render(text):
	def disp(m):
		return '<div class="formula">' + tex2mathml(m.group(1), True) + "</div>"
	def inl(m):
		return tex2mathml(m.group(1), False)
	text = re.sub(r"\\\[(.+?)\\\]", disp, text, flags=re.S)
	text = re.sub(r"\\\((.+?)\\\)", inl, text, flags=re.S)
	return text


def strip(text):
	# 搜尋用的純文字：公式整段拿掉
	text = re.sub(r"\\\[(.+?)\\\]", " ", text, flags=re.S)
	return re.sub(r"\\\((.+?)\\\)", " ", text, flags=re.S)
