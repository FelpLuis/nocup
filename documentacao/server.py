#!/usr/bin/env python3
"""
UPDOWN NOC — Documentação de equipamentos (documentacao.noc.updown.com.br)

Site editável com a documentação das interfaces de roteadores, switches e DWDM,
separados por site e rack, com o status atual de cada interface lido do Zabbix.

  GET  /                  -> site (static/index.html)
  GET  /api/dados         -> documentação (data/equipamentos.json) + rev + usuário
  PUT  /api/dados         -> salva a documentação (precisa de login; controle de versão por "rev")
  GET  /api/zabbix        -> cache do Zabbix (status, velocidade, Rx/Tx, sysName, sysLocation...)
  POST /api/zabbix/sync   -> lê o Zabbix agora
  GET  /api/historico     -> lista das últimas versões salvas
  GET  /api/cofre         -> cofre de acessos DO USUÁRIO LOGADO (só o conteúdo cifrado no navegador)
  PUT  /api/cofre         -> salva o cofre cifrado do usuário logado
  GET  /api/cofre/legado  -> cofre compartilhado antigo (versão anterior), para trazer ao cofre pessoal
  DELETE /api/cofre/legado -> retira o cofre compartilhado antigo do servidor (guarda cópia cifrada)
  GET  /healthz           -> "ok"

Os dados ficam em DATA_DIR (padrão /opt/documentacao-noc/data):
  equipamentos.json   documentação (o que a equipe edita)
  zabbix.json         cache do Zabbix (recriado a cada SYNC_MINUTES)
  historico/          cópia de cada versão anterior (mantém HISTORY_KEEP)

Só usa a biblioteca padrão do Python 3.8+.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import ssl
import sys
import threading
import time
import urllib.request
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse, quote

BASE = Path(__file__).resolve().parent


def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, flush=True)


# ----------------------------------------------------------------- config ---
def load_env(path):
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = re.sub(r"\s+#.*$", "", v).strip().strip('"').strip("'")
        os.environ.setdefault(k.strip(), v)


load_env(BASE / "config.env")


def env(name, default=None, cast=str):
    v = os.environ.get(name)
    if v is None or str(v).strip() == "":
        v = default
    if v is None:
        return None
    try:
        return cast(v)
    except Exception:
        log(f"config: valor inválido em {name}={v!r}; usando {default!r}")
        return cast(default)


ZBX_URL = env("ZABBIX_URL", "http://127.0.0.1:19090").rstrip("/")
ZBX_TOKEN = env("ZABBIX_TOKEN", "")
ZBX_VERIFY_TLS = env("ZABBIX_VERIFY_TLS", "1") == "1"
SYNC_MINUTES = env("SYNC_MINUTES", "5", int)
LISTEN = env("LISTEN", "127.0.0.1")   # atrás do nginx; LISTEN=0.0.0.0 só de propósito
PORT = env("PORT", "8447", int)
DATA_DIR = Path(env("DATA_DIR", str(BASE / "data")))
HISTORY_KEEP = env("HISTORY_KEEP", "200", int)
LOGIN = env("LOGIN", "1") == "1"
# Cookie com Secure: auto (= quando o nginx repassa X-Forwarded-Proto https) | 1 | 0
COOKIE_SECURE = env("COOKIE_SECURE", "auto").strip().lower()
# Login único pelo Portal NOC (portal.updown.com.br): o nginx confere a sessão no portal
# (auth_request) e repassa o usuário no cabeçalho X-Portal-User. PORTAL=1 liga — o
# vincular-portal.sh do repositório já deixa assim. Com ele, o usuário e as permissões
# vêm do portal e o login próprio desta tela deixa de ser usado.
PORTAL = env("PORTAL", "0") == "1"
PORTAL_URL = env("PORTAL_URL", "https://portal.updown.com.br").rstrip("/")
PORTAL_SISTEMA = env("PORTAL_SISTEMA", "documentacao")
# Conta do site (padrão: NOC). A senha fica só como hash PBKDF2; troque com: python3 server.py senha
LOGIN_USUARIO_NOME = env("LOGIN_USUARIO", "NOC").strip()
LOGIN_USUARIO = LOGIN_USUARIO_NOME.lower()
LOGIN_SENHA_HASH = env("LOGIN_SENHA_HASH", "")
# Usuários extras do Painel das OLTs (vazio = só a conta acima)
_uf = env("USERS_FILE", "")
USERS_FILE = Path(_uf) if _uf else None
BASIC_AUTH = env("BASIC_AUTH", "")
SESSION_HOURS = env("SESSION_HOURS", "12", int)
SESSION_TV_DAYS = env("SESSION_TV_DAYS", "90", int)
# Quem pode editar (vazio = todos os usuários com login). Ex.: EDITORES=luis,ana
EDITORES = {u.strip().lower() for u in env("EDITORES", "").split(",") if u.strip()}

DOC_FILE = DATA_DIR / "equipamentos.json"
# Cofre de acessos: UM POR USUÁRIO (do portal ou da conta local). Cada arquivo guarda só o
# conteúdo CIFRADO no navegador do dono (AES-GCM com a senha mestra dele): nem outro
# usuário, nem o administrador, nem o servidor conseguem abrir.
COFRES_DIR = DATA_DIR / "cofres"
COFRE_LEGADO = DATA_DIR / "cofre.json"        # cofre compartilhado da versão anterior (se existir)
COFRE_HIST = DATA_DIR / "historico-cofre"
ZBX_FILE = DATA_DIR / "zabbix.json"
HIST_DIR = DATA_DIR / "historico"
MAX_BODY = 8 * 1024 * 1024


# ------------------------------------------------------------------ dados ---
def write_atomic(path, obj):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, path)


class Store:
    def __init__(self):
        self.lock = threading.Lock()
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        HIST_DIR.mkdir(parents=True, exist_ok=True)
        if not DOC_FILE.exists():
            seed = BASE / "dados-iniciais.json"
            if seed.exists():
                shutil.copy(seed, DOC_FILE)
                log(f"dados: criado {DOC_FILE} a partir de dados-iniciais.json")
            else:
                write_atomic(DOC_FILE, {"rev": 1, "devices": []})

    def read(self):
        with self.lock:
            return json.loads(DOC_FILE.read_text(encoding="utf-8"))

    def save(self, doc, rev, user):
        """Grava se rev bate com a versão atual. Retorna (ok, rev_atual)."""
        with self.lock:
            cur = json.loads(DOC_FILE.read_text(encoding="utf-8"))
            cur_rev = int(cur.get("rev", 1))
            if int(rev) != cur_rev:
                return False, cur_rev, cur.get("updated_by"), cur.get("updated")
            stamp = time.strftime("%Y%m%d-%H%M%S")
            shutil.copy(DOC_FILE, HIST_DIR / f"{stamp}-rev{cur_rev}.json")
            doc["rev"] = cur_rev + 1
            doc["updated"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
            doc["updated_by"] = user or "anônimo"
            write_atomic(DOC_FILE, doc)
            hist = sorted(HIST_DIR.glob("*.json"))
            for old in hist[:-HISTORY_KEEP] if len(hist) > HISTORY_KEEP else []:
                old.unlink(missing_ok=True)
            return True, doc["rev"], doc["updated_by"], doc["updated"]

    def history(self):
        out = []
        for f in sorted(HIST_DIR.glob("*.json"), reverse=True)[:50]:
            try:
                d = json.loads(f.read_text(encoding="utf-8"))
                out.append({"arquivo": f.name, "rev": d.get("rev"), "updated": d.get("updated"),
                            "updated_by": d.get("updated_by")})
            except Exception:
                continue
        return out


def _dono(user):
    """Nome de arquivo seguro e único para o usuário (sem barras, sem '..')."""
    u = (user or "").strip().lower()
    base = re.sub(r"[^a-z0-9._-]+", "_", u).strip("._") or "usuario"
    return f"{base[:60]}-{hashlib.sha256(u.encode()).hexdigest()[:10]}"


class Cofre:
    """Cofres individuais já cifrados pelo navegador. O servidor não conhece nenhuma senha mestra.
    Cada requisição só lê ou grava o cofre do usuário da sessão; o nome nunca vem do navegador."""

    def __init__(self):
        self.lock = threading.Lock()
        COFRES_DIR.mkdir(parents=True, exist_ok=True)
        os.chmod(COFRES_DIR, 0o700)
        (COFRE_HIST / "usuarios").mkdir(parents=True, exist_ok=True)

    def _f(self, user):
        return COFRES_DIR / f"{_dono(user)}.json"

    def read(self, user):
        with self.lock:
            try:
                return json.loads(self._f(user).read_text(encoding="utf-8"))
            except FileNotFoundError:
                return {"rev": 0, "blob": None}

    def save(self, user, blob, rev):
        f = self._f(user)
        with self.lock:
            try:
                cur = json.loads(f.read_text(encoding="utf-8"))
            except FileNotFoundError:
                cur = {"rev": 0}
            if int(rev) != int(cur.get("rev", 0)):
                return False, cur.get("rev", 0)
            if f.exists():
                hd = COFRE_HIST / "usuarios" / _dono(user)
                hd.mkdir(parents=True, exist_ok=True)
                os.chmod(hd, 0o700)
                shutil.copy(f, hd / f"{time.strftime('%Y%m%d-%H%M%S')}-rev{cur.get('rev', 0)}.json")
                hist = sorted(hd.glob("*.json"))
                for old in hist[:-30] if len(hist) > 30 else []:
                    old.unlink(missing_ok=True)
            novo = {"rev": int(cur.get("rev", 0)) + 1, "dono": user, "blob": blob,
                    "updated": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
            write_atomic(f, novo)
            os.chmod(f, 0o600)
            return True, novo["rev"]

    def legado(self):
        try:
            c = json.loads(COFRE_LEGADO.read_text(encoding="utf-8"))
            return c if c.get("blob") else None
        except (FileNotFoundError, ValueError):
            return None

    def retirar_legado(self, user):
        with self.lock:
            if not COFRE_LEGADO.exists():
                return False
            os.replace(COFRE_LEGADO, COFRE_HIST / f"legado-compartilhado-{time.strftime('%Y%m%d-%H%M%S')}-por-{_dono(user)}.json")
            return True


def valid_blob(b):
    if not isinstance(b, dict) or b.get("alg") != "AES-GCM" or b.get("kdf") != "PBKDF2-SHA256":
        return "cofre em formato inválido"
    for k in ("salt", "iv", "ct"):
        if not isinstance(b.get(k), str) or not re.fullmatch(r"[A-Za-z0-9+/=]+", b[k]):
            return "cofre em formato inválido"
    if not isinstance(b.get("iter"), int) or b["iter"] < 100000:
        return "cofre com derivação de chave fraca demais"
    return None


def valid_doc(doc):
    if not isinstance(doc, dict) or not isinstance(doc.get("devices"), list):
        return "formato inválido: falta a lista devices"
    if len(doc["devices"]) > 500:
        return "equipamentos demais"
    for d in doc["devices"]:
        if not isinstance(d, dict) or not isinstance(d.get("name"), str) or not isinstance(d.get("ports"), list):
            return "equipamento sem nome ou sem lista de interfaces"
        if len(d["ports"]) > 5000:
            return f"interfaces demais em {d['name']}"
        for p in d["ports"]:
            if not isinstance(p, dict):
                return f"interface inválida em {d['name']}"
            p.pop("z", None)   # dados do Zabbix não são gravados na documentação
    return None


# ----------------------------------------------------------------- zabbix ---
class Zabbix:
    def __init__(self, url, token, verify=True):
        self.url = url + "/api_jsonrpc.php"
        self.token = token
        self.ctx = None
        if url.startswith("https") and not verify:
            self.ctx = ssl._create_unverified_context()

    def call(self, method, params):
        body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
        req = urllib.request.Request(self.url, data=body, headers={
            "Content-Type": "application/json-rpc", "Authorization": "Bearer " + self.token})
        with urllib.request.urlopen(req, timeout=60, context=self.ctx) as r:
            res = json.loads(r.read().decode("utf-8"))
        if "error" in res:
            raise RuntimeError(f"{method}: {res['error'].get('data') or res['error'].get('message')}")
        return res["result"]


IF_RX = re.compile(r"^Interface (.+?): (Status Operacional|Operational status|Velocidade|Speed|RxPower|TxPower|"
                   r"Bits Recebidos|Bits received|Bits Enviados|Bits sent)$")
CAMPO = {"Status Operacional": "st", "Operational status": "st", "Velocidade": "sp", "Speed": "sp",
         "RxPower": "rx", "TxPower": "tx", "Bits Recebidos": "in", "Bits received": "in",
         "Bits Enviados": "out", "Bits sent": "out"}
OPER = {"1": "UP", "2": "DOWN", "3": "DOWN", "5": "DOWN", "7": "DOWN"}
IGNORAR_IF = re.compile(r"(-mpls|-gre)$|^Console", re.I)
# OLTs ZTE (template do painel das OLTs): sinal do módulo por porta e resumo das ONUs por PON
PORTA_RX = re.compile(r"^Porta (\d+/\d+/\d+): (RX|TX) do módulo$")
PON_RX = re.compile(r"^PON (\d+/\d+/\d+): (ONUs com leitura de sinal|RX médio das ONUs|ONUs com sinal baixo|RX da pior ONU)$")
PON_CAMPO = {"ONUs com leitura de sinal": "onus", "RX médio das ONUs": "rxm", "ONUs com sinal baixo": "low",
             "RX da pior ONU": "worst"}


def fmt_speed(v):
    try:
        n = int(float(v))
    except (TypeError, ValueError):
        return ""
    if n >= 10 ** 9:
        g = n / 10 ** 9
        return f"{g:.0f}G" if abs(g - round(g)) < 0.05 else f"{g:.1f}G".replace(".", ",")
    if n >= 10 ** 6:
        return f"{n // 10 ** 6}M"
    return ""


def fmt_dbm(v):
    try:
        return f"{float(v):.2f}"
    except (TypeError, ValueError):
        return ""


class ZabbixSync:
    def __init__(self, store):
        self.store = store
        self.zbx = Zabbix(ZBX_URL, ZBX_TOKEN, ZBX_VERIFY_TLS) if ZBX_TOKEN else None
        self.lock = threading.Lock()
        self.wake = threading.Event()
        self.err = None

    def cache(self):
        try:
            return json.loads(ZBX_FILE.read_text(encoding="utf-8"))
        except (FileNotFoundError, ValueError):
            return {"synced": None, "hosts": {}}

    def run(self):
        if not self.zbx:
            self.err = "ZABBIX_TOKEN não configurado"
            return False
        with self.lock:
            try:
                doc = self.store.read()
                names = sorted({n for d in doc.get("devices", []) for n in d.get("zabbix_hosts", []) if n})
                if not names:
                    self.err = "nenhum equipamento ligado a um host do Zabbix (campo zabbix_hosts)"
                    return False
                hosts = self.zbx.call("host.get", {"output": ["hostid", "host", "name", "status"],
                                                   "selectInterfaces": ["ip"],
                                                   "filter": {"name": names}})
                found = {h["name"] for h in hosts}
                extra = [n for n in names if n not in found]
                if extra:   # aceita também o nome técnico (host)
                    hosts += self.zbx.call("host.get", {"output": ["hostid", "host", "name", "status"],
                                                        "selectInterfaces": ["ip"], "filter": {"host": extra}})
                ids = [h["hostid"] for h in hosts]
                items = self.zbx.call("item.get", {"hostids": ids, "output": ["hostid", "name", "key_", "lastvalue"],
                                                   "filter": {"status": 0}}) if ids else []
                by = {h["hostid"]: {"hostid": h["hostid"], "name": h["name"], "host": h["host"],
                                    "ip": (h.get("interfaces") or [{}])[0].get("ip", ""), "ifs": {},
                                    "sysname": "", "location": "", "model": "", "version": "", "ping": ""}
                      for h in hosts}
                for it in items:
                    H = by.get(it["hostid"])
                    if not H:
                        continue
                    k, v = it["key_"], str(it.get("lastvalue", "")).strip()
                    if k == "system.name":
                        H["sysname"] = v
                    elif k == "system.location":
                        H["location"] = v
                    elif k == "system.descr.modelo":
                        H["model"] = v
                    elif k == "system.descr.versao":
                        H["version"] = v
                    elif k == "icmpping":
                        H["ping"] = v
                    mp = PORTA_RX.match(it["name"])
                    if mp:
                        H.setdefault("_porta", {}).setdefault(mp.group(1), {})[mp.group(2).lower()] = fmt_dbm(v)
                        continue
                    mp = PON_RX.match(it["name"])
                    if mp:
                        c = PON_CAMPO[mp.group(2)]
                        H.setdefault("_pon", {}).setdefault(mp.group(1), {})[c] = fmt_dbm(v) if c in ("rxm", "worst") else v
                        continue
                    m = IF_RX.match(it["name"])
                    if not m:
                        continue
                    full = m.group(1)
                    mm = re.match(r"^(\S+?)(?:\((.*)\))?$", full)
                    nome, alias = (mm.group(1), mm.group(2) or "") if mm else (full, "")
                    if IGNORAR_IF.search(nome):
                        continue
                    e = H["ifs"].setdefault(nome, {"i": nome, "a": ""})
                    if alias and not e["a"]:
                        e["a"] = alias
                    campo = CAMPO[m.group(2)]
                    if campo == "st":
                        e["st"] = OPER.get(v, "")
                    elif campo == "sp":
                        e["sp"] = fmt_speed(v)
                    elif campo in ("rx", "tx"):
                        e[campo] = fmt_dbm(v)
                    else:
                        try:
                            e[campo] = int(float(v))
                        except ValueError:
                            pass
                for H in by.values():   # OLT: junta sinal do módulo e ONUs na interface gpon_/xgei_/gei_ da mesma posição
                    porta, pon = H.pop("_porta", {}), H.pop("_pon", {})
                    for nome, e in H["ifs"].items():
                        pos = nome.split("_", 1)[1] if "_" in nome else None
                        if pos in porta:
                            for c in ("rx", "tx"):
                                if porta[pos].get(c) and not e.get(c):
                                    e[c] = porta[pos][c]
                        if pos in pon and nome.startswith("gpon"):
                            e.update({k: v for k, v in pon[pos].items() if v != ""})
                out = {"synced": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                       "hosts": {H["name"]: dict(H, ifs=list(H["ifs"].values())) for H in by.values()},
                       "nao_encontrados": [n for n in names if n not in {h["name"] for h in hosts}
                                           and n not in {h["host"] for h in hosts}]}
                # o mesmo host também fica acessível pelo nome técnico
                for H in by.values():
                    if H["host"] != H["name"]:
                        out["hosts"].setdefault(H["host"], out["hosts"][H["name"]])
                write_atomic(ZBX_FILE, out)
                self.err = None
                n_if = sum(len(H["ifs"]) for H in by.values())
                log(f"zabbix: ok: {len(by)} hosts, {n_if} interfaces"
                    + (f"; não encontrados: {', '.join(out['nao_encontrados'])}" if out["nao_encontrados"] else ""))
                return True
            except Exception as e:
                self.err = str(e)[:300]
                log(f"zabbix: Falha: {self.err}")
                return False

    def loop(self):
        while True:
            self.run()
            self.wake.wait(SYNC_MINUTES * 60)
            self.wake.clear()


# ------------------------------------------------------------------ login ---
COOKIE = "doc_noc"
SECRET_FILE = BASE / "secret.key"


def _secret():
    try:
        return SECRET_FILE.read_bytes()
    except FileNotFoundError:
        k = secrets.token_bytes(32)
        SECRET_FILE.write_bytes(k)
        os.chmod(SECRET_FILE, 0o600)
        return k


def _b64e(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _b64d(t):
    return base64.urlsafe_b64decode(t + "=" * (-len(t) % 4))


def _check_pbkdf2(pw, stored):
    try:
        algo, it, salt, dk = stored.split("$")
        if algo != "pbkdf2_sha256":
            return False
        calc = hashlib.pbkdf2_hmac("sha256", pw.encode(), _b64d(salt), int(it))
        return hmac.compare_digest(calc, _b64d(dk))
    except Exception:
        return False


_DUMMY = "pbkdf2_sha256$200000$" + _b64e(b"x" * 16) + "$" + _b64e(b"y" * 32)


class Users:
    """Usuários do painel-auth (users.json, recarrega quando muda) + contas do BASIC_AUTH."""

    def __init__(self):
        self.mtime, self.data = None, {}
        self.local = {}
        for part in BASIC_AUTH.split(","):
            if ":" in part:
                u, pw = part.split(":", 1)
                self.local[u.strip().lower()] = pw

    def get(self):
        if USERS_FILE is None:
            return {}
        try:
            m = USERS_FILE.stat().st_mtime_ns
            if m != self.mtime:
                self.data, self.mtime = json.loads(USERS_FILE.read_text(encoding="utf-8")), m
        except FileNotFoundError:
            self.data, self.mtime = {}, None
        except (OSError, ValueError) as e:
            log(f"login: não consegui ler {USERS_FILE}: {e}")
        return self.data

    def any(self):
        return bool(self.get() or self.local or (LOGIN_USUARIO and LOGIN_SENHA_HASH))

    def check(self, user, pw):
        user = (user or "").strip().lower()
        if LOGIN_USUARIO and LOGIN_SENHA_HASH and user == LOGIN_USUARIO:
            return _check_pbkdf2(pw or "", LOGIN_SENHA_HASH)
        if user in self.local:
            return hmac.compare_digest(self.local[user].encode(), (pw or "").encode())
        info = self.get().get(user)
        ok = _check_pbkdf2(pw or "", info["hash"] if info else _DUMMY)
        return ok and bool(info)

    def sv(self, user):
        if LOGIN_USUARIO and LOGIN_SENHA_HASH and user == LOGIN_USUARIO:
            # muda quando a senha muda: derruba as sessões abertas
            return int(hashlib.sha256(LOGIN_SENHA_HASH.encode()).hexdigest()[:7], 16)
        if user in self.local:
            return 0
        info = self.get().get(user)
        return None if info is None else int(info.get("sv", 0))


USERS = Users()


class Limiter:
    """5 senhas erradas em 15 min bloqueiam o IP e o usuário por 15 min."""

    def __init__(self):
        self.lock = threading.Lock()
        self.fails = {}

    def wait(self, *keys):
        now = time.time()
        with self.lock:
            w = 0
            for k in keys:
                lst = [t for t in self.fails.get(k, []) if now - t < 900]
                self.fails[k] = lst
                if len(lst) >= 5:
                    w = max(w, int(900 - (now - lst[0])))
            return w

    def fail(self, *keys):
        with self.lock:
            for k in keys:
                self.fails.setdefault(k, []).append(time.time())

    def clear(self, *keys):
        with self.lock:
            for k in keys:
                self.fails.pop(k, None)


LIMIT = Limiter()


def make_session(user, keep):
    exp = int(time.time()) + (SESSION_TV_DAYS * 86400 if keep else SESSION_HOURS * 3600)
    body = f"{user}|{exp}|{USERS.sv(user) or 0}|{1 if keep else 0}"
    sig = hmac.new(_secret(), body.encode(), hashlib.sha256).digest()
    return _b64e(body.encode()) + "." + _b64e(sig), exp, keep


def read_session(cookie_header):
    for part in (cookie_header or "").split(";"):
        name, _, value = part.strip().partition("=")
        if name != COOKIE or "." not in value:
            continue
        try:
            b, sig = value.split(".", 1)
            body = _b64d(b)
            if not hmac.compare_digest(hmac.new(_secret(), body, hashlib.sha256).digest(), _b64d(sig)):
                return None
            user, exp, sv, keep = body.decode().split("|")
            if int(exp) < time.time():
                return None
            cur = USERS.sv(user)
            if cur is None or cur != int(sv):   # usuário removido ou senha trocada
                return None
            return {"user": user, "exp": int(exp), "keep": keep == "1"}
        except Exception:
            return None
    return None


def exibir(user):
    return LOGIN_USUARIO_NOME if user and user == LOGIN_USUARIO else user


def safe_next(n):
    n = n or "/"
    return n if n.startswith("/") and not n.startswith("//") and not n.startswith("/login") else "/"


# ------------------------------------------------------------------- http ---
PUBLIC = {"/login", "/login.html", "/logo-updown.png", "/monograma.svg", "/healthz"}


class Handler(SimpleHTTPRequestHandler):
    # Sem timeout, quem anuncia Content-Length e não manda o corpo prende a thread
    # para sempre (slowloris). 30 s cobre qualquer cliente legítimo.
    timeout = 30

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(BASE / "static"), **kw)

    def log_message(self, fmt, *args):
        pass

    def end_headers(self):
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "same-origin")
        if self.path.split("?")[0] in ("/", "/index.html"):
            self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def from_proxy(self):
        # Cabeçalhos X-Real-IP/X-Forwarded-Proto só valem vindos do nginx desta máquina.
        return self.client_address[0] in ("127.0.0.1", "::1", "::ffff:127.0.0.1")

    def ip(self):
        if self.from_proxy():
            return self.headers.get("X-Real-IP") or self.client_address[0]
        return self.client_address[0]

    def secure(self):
        if COOKIE_SECURE in ("1", "true", "sim"):
            return True
        if COOKIE_SECURE in ("0", "false", "nao", "não"):
            return False
        return self.from_proxy() and self.headers.get("X-Forwarded-Proto", "") == "https"

    def send_json(self, code, obj, headers=()):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, to, headers=()):
        self.send_response(303)
        self.send_header("Location", to)
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()

    def sem_conta(self):
        """LOGIN=1 sem nenhuma conta (nem portal): configuração incompleta. Falha FECHADA."""
        return LOGIN and not self.login_on()

    def recusar_sem_conta(self):
        self.send_json(503, {"error": "Login ligado (LOGIN=1) mas nenhuma conta configurada. "
                                      "Configure a senha (python3 server.py senha), o PORTAL=1 ou, se o site "
                                      "deve mesmo ser aberto, LOGIN=0 no config.env."})

    def login_on(self):
        return PORTAL or (LOGIN and USERS.any())

    def session(self):
        if PORTAL:
            # Só confia no cabeçalho quando vem do nginx desta máquina.
            u = (self.headers.get("X-Portal-User") or "").strip()
            if u and self.client_address[0] in ("127.0.0.1", "::1", "::ffff:127.0.0.1"):
                role = (self.headers.get("X-Portal-Role") or "").strip().lower()
                return {"user": u, "portal": True, "role": role, "admin": role == "administrador"}
            return None
        return read_session(self.headers.get("Cookie")) if self.login_on() else {"user": None}

    _aviso_t = 0

    def aviso_sem_portal(self):
        now = time.time()
        if now - Handler._aviso_t > 600:
            Handler._aviso_t = now
            log("login: PORTAL=1, mas o pedido chegou sem X-Portal-User do nginx local — o site do nginx "
                "não está ligado ao portal. Rode: sudo bash vincular-portal.sh (no repositório nocup)")

    def can_edit(self, sess):
        if not sess:
            return False
        if sess.get("admin"):          # administrador no Portal NOC gerencia tudo
            return True
        return not EDITORES or (sess.get("user") or "").lower() in EDITORES

    def body_json(self, limit):
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            return None, "requisição grande demais"
        raw = self.rfile.read(n).decode("utf-8", "replace")
        try:
            return json.loads(raw or "{}"), None
        except ValueError:
            return None, "JSON inválido"

    # ---- GET ----
    def do_GET(self):
        url = urlparse(self.path)
        path = url.path
        if path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        if self.sem_conta():
            return self.recusar_sem_conta()
        if path == "/logout":
            return self.redirect("/login", [("Set-Cookie", f"{COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
                                             + ("; Secure" if self.secure() else ""))])
        sess = self.session()
        if PORTAL and not sess:
            # Modo portal sem usuário no cabeçalho: o nginx não está ligado ao portal (ex.: reinstalado
            # sem o vínculo). Nunca mostra o login próprio: manda para o portal e avisa no log.
            self.aviso_sem_portal()
            if path.startswith("/api/"):
                return self.send_json(401, {"error": "login", "portal": PORTAL_URL})
            volta = f"https://{self.headers.get('Host', 'documentacao.noc.updown.com.br')}/"
            return self.redirect(f"{PORTAL_URL}/login?sistema={PORTAL_SISTEMA}&volta={quote(volta, safe=':/')}")
        if PORTAL and path in ("/login", "/login.html"):
            return self.redirect("/")
        if path in ("/login", "/login.html"):
            if not self.login_on() or sess:
                return self.redirect(safe_next(parse_qs(url.query).get("next", ["/"])[0]))
            self.path = "/login.html"
            return super().do_GET()
        if path not in PUBLIC and not sess:
            if path.startswith("/api/"):
                return self.send_json(401, {"error": "login"})
            return self.redirect("/login?next=" + quote(self.path, safe="/?=&"))
        if path == "/api/dados":
            doc = STORE.read()
            return self.send_json(200, {"doc": doc, "rev": doc.get("rev", 1), "user": exibir(sess.get("user")),
                                        "admin": bool(sess.get("admin")), "role": sess.get("role", ""),
                                        "login": self.login_on(), "can_edit": self.can_edit(sess) or not self.login_on()})
        if path == "/api/zabbix":
            c = SYNC.cache()
            c["erro"] = SYNC.err
            c["intervalo_min"] = SYNC_MINUTES
            return self.send_json(200, c)
        if path == "/api/cofre":
            dono = sess.get("user")
            if not dono:
                return self.send_json(403, {"error": "O cofre é pessoal: precisa entrar com o seu usuário."})
            c = COFRE.read(dono)
            return self.send_json(200, {"rev": c.get("rev", 0), "blob": c.get("blob"), "updated": c.get("updated"),
                                        "dono": exibir(dono), "legado": COFRE.legado() is not None})
        if path == "/api/cofre/legado":
            if not sess.get("user"):
                return self.send_json(403, {"error": "O cofre é pessoal: precisa entrar com o seu usuário."})
            c = COFRE.legado()
            if not c:
                return self.send_json(404, {"error": "não há cofre compartilhado antigo"})
            return self.send_json(200, {"blob": c["blob"], "updated": c.get("updated")})
        if path == "/api/historico":
            return self.send_json(200, {"versoes": STORE.history()})
        if path.startswith("/api/historico/"):
            nome = path.rsplit("/", 1)[-1]
            f = HIST_DIR / nome
            if not re.fullmatch(r"[\w.-]+\.json", nome) or not f.exists():
                return self.send_json(404, {"error": "versão não encontrada"})
            return self.send_json(200, json.loads(f.read_text(encoding="utf-8")))
        if path.startswith("/api/"):
            return self.send_json(404, {"error": "não encontrado"})
        return super().do_GET()

    # ---- PUT /api/dados ----
    def do_PUT(self):
        if self.sem_conta():
            return self.recusar_sem_conta()
        path = urlparse(self.path).path
        if path not in ("/api/dados", "/api/cofre"):
            return self.send_json(404, {"error": "não encontrado"})
        sess = self.session()
        if not sess:
            return self.send_json(401, {"error": "login"})
        if path == "/api/cofre":   # cofre pessoal: qualquer usuário logado grava o SEU (EDITORES não se aplica)
            dono = sess.get("user")
            if not dono:
                return self.send_json(403, {"error": "O cofre é pessoal: precisa entrar com o seu usuário."})
            body, err = self.body_json(MAX_BODY)
            if err:
                return self.send_json(400, {"error": err})
            blob, rev = body.get("blob"), body.get("rev")
            err = valid_blob(blob)
            if err or rev is None:
                return self.send_json(400, {"error": err or "falta rev"})
            ok, cur = COFRE.save(dono, blob, rev)
            if not ok:
                return self.send_json(409, {"error": "conflito", "rev": cur})
            log(f"cofre: '{exibir(dono)}' salvou o próprio cofre (rev {cur}) de {self.ip()}")
            return self.send_json(200, {"ok": True, "rev": cur})
        if self.login_on() and not self.can_edit(sess):
            return self.send_json(403, {"error": "Seu usuário pode só consultar a documentação."})
        body, err = self.body_json(MAX_BODY)
        if err:
            return self.send_json(400, {"error": err})
        doc, rev = body.get("doc"), body.get("rev")
        err = valid_doc(doc)
        if err or rev is None:
            return self.send_json(400, {"error": err or "falta rev"})
        ok, cur, by, when = STORE.save(doc, rev, exibir(sess.get("user")))
        if not ok:
            return self.send_json(409, {"error": "conflito", "rev": cur, "updated_by": by, "updated": when})
        log(f"dados: rev {cur} salva por '{by}' de {self.ip()}")
        threading.Thread(target=SYNC.run, daemon=True).start()   # novo host ligado? atualiza o cache
        return self.send_json(200, {"ok": True, "rev": cur, "updated_by": by, "updated": when})

    # ---- DELETE /api/cofre/legado ----
    def do_DELETE(self):
        if self.sem_conta():
            return self.recusar_sem_conta()
        if urlparse(self.path).path != "/api/cofre/legado":
            return self.send_json(404, {"error": "não encontrado"})
        sess = self.session()
        if not sess or not sess.get("user"):
            return self.send_json(401, {"error": "login"})
        ok = COFRE.retirar_legado(sess["user"])
        if ok:
            log(f"cofre: cofre compartilhado antigo retirado por '{exibir(sess['user'])}' (cópia cifrada em historico-cofre/)")
        return self.send_json(200, {"ok": ok})

    # ---- POST /login, /api/zabbix/sync ----
    def do_POST(self):
        if self.sem_conta():
            return self.recusar_sem_conta()
        path = urlparse(self.path).path
        if path == "/api/zabbix/sync":
            if not self.session():
                return self.send_json(401, {"error": "login"})
            ok = SYNC.run()
            return self.send_json(200 if ok else 502, {"ok": ok, "erro": SYNC.err, "synced": SYNC.cache().get("synced")})
        if path != "/login":
            return self.send_json(404, {"error": "não encontrado"})
        n = int(self.headers.get("Content-Length") or 0)
        if n > 4096:
            return self.send_json(413, {"error": "requisição grande demais"})
        raw = self.rfile.read(n).decode("utf-8", "replace")
        if "json" in (self.headers.get("Content-Type") or ""):
            try:
                f = json.loads(raw or "{}")
            except ValueError:
                f = {}
        else:
            f = {k: v[0] for k, v in parse_qs(raw).items()}
        user = str(f.get("usuario", "")).strip().lower()
        pw = str(f.get("senha", ""))
        keep = str(f.get("manter", "")).lower() in ("1", "true", "on", "sim")
        nxt = safe_next(str(f.get("next", "/")))
        keys = ("ip:" + self.ip(), "u:" + user)
        wait = LIMIT.wait(*keys)
        if wait:
            return self.send_json(429, {"error": f"Muitas tentativas. Tente de novo em {max(1, wait // 60)} min.",
                                        "wait": wait})
        if not user or not pw:
            return self.send_json(400, {"error": "Informe usuário e senha.", "field": "usuario" if not user else "senha"})
        if not USERS.check(user, pw):
            LIMIT.fail(*keys)
            left = 5 - max(len(LIMIT.fails.get(k, [])) for k in keys)
            if left <= 0:
                return self.send_json(429, {"error": "Senha incorreta 5 vezes. Acesso bloqueado por 15 min.",
                                            "wait": 900})
            msg = "Usuário ou senha incorretos."
            if 0 < left <= 2:
                msg += f" Mais {left} tentativa{'s' if left > 1 else ''} antes de bloquear por 15 min."
            log(f"login: falhou para '{user}' de {self.ip()}")
            return self.send_json(401, {"error": msg, "field": "senha"})
        LIMIT.clear(*keys)
        token, exp, keep = make_session(user, keep)
        cookie = f"{COOKIE}={token}; Path=/; HttpOnly; SameSite=Lax" + ("; Secure" if self.secure() else "")
        if keep:
            cookie += f"; Max-Age={exp - int(time.time())}"
        log(f"login: '{user}' entrou de {self.ip()}{' (manter conectado)' if keep else ''}")
        return self.send_json(200, {"ok": True, "user": user, "next": nxt}, [("Set-Cookie", cookie)])


def gerar_hash():
    import getpass
    s1 = getpass.getpass("Nova senha do site: ")
    s2 = getpass.getpass("Repita a senha: ")
    if not s1 or s1 != s2:
        print("As senhas não conferem.", file=sys.stderr)
        sys.exit(1)
    salt = secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", s1.encode(), salt, 200000)
    print("LOGIN_SENHA_HASH=pbkdf2_sha256$200000$" + _b64e(salt) + "$" + _b64e(dk))


def main():
    global STORE, SYNC, COFRE
    if len(sys.argv) > 1 and sys.argv[1] == "senha":
        return gerar_hash()
    STORE = Store()
    SYNC = ZabbixSync(STORE)
    COFRE = Cofre()
    if not ZBX_TOKEN:
        log("zabbix: ZABBIX_TOKEN vazio no config.env — o site abre, mas sem o status do Zabbix")
    if PORTAL:
        log("login: pelo Portal NOC (usuário vem do nginx no cabeçalho X-Portal-User); cofre pessoal por usuário do portal")
    elif LOGIN and not USERS.any():
        log("login: nenhuma conta configurada (LOGIN_SENHA_HASH vazio) — site FECHADO (503) até configurar a senha, PORTAL=1 ou LOGIN=0")
    elif LOGIN:
        log(f"login: conta '{LOGIN_USUARIO}'" + (f" + usuários de {USERS_FILE}" if USERS_FILE else "")
            + (" + BASIC_AUTH" if USERS.local else ""))
    threading.Thread(target=SYNC.loop, daemon=True).start()
    srv = ThreadingHTTPServer((LISTEN, PORT), Handler)
    log(f"Documentação NOC em http://{LISTEN}:{PORT}  (dados em {DATA_DIR}, Zabbix {ZBX_URL})")
    srv.serve_forever()


if __name__ == "__main__":
    main()
