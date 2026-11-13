#!/usr/bin/env python3
"""
UpDown NOC — Painel de alertas GPON (PON down / CTO down) para TV.

Lê o Zabbix próprio (API JSON-RPC com token) a cada POLL_SECONDS e expõe:
  GET /              -> tela da TV (static/index.html)
  GET /api/state     -> estado consolidado (JSON)
  GET /healthz       -> "ok"

Fontes no Zabbix:
  * Host "IXC - CTO" (template "UpDown - IXC - Sessões por CTO"):
      sessoesCTO[NNN], clientesCTO[NNN], causaCTO[NNN]  (tag cto: NNN)
      ixc.cto.quedas, ixc.cto.quedas.lista e o item mestre JSON
      problemas ativos com tag "cto" (queda parcial / queda total)
  * Grupo "GPON/ONUs": onu.olt, onu.porta, onu.estado (Template PPPoE ONU)
  * Grupo "OLTs UpDown": itens de status operacional das portas gpon-olt (se existirem)

Só usa a biblioteca padrão do Python 3.8+.
"""
import json
import os
import re
import ssl
import sys
import threading
import time
import traceback
import urllib.request
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

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
CTO_HOST = env("CTO_HOST", "IXC - CTO")
ONU_GROUP = env("ONU_GROUP", "GPON/ONUs")
OLT_GROUP = env("OLT_GROUP", "OLTs UpDown")
POLL_SECONDS = env("POLL_SECONDS", "30", int)
LISTEN = env("LISTEN", "0.0.0.0")
PORT = env("PORT", "8445", int)
# PON é considerada DOWN quando todas as ONUs monitoradas nela estão fora
# e há pelo menos PON_MIN_ONUS ONUs monitoradas.
PON_MIN_ONUS = env("PON_MIN_ONUS", "2", int)
# PON também é DOWN quando TODAS as CTOs conhecidas dela estão down
# (com pelo menos PON_MIN_CTOS CTOs mapeadas).
PON_MIN_CTOS = env("PON_MIN_CTOS", "2", int)
SHOW_PARTIAL = env("SHOW_PARTIAL", "1") == "1"
# Quantos segundos uma alerta resolvida fica na faixa "Normalizadas".
RECOVERED_KEEP = env("RECOVERED_KEEP", "180", int)
# Quantas coletas seguidas a CTO precisa estar com 0 sessões para virar alerta.
CONFIRM_POLLS = env("CONFIRM_POLLS", "1", int)
MASSIVE_MIN = env("MASSIVE_MIN", "5", int)
# Login: por padrão usa os mesmos usuários do Painel das OLTs (painel-auth).
# LOGIN=0 desliga. BASIC_AUTH=usuario:senha[,usuario2:senha2] adiciona contas locais.
LOGIN = env("LOGIN", "1") == "1"
USERS_FILE = Path(env("USERS_FILE", "/etc/painel-olt/users.json"))
BASIC_AUTH = env("BASIC_AUTH", "")
SESSION_HOURS = env("SESSION_HOURS", "12", int)          # sem "manter conectado"
SESSION_TV_DAYS = env("SESSION_TV_DAYS", "90", int)      # com "manter conectado nesta TV"
OLT_NAMES = {
    "casqueiro": "C300 Casqueiro",
    "vilanatal": "C350 Vila Natal",
}
for part in env("OLT_NAMES", "").split(","):
    if "=" in part:
        k, v = part.split("=", 1)
        OLT_NAMES[k.strip().lower()] = v.strip()

STATE_FILE = BASE / "state.json"
CTO_MAP_FILE = BASE / "cto_map.json"   # opcional: {"012": {"olt": "vilanatal", "pon": "1/10/13"}}

PON_RE = re.compile(r"(\d+/\d+/\d+)")
CTO_KEY_RE = re.compile(r"^(sessoes|clientes|causa)CTO\[(.+)\]$")


# ------------------------------------------------------------- zabbix api ---
class Zabbix:
    def __init__(self, url, token, verify=True):
        self.url = url + "/api_jsonrpc.php"
        self.token = token
        self.ctx = None if verify else ssl._create_unverified_context()
        self.legacy_auth = False
        self._id = 0

    def call(self, method, params):
        self._id += 1
        body = {"jsonrpc": "2.0", "method": method, "params": params, "id": self._id}
        headers = {"Content-Type": "application/json-rpc"}
        if self.legacy_auth:
            body["auth"] = self.token
        else:
            headers["Authorization"] = "Bearer " + self.token
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), headers=headers)
        with urllib.request.urlopen(req, timeout=60, context=self.ctx) as r:
            resp = json.loads(r.read().decode("utf-8"))
        if "error" in resp:
            err = resp["error"]
            msg = f"{err.get('message')} {err.get('data')}"
            # Zabbix < 6.4 não aceita header Bearer: tenta com "auth" no corpo
            if not self.legacy_auth and "authoriz" in msg.lower():
                self.legacy_auth = True
                return self.call(method, params)
            raise RuntimeError(f"Zabbix {method}: {msg}")
        return resp["result"]


# --------------------------------------------------------------- helpers ---
def olt_key(text):
    """'OLT C350 VILA NATAL' / 'vilanatal' -> 'vilanatal'."""
    t = re.sub(r"[^a-z0-9]", "", (text or "").lower())
    for k in OLT_NAMES:
        if k in t:
            return k
    return t or "?"


def olt_name(key):
    return OLT_NAMES.get(key, key.upper())


def pon_of(porta):
    """'gpon-onu_1/10/13:2' -> '1/10/13'."""
    m = PON_RE.search(porta or "")
    return m.group(1) if m else None


def to_int(v, default=None):
    try:
        return int(float(v))
    except Exception:
        return default


def onu_online(estado):
    e = (estado or "").strip().lower()
    if not e:
        return None
    return e.startswith("funcion") or e in ("online", "working", "ok", "1", "up")


def find_cto_pon_pairs(obj, out):
    """Procura recursivamente no JSON mestre do IXC por pares CTO -> OLT/PON."""
    if isinstance(obj, dict):
        lower = {str(k).lower(): v for k, v in obj.items()}
        cto = None
        for k in ("cto", "id_cto", "cto_id", "caixa", "nome_cto", "nome"):
            if k in lower and isinstance(lower[k], (str, int)):
                cto = str(lower[k]).strip()
                break
        pon = None
        for k in ("pon", "porta_pon", "porta", "interface", "gpon", "pon_porta"):
            if k in lower and isinstance(lower[k], (str, int)):
                pon = pon_of(str(lower[k]))
                if pon:
                    break
        if cto and pon:
            olt = None
            for k in ("olt", "olt_nome", "nome_olt", "transmissor"):
                if k in lower and isinstance(lower[k], str):
                    olt = olt_key(lower[k])
                    break
            out[cto] = {"pon": pon, "olt": olt}
        for v in obj.values():
            find_cto_pon_pairs(v, out)
    elif isinstance(obj, list):
        for v in obj:
            find_cto_pon_pairs(v, out)
    # Chaves no formato {"012": {...}}
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, dict) and str(k) not in out:
                lower = {str(a).lower(): b for a, b in v.items()}
                for pk in ("pon", "porta_pon", "porta", "interface"):
                    p = pon_of(str(lower.get(pk, "")))
                    if p:
                        out[str(k)] = {"pon": p, "olt": olt_key(str(lower.get("olt", ""))) if lower.get("olt") else None}
                        break


def norm_cto(c, known):
    """Casa '12', 'CTO 012', '012' com a chave usada no Zabbix."""
    c = str(c).strip()
    if c in known:
        return c
    m = re.search(r"(\d+)", c)
    if m:
        n = m.group(1)
        for cand in (n, n.zfill(3), n.lstrip("0") or "0"):
            if cand in known:
                return cand
    return c


# ----------------------------------------------------------------- engine ---
class Engine:
    def __init__(self):
        self.zbx = Zabbix(ZBX_URL, ZBX_TOKEN, ZBX_VERIFY_TLS)
        self.lock = threading.Lock()
        self.state = {"updated": None, "ok": False, "error": "Aguardando primeira coleta…",
                      "summary": {}, "alerts": [], "recovered": [], "olts": []}
        self.persist = {"first_seen": {}, "down_streak": {}, "recovered": []}
        self.ids = {}
        try:
            self.persist.update(json.loads(STATE_FILE.read_text()))
        except Exception:
            pass

    # ---- ids (cacheados) ----
    def resolve_ids(self):
        if self.ids:
            return self.ids
        h = self.zbx.call("host.get", {"output": ["hostid", "name"], "filter": {"host": [CTO_HOST]}})
        if not h:
            h = self.zbx.call("host.get", {"output": ["hostid", "name"], "filter": {"name": [CTO_HOST]}})
        groups = self.zbx.call("hostgroup.get", {"output": ["groupid", "name"],
                                                 "filter": {"name": [ONU_GROUP, OLT_GROUP]}})
        g = {x["name"]: x["groupid"] for x in groups}
        self.ids = {
            "cto_host": h[0]["hostid"] if h else None,
            "onu_group": g.get(ONU_GROUP),
            "olt_group": g.get(OLT_GROUP),
        }
        log("ids:", self.ids)
        return self.ids

    # ---- coleta ----
    def collect(self):
        ids = self.resolve_ids()
        z = self.zbx
        now = int(time.time())

        # 1) CTOs ------------------------------------------------------------
        ctos = {}
        global_items = {}
        cto_map = {}
        problems = []
        if ids["cto_host"]:
            items = z.call("item.get", {
                "hostids": ids["cto_host"],
                "output": ["key_", "lastvalue", "lastclock", "value_type"],
                "search": {"key_": "CTO["}, "monitored": True,
            })
            for it in items:
                m = CTO_KEY_RE.match(it["key_"])
                if not m:
                    continue
                kind, cto = m.group(1), m.group(2)
                c = ctos.setdefault(cto, {"cto": cto})
                c[kind] = it["lastvalue"]
                c["clock"] = max(c.get("clock", 0), to_int(it["lastclock"], 0))

            gitems = z.call("item.get", {
                "hostids": ids["cto_host"], "output": ["key_", "name", "lastvalue", "lastclock", "value_type"],
                "search": {"key_": "ixc."}, "monitored": True,
            })
            for it in gitems:
                global_items[it["key_"]] = it["lastvalue"]
                if it["value_type"] == "4" and it["lastvalue"][:1] in "[{":
                    try:
                        find_cto_pon_pairs(json.loads(it["lastvalue"]), cto_map)
                    except Exception:
                        pass
            lista = global_items.get("ixc.cto.quedas.lista", "") or ""
            for m in re.finditer(r"CTO\s*([\w\-]+)[^\n]*?(\d+/\d+/\d+)", lista, re.I):
                cto_map.setdefault(m.group(1), {"pon": m.group(2), "olt": None})
                # tenta pegar a OLT na mesma linha
                line = lista[m.start():lista.find("\n", m.start()) if "\n" in lista[m.start():] else None]
                k = olt_key(line)
                if k in OLT_NAMES:
                    cto_map[m.group(1)]["olt"] = k

            problems = z.call("problem.get", {
                "hostids": ids["cto_host"], "output": ["eventid", "name", "clock", "severity"],
                "selectTags": "extend", "recent": False, "sortfield": ["eventid"], "sortorder": "DESC",
            })

        # mapa manual tem prioridade
        if CTO_MAP_FILE.exists():
            try:
                for k, v in json.loads(CTO_MAP_FILE.read_text()).items():
                    cto_map[k] = {"pon": pon_of(v.get("pon", "")), "olt": olt_key(v.get("olt", "")) if v.get("olt") else None}
            except Exception as e:
                log("cto_map.json inválido:", e)
        cto_map = {norm_cto(k, ctos): v for k, v in cto_map.items()}

        prob_by_cto = {}
        for p in problems:
            tags = {t["tag"]: t["value"] for t in p.get("tags", [])}
            if "cto" in tags:
                prob_by_cto.setdefault(norm_cto(tags["cto"], ctos), []).append(p)

        # 2) ONUs -> PONs ----------------------------------------------------
        pons = {}   # (olt, pon) -> {"onus": n, "online": n}
        if ids["onu_group"]:
            items = z.call("item.get", {
                "groupids": ids["onu_group"], "output": ["hostid", "key_", "lastvalue"],
                "filter": {"key_": ["onu.olt", "onu.porta", "onu.estado", "pppoe.status"]},
                "monitored": True,
            })
            per_host = {}
            for it in items:
                per_host.setdefault(it["hostid"], {})[it["key_"]] = it["lastvalue"]
            for hv in per_host.values():
                pon = pon_of(hv.get("onu.porta"))
                if not pon:
                    continue
                key = (olt_key(hv.get("onu.olt")), pon)
                st = onu_online(hv.get("onu.estado"))
                if st is None:
                    ps = hv.get("pppoe.status")
                    st = None if ps in (None, "") else ps == "1"
                if st is None:
                    continue
                p = pons.setdefault(key, {"onus": 0, "online": 0, "oper": None})
                p["onus"] += 1
                p["online"] += 1 if st else 0

        # 3) Status operacional das PONs nas OLTs (se o template coletar) ---
        if ids["olt_group"]:
            items = {}
            for pattern in ({"key_": "net.if.status"}, {"key_": "OperStatus"}, {"name": "Operational status"}):
                for it in z.call("item.get", {
                    "groupids": ids["olt_group"], "output": ["itemid", "key_", "name", "lastvalue"],
                    "selectHosts": ["name"], "monitored": True, "search": pattern,
                }):
                    items[it["itemid"]] = it
            for it in items.values():
                txt = it["name"] + " " + it["key_"]
                if not re.search(r"gpon|pon", txt, re.I) or not re.search(r"oper", txt, re.I):
                    continue
                pon = pon_of(txt)
                if not pon:
                    continue
                key = (olt_key(it["hosts"][0]["name"]), pon)
                v = to_int(it["lastvalue"])
                p = pons.setdefault(key, {"onus": 0, "online": 0, "oper": None})
                p["oper"] = v   # 1 up, 2 down, 7 lowerLayerDown

        # 4) Monta alertas --------------------------------------------------
        fs = self.persist["first_seen"]
        streak = self.persist["down_streak"]
        alerts = {}
        cto_down = {}
        clientes_afetados = 0

        def since_for(aid, plist):
            if plist:
                t = min(to_int(p["clock"], now) for p in plist)
                fs[aid] = min(fs.get(aid, t), t)
            return fs.setdefault(aid, now)

        for cto, c in ctos.items():
            cli = to_int(c.get("clientes"), 0) or 0
            ses = to_int(c.get("sessoes"))
            if ses is None:
                continue
            plist = prob_by_cto.get(cto, [])
            down = cli > 0 and ses == 0
            streak[cto] = (streak.get(cto, 0) + 1) if down else 0
            loc = cto_map.get(cto, {})
            if down and streak[cto] >= CONFIRM_POLLS:
                aid = f"cto:{cto}"
                alerts[aid] = {
                    "id": aid, "kind": "cto", "cto": cto, "title": f"CTO {cto}",
                    "olt": loc.get("olt"), "olt_name": olt_name(loc["olt"]) if loc.get("olt") else None,
                    "pon": loc.get("pon"), "clientes": cli, "sessoes": 0,
                    "causa": (c.get("causa") or "").strip(), "since": since_for(aid, plist),
                }
                cto_down[cto] = alerts[aid]
                clientes_afetados += cli
            elif SHOW_PARTIAL and plist and not down:
                aid = f"parcial:{cto}"
                alerts[aid] = {
                    "id": aid, "kind": "parcial", "cto": cto, "title": f"CTO {cto}",
                    "olt": loc.get("olt"), "olt_name": olt_name(loc["olt"]) if loc.get("olt") else None,
                    "pon": loc.get("pon"), "clientes": cli, "sessoes": ses,
                    "causa": (c.get("causa") or "").strip(), "since": since_for(aid, plist),
                    "problema": plist[0]["name"],
                }

        # CTO mapeada sem OLT: se só uma OLT tem essa PON, assume ela
        olts_by_pon = {}
        for (o, p) in pons:
            olts_by_pon.setdefault(p, set()).add(o)
        for loc in cto_map.values():
            if loc.get("pon") and not loc.get("olt") and len(olts_by_pon.get(loc["pon"], ())) == 1:
                loc["olt"] = next(iter(olts_by_pon[loc["pon"]]))
        for a in alerts.values():
            loc = cto_map.get(a.get("cto"), {})
            if loc.get("olt") and not a.get("olt"):
                a["olt"], a["olt_name"] = loc["olt"], olt_name(loc["olt"])

        # CTOs por PON (pelo mapa)
        ctos_by_pon = {}
        for cto, loc in cto_map.items():
            if loc.get("pon") and cto in ctos:
                ctos_by_pon.setdefault((loc.get("olt"), loc["pon"]), []).append(cto)
        # garante que PONs com CTO mapeada apareçam no grid
        for (o, p) in ctos_by_pon:
            if o:
                pons.setdefault((o, p), {"onus": 0, "online": 0, "oper": None})

        pon_alerts = {}
        for (o, p), info in pons.items():
            reasons = []
            if info["oper"] in (2, 7):
                reasons.append("Porta PON operacionalmente DOWN na OLT")
            if info["onus"] >= PON_MIN_ONUS and info["online"] == 0:
                reasons.append(f"Todas as {info['onus']} ONUs monitoradas fora")
            pcs = sorted(set(ctos_by_pon.get((o, p), [])))
            if len(pcs) >= PON_MIN_CTOS and all(x in cto_down for x in pcs):
                reasons.append(f"Todas as {len(pcs)} CTOs da PON sem clientes online")
            info["ctos"] = pcs
            if reasons:
                aid = f"pon:{o}:{p}"
                affected = [x for x in pcs if x in cto_down]
                pon_alerts[aid] = {
                    "id": aid, "kind": "pon", "title": f"PON {p}", "olt": o, "olt_name": olt_name(o),
                    "pon": p, "ctos": affected,
                    "clientes": sum(cto_down[x]["clientes"] for x in affected),
                    "onus": info["onus"], "onus_online": info["online"],
                    "causa": " · ".join(reasons), "since": since_for(aid, []),
                }
                # As CTOs da PON down ficam agrupadas no card da PON
                for x in affected:
                    alerts.pop(f"cto:{x}", None)
                    since = cto_down[x]["since"]
                    pon_alerts[aid]["since"] = min(pon_alerts[aid]["since"], since)
        alerts.update(pon_alerts)

        # 5) Normalizadas (saíram do painel) --------------------------------
        prev = {a["id"]: a for a in self.state.get("alerts", [])}
        rec = [r for r in self.persist.get("recovered", []) if now - r["until"] < RECOVERED_KEEP]
        for aid, a in prev.items():
            if aid not in alerts:
                rec.insert(0, {**a, "until": now})
                fs.pop(aid, None)
        for aid in list(fs):
            if aid not in alerts:
                fs.pop(aid, None)
        self.persist["recovered"] = rec[:12]

        # 6) Grid de PONs por OLT --------------------------------------------
        olts = {}
        partial_pons = {(a["olt"], a["pon"]) for a in alerts.values() if a["kind"] == "parcial" and a.get("pon")}
        cto_down_pons = {(a["olt"], a["pon"]) for a in alerts.values() if a["kind"] == "cto" and a.get("pon")}
        down_pons = {(a["olt"], a["pon"]) for a in pon_alerts.values()}
        for (o, p), info in pons.items():
            st = "ok"
            if (o, p) in down_pons:
                st = "down"
            elif (o, p) in cto_down_pons:
                st = "cto"
            elif (o, p) in partial_pons:
                st = "parcial"
            elif info["onus"] and info["online"] < info["onus"]:
                st = "ok"  # ONUs isoladas fora não pintam a PON
            olts.setdefault(o, []).append({
                "pon": p, "status": st, "onus": info["onus"], "online": info["online"],
                "ctos": len(info.get("ctos", [])),
            })

        def pon_sort(x):
            return [int(n) for n in x["pon"].split("/")]

        olt_list = [{"key": k, "name": olt_name(k), "pons": sorted(v, key=pon_sort)}
                    for k, v in sorted(olts.items()) if k and k != "?"]

        order = {"pon": 0, "cto": 1, "parcial": 2}
        alert_list = sorted(alerts.values(), key=lambda a: (order[a["kind"]], a["since"]))
        quedas = to_int(global_items.get("ixc.cto.quedas"), None)
        ncto_down = sum(1 for a in alerts.values() if a["kind"] == "cto") + \
            sum(len(a["ctos"]) for a in pon_alerts.values())

        state = {
            "updated": now, "ok": True, "error": None,
            "summary": {
                "ctos_total": len(ctos),
                "ctos_down": ncto_down,
                "ctos_parcial": sum(1 for a in alerts.values() if a["kind"] == "parcial"),
                "clientes_afetados": clientes_afetados,
                "pons_total": len(pons),
                "pons_down": len(pon_alerts),
                "onus_monitoradas": sum(p["onus"] for p in pons.values()),
                "massiva": max(ncto_down, quedas or 0) >= MASSIVE_MIN,
                "quedas_ixc": quedas,
                "cto_map": len(cto_map),
            },
            "alerts": alert_list,
            "recovered": self.persist["recovered"],
            "olts": olt_list,
            "poll_seconds": POLL_SECONDS,
        }
        with self.lock:
            self.state = state
        try:
            STATE_FILE.write_text(json.dumps(self.persist))
        except Exception:
            pass

    def loop(self):
        while True:
            t0 = time.time()
            try:
                self.collect()
                s = self.state["summary"]
                log(f"ok: {s['ctos_down']} CTO down, {s['pons_down']} PON down, "
                    f"{s['ctos_parcial']} parcial ({time.time() - t0:.1f}s)")
            except Exception as e:
                traceback.print_exc()
                self.ids = {} if "hostid" in str(e) else self.ids
                with self.lock:
                    self.state = {**self.state, "ok": False,
                                  "error": f"Falha ao consultar o Zabbix: {e}"}
            time.sleep(max(5, POLL_SECONDS - (time.time() - t0)))


ENGINE = None


# ------------------------------------------------------------------ login ---
import base64
import hashlib
import hmac
import secrets
from urllib.parse import parse_qs, urlparse, quote

COOKIE = "painel_pon"
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
        return bool(self.get() or self.local)

    def check(self, user, pw):
        user = (user or "").strip().lower()
        if user in self.local:
            return hmac.compare_digest(self.local[user].encode(), (pw or "").encode())
        info = self.get().get(user)
        ok = _check_pbkdf2(pw or "", info["hash"] if info else _DUMMY)
        return ok and bool(info)

    def sv(self, user):
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


def safe_next(n):
    n = n or "/"
    return n if n.startswith("/") and not n.startswith("//") and not n.startswith("/login") else "/"


# ------------------------------------------------------------------- http ---
PUBLIC = {"/login", "/login.html", "/logo-updown.png", "/monograma.svg", "/healthz"}


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(BASE / "static"), **kw)

    def log_message(self, fmt, *args):
        pass

    def end_headers(self):
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "same-origin")
        super().end_headers()

    # ---- util ----
    def ip(self):
        return self.headers.get("X-Real-IP") or self.client_address[0]

    def secure(self):
        return self.headers.get("X-Forwarded-Proto", "") == "https"

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

    def login_on(self):
        return LOGIN and USERS.any()

    def session(self):
        return read_session(self.headers.get("Cookie")) if self.login_on() else {"user": None}

    # ---- GET ----
    def do_GET(self):
        url = urlparse(self.path)
        path = url.path
        if path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        if path == "/logout":
            return self.redirect("/login", [("Set-Cookie", f"{COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
                                             + ("; Secure" if self.secure() else ""))])
        sess = self.session()
        if path in ("/login", "/login.html"):
            if not self.login_on() or sess:
                return self.redirect(safe_next(parse_qs(url.query).get("next", ["/"])[0]))
            self.path = "/login.html"
            return super().do_GET()
        if path not in PUBLIC and not sess:
            if path.startswith("/api/"):
                return self.send_json(401, {"error": "login"})
            return self.redirect("/login?next=" + quote(self.path, safe="/?=&"))
        if path == "/api/state":
            with ENGINE.lock:
                st = dict(ENGINE.state)
            st["user"] = sess.get("user")
            st["login"] = self.login_on()
            return self.send_json(200, st)
        if path == "/api/me":
            return self.send_json(200, {"user": sess.get("user"), "login": self.login_on()})
        return super().do_GET()

    # ---- POST /login ----
    def do_POST(self):
        if urlparse(self.path).path != "/login":
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


def main():
    global ENGINE
    if not ZBX_TOKEN:
        print("Defina ZABBIX_TOKEN no config.env", file=sys.stderr)
        sys.exit(1)
    ENGINE = Engine()
    if LOGIN and not USERS.any():
        log(f"login: nenhum usuário em {USERS_FILE} nem em BASIC_AUTH — tela ABERTA sem login")
    elif LOGIN:
        log(f"login: usando usuários de {USERS_FILE}" + (" + BASIC_AUTH" if USERS.local else ""))
    threading.Thread(target=ENGINE.loop, daemon=True).start()
    srv = ThreadingHTTPServer((LISTEN, PORT), Handler)
    log(f"Painel PON/CTO em http://{LISTEN}:{PORT}  (Zabbix {ZBX_URL})")
    srv.serve_forever()


if __name__ == "__main__":
    main()
