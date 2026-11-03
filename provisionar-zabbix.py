#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Monitoramento das OLTs no Zabbix da UpDown (UPT-UBUNTU02, porta 19090) — versão 2

  python3 provisionar-zabbix.py

O que faz, em ordem:
  1. entra na API do Zabbix local com o usuário administrador (você digita a senha)
  2. pede a comunidade SNMP de cada OLT (C350 e C300 são diferentes) e testa
  3. sonda memória, sinal RX das ONUs e a tabela óptica (TX) de cada OLT
  4. cria/atualiza o template "UpDown ZTE OLT SNMP":
       - tráfego, estado, velocidade, erros e descartes de cada porta
       - CPU, memória e temperatura de cada placa
       - sinal RX das ONUs resumido por PON (pior, média, quantidade, abaixo do limite, lista)
       - TX de cada porta PON e RX/TX dos módulos de uplink
  5. cria/atualiza os hosts OLT C350 VILA NATAL e OLT C300 CASQUEIRO
  6. usuário somente leitura "painel-olt" com token (reaproveita o atual se ainda vale)
  7. espera os primeiros dados e deixa o painel (nginx /zbx-api) apontado para este Zabbix

Pode rodar de novo: o que já existe é reaproveitado ou atualizado, nada é duplicado.
Nenhuma senha fica gravada; as comunidades SNMP vão como macro secreta em cada host.
"""
import getpass
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

LOCAL_URL = os.environ.get("ZBX_URL", "http://127.0.0.1:19090/api_jsonrpc.php")
LV_URL = os.environ.get("LV_URL", "https://zbx7.lv.network/api_jsonrpc.php")
NGINX_SITE = os.environ.get("NGINX_SITE", "/etc/nginx/sites-available/painel-olt")
STATE_DIR = os.environ.get("STATE_DIR", "/etc/painel-olt")
PROBE_FILE = os.environ.get("PROBE_FILE", "/root/olt-sondagem-snmp.txt")

OLTS = [
    {"nome": "OLT C350 VILA NATAL", "curto": "C350", "ip": "172.16.255.1", "lv_hostid": "29174"},
    {"nome": "OLT C300 CASQUEIRO", "curto": "C300", "ip": "172.16.255.3", "lv_hostid": "29173"},
]
HOST_GROUP = "OLTs UpDown"
TEMPLATE = "UpDown ZTE OLT SNMP"
TEMPLATE_GROUP = "Templates/UpDown"
PANEL_USER = "painel-olt"
PANEL_GROUP = "Painel OLT - leitura"
TOKEN_NAME = "Painel das OLTs"

SYSNAME = "1.3.6.1.2.1.1.5.0"
IFNAME = "1.3.6.1.2.1.31.1.1.1.1"
# Tabela de placas da ZTE (ZXAN): índice rack.shelf.slot, ex. 1.1.13
CPU_BASE = "1.3.6.1.4.1.3902.1015.2.1.1.3.1.9"
MEM_BASE = "1.3.6.1.4.1.3902.1015.2.1.1.3.1.11"
TEMP_BASE_DEFAULT = "1.3.6.1.4.1.3902.1015.2.1.3.13.5.1.1"
# Sinal das ONUs: (OID, formato). "milli" = milésimos de dBm; "zte002" = valor*0,002-30
# 1012…10 = RX recebido pela ONU (o mesmo do "show pon power attenuation", linha down/ONU Rx)
# 1015…2   = RX das ONUs medido na OLT (linha up/OLT Rx), só se a primeira não responder
ONU_RX_CANDIDATES = [
    ("1.3.6.1.4.1.3902.1012.3.50.12.1.1.10", "zte002"),
    ("1.3.6.1.4.1.3902.1015.1010.11.2.1.2", "milli"),
]
OPT_TABLE = "1.3.6.1.4.1.3902.1015.3.1.13.1"      # módulos ópticos das portas (colunas: RX, TX, …)
INVALIDO = 2147483647

IF_FILTER = r"^(gpon|xgs|xg-pon|epon|xgei|gei|smartgroup)"
PREP_CHANGE = {"type": 10, "params": "", "error_handler": 0, "error_handler_params": ""}


def prep_mult(n):
    return {"type": 1, "params": str(n), "error_handler": 0, "error_handler_params": ""}


def prep_js(code):
    return {"type": 21, "params": code, "error_handler": 0, "error_handler_params": ""}


def prep_jsonpath(path, discard=False):
    return {"type": 12, "params": path, "error_handler": 1 if discard else 0, "error_handler_params": ""}


# ------------------------------------------------------------------ JavaScript do Zabbix (ES5)
# O mesmo decodificador de índice nos dois resumos:
#   0x11RRSSPP  (ifIndex do IF-MIB)        -> RR/SS/PP
#   0x10SSPP00  (índice de PON da ZTE)     -> 1/SS/PP, com PP a partir de 0 quando a tabela tem PP=0
JS_ONU_RX = r"""
var BASE = '{$ONU.RX.OID}'.replace(/^\./, '') + '.';
var FMT = '{$ONU.RX.FMT}';
var LOW = parseFloat('{$ONU.RX.LOW}');
if (isNaN(LOW)) LOW = -28;
var lines = String(value).split('\n'), rows = [], zero = false;
for (var i = 0; i < lines.length; i++) {
  var m = /^\.?([0-9.]+)\s*=\s*[A-Za-z0-9 -]+:\s*"?(-?[0-9.]+)/.exec(lines[i]);
  if (!m || m[1].indexOf(BASE) !== 0) continue;
  var idx = m[1].substr(BASE.length).split('.');
  if (idx.length < 2) continue;
  var p = parseInt(idx[0], 10), onu = parseInt(idx[1], 10), raw = parseFloat(m[2]), dbm;
  if (isNaN(p) || isNaN(onu) || isNaN(raw)) continue;
  if (FMT === 'zte002') { if (raw <= 0 || raw >= 32768) continue; dbm = raw * 0.002 - 30; }
  else { if (raw <= -2147483647 || raw >= 2147483647) continue; dbm = raw / 1000; }
  if (!(dbm > -50 && dbm < 10)) continue;
  var top = (p >>> 24) & 255;
  if (top === 17) rows.push([(p >>> 16) & 255, (p >>> 8) & 255, p & 255, onu, dbm, false]);
  else { var pb = (p >>> 8) & 255; if (pb === 0) zero = true; rows.push([1, (p >>> 16) & 255, pb, onu, dbm, true]); }
}
var out = {};
for (var j = 0; j < rows.length; j++) {
  var r = rows[j], key = r[0] + '/' + r[1] + '/' + (r[2] + (r[5] && zero ? 1 : 0));
  var o = out[key];
  if (!o) o = out[key] = { n: 0, sum: 0, min: null, minOnu: null, low: 0, onus: [] };
  var v = Math.round(r[4] * 100) / 100;
  o.n++; o.sum += v;
  if (o.min === null || v < o.min) { o.min = v; o.minOnu = r[3]; }
  if (v <= LOW) o.low++;
  o.onus.push([r[3], v]);
}
for (var k in out) {
  var q = out[k];
  q.avg = Math.round(q.sum / q.n * 100) / 100;
  delete q.sum;
  q.onus.sort(function (a, b) { return a[1] - b[1]; });
}
return JSON.stringify(out);
"""

JS_OPT = r"""
var BASE = '1.3.6.1.4.1.3902.1015.3.1.13.1.';
var TX = parseInt('{$OPT.TX.COL}', 10) || 0, RX = parseInt('{$OPT.RX.COL}', 10) || 0;
var SCALE = parseFloat('{$OPT.SCALE}') || 1000;
var lines = String(value).split('\n'), rows = [], zero = false;
for (var i = 0; i < lines.length; i++) {
  var m = /^\.?([0-9.]+)\s*=\s*[A-Za-z0-9 -]+:\s*"?(-?[0-9.]+)/.exec(lines[i]);
  if (!m || m[1].indexOf(BASE) !== 0) continue;
  var parts = m[1].substr(BASE.length).split('.');
  if (parts.length < 2) continue;
  var col = parseInt(parts[0], 10), p = parseInt(parts[1], 10), raw = parseFloat(m[2]);
  if (isNaN(p) || isNaN(raw) || (col !== TX && col !== RX)) continue;
  var top = (p >>> 24) & 255, pb = (p >>> 8) & 255;
  if (top !== 17 && pb === 0) zero = true;
  if (raw <= -2147483647 || raw >= 2147483647) continue;
  var dbm = raw / SCALE;
  if (!(dbm > -50 && dbm < 15)) continue;
  if (top === 17) rows.push([(p >>> 16) & 255, (p >>> 8) & 255, p & 255, col, dbm, false]);
  else rows.push([1, (p >>> 16) & 255, pb, col, dbm, true]);
}
var out = {};
for (var j = 0; j < rows.length; j++) {
  var r = rows[j], key = r[0] + '/' + r[1] + '/' + (r[2] + (r[5] && zero ? 1 : 0));
  var o = out[key] || (out[key] = {});
  o[r[3] === TX ? 'tx' : 'rx'] = Math.round(r[4] * 100) / 100;
}
return JSON.stringify(out);
"""

JS_LLD_PON = r"""
var o = JSON.parse(value), a = [];
for (var k in o) a.push({ '{#PON}': k });
return JSON.stringify(a);
"""

JS_LLD_PORT = r"""
var o = JSON.parse(value), a = [];
for (var k in o) a.push({ '{#PORT}': k });
return JSON.stringify(a);
"""


def ok(m):    print("\033[32m✔\033[0m " + m, flush=True)
def info(m):  print("\033[36m•\033[0m " + m, flush=True)
def aviso(m): print("\033[33m!\033[0m " + m, flush=True)
def falha(m):
    print("\033[31m✘ " + m + "\033[0m", file=sys.stderr, flush=True)
    sys.exit(1)


def pergunta(texto, padrao="n"):
    try:
        r = input(texto + (" [S/n] " if padrao == "s" else " [s/N] ")).strip().lower()
    except EOFError:
        r = ""
    return (r or padrao) in ("s", "sim", "y", "yes")


def dbm(v):
    return ("%+.2f dBm" % v).replace("-", "−").replace(".", ",")


class ZbxError(Exception):
    pass


class Api:
    def __init__(self, url, token=None):
        self.url, self.token = url, token

    def call(self, method, params=None, auth=True):
        body = {"jsonrpc": "2.0", "method": method, "params": {} if params is None else params, "id": 1}
        headers = {"Content-Type": "application/json-rpc", "User-Agent": "curl/7.81.0"}
        if auth and self.token:
            headers["Authorization"] = "Bearer " + self.token
        req = urllib.request.Request(self.url, json.dumps(body).encode("utf-8"), headers)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = json.load(resp)
        except urllib.error.HTTPError as e:
            raise ZbxError("%s: HTTP %s" % (method, e.code))
        except urllib.error.URLError as e:
            raise ZbxError("%s: sem conexão (%s)" % (method, e.reason))
        except ValueError:
            raise ZbxError("%s: resposta que não é JSON (confira a URL da API)" % method)
        if "error" in data:
            err = data["error"]
            raise ZbxError("%s: %s %s" % (method, err.get("message", ""), err.get("data", "")))
        return data.get("result")


def versao(v):
    return tuple(int(x) for x in re.findall(r"\d+", v)[:2])


# ---------------------------------------------------------------- SNMP

def garantir_snmp():
    if shutil.which("snmpget") and shutil.which("snmpbulkwalk"):
        return True
    info("Instalando as ferramentas SNMP (pacote snmp)…")
    r = subprocess.run(["apt-get", "install", "-y", "snmp"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if r.returncode != 0 or not shutil.which("snmpget"):
        aviso("Não consegui instalar o pacote snmp: " + r.stderr.strip()[-200:])
        return False
    return True


def snmp(cmd, comunidade, ip, oid, timeout=60, espera=5):
    args = [cmd, "-v2c", "-c", comunidade, "-On", "-t", str(espera), "-r", "1"]
    if cmd == "snmpbulkwalk":
        args += ["-Cr25"]
    try:
        r = subprocess.run(args + [ip, oid], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return ""
    return r.stdout


def valores(saida, base):
    """{índice: valor} de uma saída snmpwalk -On (número quando dá, texto quando não)."""
    out = {}
    pref = "." + base.lstrip(".") + "."
    for linha in saida.splitlines():
        m = re.match(r"^(\.[\d.]+)\s*=\s*(\w[\w\- ]*):\s*(.*)$", linha)
        if not m or not m.group(1).startswith(pref):
            continue
        idx, val = m.group(1)[len(pref):], m.group(3).strip().strip('"')
        try:
            out[idx] = float(val.split()[0])
        except (ValueError, IndexError):
            out[idx] = val
    return out


def decodificador(indices):
    """Mesmo critério do JavaScript: índice de PON da ZTE -> '1/slot/porta'."""
    ints = [int(i) for i in indices]
    zero = any(((p >> 24) & 255) != 17 and ((p >> 8) & 255) == 0 for p in ints)

    def nome(p):
        p = int(p)
        if ((p >> 24) & 255) == 17:
            return "%d/%d/%d" % ((p >> 16) & 255, (p >> 8) & 255, p & 255)
        return "1/%d/%d" % ((p >> 16) & 255, ((p >> 8) & 255) + (1 if zero else 0))
    return nome


def tipos_de_porta(com, ip):
    """{'1/2/1': 'pon', '1/0/1': 'up'} a partir do ifName."""
    tipos = {}
    for _, nome in valores(snmp("snmpbulkwalk", com, ip, IFNAME, timeout=90), IFNAME).items():
        m = re.match(r"^([a-z0-9-]+?)(?:-olt)?_(\d+)/(\d+)/(\d+)$", str(nome), re.I)
        if not m:
            continue
        t = m.group(1).lower()
        k = "%s/%s/%s" % (m.group(2), m.group(3), m.group(4))
        if t.startswith(("gpon", "xgs", "xg-pon", "epon")):
            tipos[k] = "pon"
        elif t.endswith("gei") or t.startswith(("xgei", "gei", "xxgei", "cgei")):
            tipos[k] = "up"
    return tipos


def sondar_onu_rx(com, ip, relatorio):
    for oid, fmt in ONU_RX_CANDIDATES:
        saida = snmp("snmpbulkwalk", com, ip, oid, timeout=240)
        brutos = valores(saida, oid)
        bons = {}
        for idx, raw in brutos.items():
            if not isinstance(raw, float) or "." not in idx:
                continue
            v = raw * 0.002 - 30 if fmt == "zte002" else raw / 1000.0
            if fmt == "zte002" and not (0 < raw < 32768):
                continue
            if -50 < v < 10:
                bons[idx] = v
        relatorio.append("ONU RX %s (%s): %d leituras, %d válidas" % (oid, fmt, len(brutos), len(bons)))
        relatorio.extend("   %s = %.2f dBm" % (k, v) for k, v in list(bons.items())[:8])
        if len(bons) >= 3:
            nome = decodificador([k.split(".")[0] for k in bons])
            pons = {}
            for k, v in bons.items():
                pons.setdefault(nome(k.split(".")[0]), []).append(v)
            return {"oid": oid, "fmt": fmt, "onus": len(bons), "pons": pons}
    return None


def sondar_modulos(com, ip, tipos, relatorio):
    saida = snmp("snmpbulkwalk", com, ip, OPT_TABLE, timeout=240)
    cols = {}
    pref = "." + OPT_TABLE + "."
    for linha in saida.splitlines():
        m = re.match(r"^(\.[\d.]+)\s*=\s*\w[\w\- ]*:\s*\"?(-?[\d.]+)", linha)
        if not m or not m.group(1).startswith(pref):
            continue
        partes = m.group(1)[len(pref):].split(".")
        if len(partes) != 2:
            continue
        cols.setdefault(int(partes[0]), {})[int(partes[1])] = float(m.group(2))
    if not cols:
        relatorio.append("Tabela óptica %s: sem resposta" % OPT_TABLE)
        return None
    todos = set()
    for c in cols.values():
        todos.update(c.keys())
    nome = decodificador(todos)
    relatorio.append("Tabela óptica %s: %d colunas" % (OPT_TABLE, len(cols)))
    amostra_pon = next((i for i in sorted(todos) if tipos.get(nome(i)) == "pon" and any(abs(c.get(i, INVALIDO)) < INVALIDO for c in cols.values())), None)
    amostra_up = next((i for i in sorted(todos) if tipos.get(nome(i)) == "up" and abs(cols.get(1, {}).get(i, INVALIDO)) < INVALIDO), None)
    for col in sorted(cols):
        relatorio.append("   coluna %2d: PON %s = %s · uplink %s = %s" % (
            col, nome(amostra_pon) if amostra_pon is not None else "-", cols[col].get(amostra_pon, "-"),
            nome(amostra_up) if amostra_up is not None else "-", cols[col].get(amostra_up, "-")))

    def separa(col, escala):
        pon, up = {}, {}
        for i, v in cols[col].items():
            if abs(v) >= INVALIDO:
                continue
            t = tipos.get(nome(i))
            if t == "pon":
                pon[nome(i)] = v / escala
            elif t == "up":
                up[nome(i)] = v / escala
        return pon, up

    def mediana(xs):
        xs = sorted(xs)
        return xs[len(xs) // 2]

    candidatos_tx = []
    for escala in (1000.0, 100.0):
        for col in cols:
            pon, up = separa(col, escala)
            if len(pon) < 3:
                continue
            vs = list(pon.values())
            if not all(-1 <= x <= 10 for x in vs) or not (0.5 <= mediana(vs) <= 9):
                continue
            distintos = len({round(x, 2) for x in vs})
            if distintos < 3:
                continue
            if up and not (-12 <= mediana(list(up.values())) <= 2.5):
                continue
            # na tabela da ZTE o TX vem antes de temperatura, tensão e corrente: entre as colunas
            # possíveis, a de menor número; tensão (~3,3) fica de fora pela faixa estreita
            if max(vs) - min(vs) < 0.2 and 3.0 <= mediana(vs) <= 3.6:
                continue
            candidatos_tx.append(((bool(up), -col, escala), col, escala, pon, up))
    if not candidatos_tx:
        relatorio.append("TX das PONs: nenhuma coluna com valores de TX de GPON")
        return {"tx": 0, "rx": 0, "escala": 1000.0}
    candidatos_tx.sort(key=lambda c: c[0], reverse=True)
    _, tx_col, escala, tx_pon, tx_up = candidatos_tx[0]

    rx_col, rx_up = 0, {}
    pons_total = sum(1 for t in tipos.values() if t == "pon")
    for col in sorted(cols):
        if col == tx_col:
            continue
        pon, up = separa(col, escala)
        if not up or len(pon) > max(1, pons_total // 10):
            continue
        vs = list(up.values())
        if not all(-30 <= x <= 5 for x in vs):
            continue
        if len(vs) >= 2 and len({round(x, 2) for x in vs}) < 2:
            continue
        rx_col, rx_up = col, up
        break
    relatorio.append("TX: coluna %d, escala %d · RX dos uplinks: coluna %d" % (tx_col, escala, rx_col))
    return {"tx": tx_col, "rx": rx_col, "escala": escala, "tx_pon": tx_pon, "tx_up": tx_up, "rx_up": rx_up}


# ---------------------------------------------------------------- Zabbix: utilidades

def get_or_create(api, obj, filtro, criar, idfield):
    r = api.call(obj + ".get", {"output": [idfield], "filter": filtro})
    if r:
        return r[0][idfield], False
    r = api.call(obj + ".create", criar)
    return r[idfield + "s"][0], True


def main():
    if os.geteuid() != 0:
        falha("Rode como root.")
    print("\nMonitoramento das OLTs no Zabbix da UpDown — versão 2.1\n")
    api = Api(LOCAL_URL)
    try:
        v = api.call("apiinfo.version", auth=False)
    except ZbxError as e:
        falha("A API do Zabbix não respondeu em %s (%s). Se ela estiver em outro endereço, rode com ZBX_URL=http://…/api_jsonrpc.php" % (LOCAL_URL, e))
    ok("Zabbix %s respondendo em %s" % (v, LOCAL_URL))
    if versao(v) < (6, 4):
        falha("Este Zabbix é anterior ao 6.4; o sinal óptico usa a coleta walk[], que só existe a partir do 6.4.")
    usuario = input("Usuário administrador do Zabbix [Admin]: ").strip() or "Admin"
    senha = getpass.getpass("Senha de %s (não aparece na tela): " % usuario)
    try:
        api.token = api.call("user.login", {"username": usuario, "password": senha}, auth=False)
    except ZbxError as e:
        falha("Não entrou no Zabbix: " + str(e))
    senha = None
    ok("Entrou no Zabbix como " + usuario)
    try:
        executar(api, v)
    finally:
        try:
            api.call("user.logout", [])
        except ZbxError:
            pass


def pedir_comunidade(o, snmp_ok):
    for tentativa in range(3):
        extra = ", Enter para pular" if tentativa else ""
        c = getpass.getpass("Comunidade SNMP da %s (%s; não aparece na tela%s): " % (o["curto"], o["ip"], extra)).strip()
        if not c:
            return None
        if not snmp_ok:
            return c
        resp = snmp("snmpget", c, o["ip"], SYSNAME, timeout=25, espera=8).strip()
        if resp:
            ok("%s respondeu (%s)" % (o["curto"], resp.split("=", 1)[-1].strip()))
            return c
        aviso("A %s não respondeu com essa comunidade. Confira maiúsculas, minúsculas e espaços." % o["curto"])
    return None


def executar(api, versao_zbx):
    v7 = versao(versao_zbx) >= (7, 0)
    estado = {}
    try:
        with open(os.path.join(STATE_DIR, "zabbix-olts.json"), encoding="utf-8") as f:
            estado = json.load(f)
    except (OSError, ValueError):
        pass
    temp_base = estado.get("temp_base", TEMP_BASE_DEFAULT)
    for o in OLTS:
        info("%s → %s:%s" % (o["nome"], o["ip"], o.get("port", "161")))

    # 1. comunidades e sondagem
    snmp_ok = garantir_snmp()
    relatorio = []
    mem_ok = bool(estado.get("mem"))
    for o in OLTS:
        o["com"] = pedir_comunidade(o, snmp_ok)
        if not o["com"]:
            aviso("%s: sem comunidade confirmada; a macro atual do host fica como está e a sondagem é pulada." % o["curto"])
            continue
        if not snmp_ok:
            continue
        relatorio.append("== %s (%s)" % (o["nome"], o["ip"]))
        cpu = valores(snmp("snmpbulkwalk", o["com"], o["ip"], CPU_BASE), CPU_BASE)
        mem = valores(snmp("snmpbulkwalk", o["com"], o["ip"], MEM_BASE), MEM_BASE)
        bons = [x for k, x in mem.items() if isinstance(x, float) and 0 <= x <= 100 and k in cpu]
        relatorio.append("CPU: %d placas · memória: %d placas" % (len(cpu), len(bons)))
        if cpu and len(bons) >= max(1, len(cpu) // 2):
            mem_ok = True
            ok("  memória por placa: %d placas" % len(bons))
        else:
            aviso("  memória por placa não respondeu no OID esperado")

        info("  lendo o sinal das ONUs (pode levar 1 a 2 min)…")
        o["onu"] = sondar_onu_rx(o["com"], o["ip"], relatorio)
        if o["onu"]:
            todos = [x for vs in o["onu"]["pons"].values() for x in vs]
            pior_pon = min(o["onu"]["pons"], key=lambda k: min(o["onu"]["pons"][k]))
            ok("  sinal RX de %d ONUs em %d PONs (pior: %s na PON %s; média %s)" % (
                len(todos), len(o["onu"]["pons"]), dbm(min(todos)), pior_pon, dbm(sum(todos) / len(todos))))
        else:
            aviso("  a OLT não devolveu o sinal das ONUs nos OIDs conhecidos")

        tipos = tipos_de_porta(o["com"], o["ip"])
        o["mod"] = sondar_modulos(o["com"], o["ip"], tipos, relatorio)
        mod = o["mod"]
        if mod and mod["tx"]:
            ex = list(mod["tx_pon"].items())[:4]
            print("  TX das PONs (coluna %d): %s" % (mod["tx"], " · ".join("%s %s" % (k, dbm(x)) for k, x in ex)))
            if mod["rx"]:
                print("  RX dos uplinks (coluna %d): %s" % (mod["rx"], " · ".join("%s %s" % (k, dbm(x)) for k, x in list(mod["rx_up"].items())[:4])))
            if not pergunta("  Esses valores de TX parecem certos? (GPON costuma ficar entre +1,5 e +7 dBm)", "s"):
                mod["tx"] = mod["rx"] = 0
                aviso("  TX desligado para a %s; mande o arquivo %s para revisar." % (o["curto"], PROBE_FILE))
        else:
            aviso("  TX das PONs não identificado na tabela óptica")
    if relatorio:
        with open(PROBE_FILE, "w", encoding="utf-8") as f:
            f.write("\n".join(relatorio) + "\n")
        os.chmod(PROBE_FILE, 0o600)
        info("Detalhes da sondagem em " + PROBE_FILE)

    # 2. grupos e template
    gid, novo = get_or_create(api, "hostgroup", {"name": [HOST_GROUP]}, {"name": HOST_GROUP}, "groupid")
    (ok if novo else info)("Grupo de hosts %s" % HOST_GROUP)
    if versao(versao_zbx) >= (6, 2):
        tgid, _ = get_or_create(api, "templategroup", {"name": [TEMPLATE_GROUP]}, {"name": TEMPLATE_GROUP}, "groupid")
    else:
        tgid, _ = get_or_create(api, "hostgroup", {"name": [TEMPLATE_GROUP]}, {"name": TEMPLATE_GROUP}, "groupid")
    tid, novo = get_or_create(api, "template", {"host": [TEMPLATE]},
                              {"host": TEMPLATE, "name": TEMPLATE, "groups": [{"groupid": tgid}],
                               "description": "Tráfego, saúde das placas e sinal óptico de OLTs ZTE (C300/C350). Criado pelo provisionar-zabbix.py do Painel das OLTs."},
                              "templateid")
    (ok if novo else info)("Template %s" % TEMPLATE)

    def macro(hostid, nome, valor, descr="", secreta=False):
        r = api.call("usermacro.get", {"hostids": [hostid], "filter": {"macro": [nome]}, "output": ["hostmacroid", "value"]})
        p = {"value": str(valor), "type": 1 if secreta else 0}
        if descr:
            p["description"] = descr
        if r:
            api.call("usermacro.update", dict(p, hostmacroid=r[0]["hostmacroid"]))
        else:
            api.call("usermacro.create", dict(p, hostid=hostid, macro=nome))

    def macro_padrao(nome, valor, descr, forcar=False):
        r = api.call("usermacro.get", {"hostids": [tid], "filter": {"macro": [nome]}, "output": ["hostmacroid"]})
        if not r:
            api.call("usermacro.create", {"hostid": tid, "macro": nome, "value": str(valor), "description": descr})
        elif forcar:
            api.call("usermacro.update", {"hostmacroid": r[0]["hostmacroid"], "value": str(valor), "description": descr})

    macro_padrao("{$ONU.RX.OID}", ONU_RX_CANDIDATES[0][0], "OID do sinal RX recebido pelas ONUs", forcar=True)
    macro_padrao("{$ONU.RX.FMT}", ONU_RX_CANDIDATES[0][1], "milli = milésimos de dBm; zte002 = valor*0,002-30", forcar=True)
    macro_padrao("{$ONU.RX.LOW}", "-28", "ONU com RX igual ou abaixo deste valor conta como sinal baixo (dBm)")
    macro_padrao("{$OPT.TX.COL}", "0", "Coluna de TX na tabela óptica (0 = não coletar)")
    macro_padrao("{$OPT.RX.COL}", "0", "Coluna de RX na tabela óptica (0 = não coletar)")
    macro_padrao("{$OPT.SCALE}", "1000", "Divisor dos valores da tabela óptica para chegar em dBm")

    def regra(key, nome, oid, filtro=None, delay="10m"):
        r = api.call("discoveryrule.get", {"templateids": [tid], "filter": {"key_": [key]}, "output": ["itemid"]})
        if r:
            return r[0]["itemid"]
        p = {"hostid": tid, "name": nome, "key_": key, "type": 20, "snmp_oid": oid, "delay": delay, "lifetime": "7d"}
        if filtro:
            p["filter"] = filtro
        return api.call("discoveryrule.create", p)["itemids"][0]

    def regra_dependente(key, nome, master, js):
        p = {"name": nome, "type": 18, "master_itemid": master, "lifetime": "7d", "preprocessing": [prep_js(js)]}
        r = api.call("discoveryrule.get", {"templateids": [tid], "filter": {"key_": [key]}, "output": ["itemid"]})
        if r:
            api.call("discoveryrule.update", dict(p, itemid=r[0]["itemid"]))
            return r[0]["itemid"]
        return api.call("discoveryrule.create", dict(p, hostid=tid, key_=key))["itemids"][0]

    def item(p):
        r = api.call("item.get", {"templateids": [tid], "filter": {"key_": [p["key_"]]}, "output": ["itemid"]})
        if r:
            upd = {k: x for k, x in p.items() if k not in ("key_", "type", "value_type")}
            api.call("item.update", dict(upd, itemid=r[0]["itemid"]))
            return r[0]["itemid"]
        return api.call("item.create", dict(p, hostid=tid))["itemids"][0]

    def prototipos(ruleid, lista, atualizar=False):
        existentes = {x["key_"]: x["itemid"] for x in api.call("itemprototype.get", {"discoveryids": [ruleid], "output": ["key_", "itemid"]}) or []}
        novos = [dict(p, ruleid=ruleid, hostid=tid) for p in lista if p["key_"] not in existentes]
        if novos:
            api.call("itemprototype.create", novos)
        if atualizar:
            for p in lista:
                if p["key_"] in existentes:
                    upd = {k: x for k, x in p.items() if k not in ("key_", "type", "value_type", "master_itemid")}
                    api.call("itemprototype.update", dict(upd, itemid=existentes[p["key_"]]))
        return len(novos)

    if_rule = regra("olt.if.discovery", "Portas da OLT (PON e uplinks)",
                    "discovery[{#IFNAME},1.3.6.1.2.1.31.1.1.1.1,{#IFALIAS},1.3.6.1.2.1.31.1.1.1.18]",
                    {"evaltype": 0, "conditions": [{"macro": "{#IFNAME}", "value": IF_FILTER, "operator": 8}]})
    base = "Interface {#IFNAME}({#IFALIAS}): "
    n = prototipos(if_rule, [
        {"name": base + "Bits received", "key_": "net.if.in[ifHCInOctets.{#SNMPINDEX}]", "type": 20,
         "snmp_oid": "1.3.6.1.2.1.31.1.1.1.6.{#SNMPINDEX}", "value_type": 3, "units": "bps", "delay": "1m",
         "preprocessing": [PREP_CHANGE, prep_mult(8)]},
        {"name": base + "Bits sent", "key_": "net.if.out[ifHCOutOctets.{#SNMPINDEX}]", "type": 20,
         "snmp_oid": "1.3.6.1.2.1.31.1.1.1.10.{#SNMPINDEX}", "value_type": 3, "units": "bps", "delay": "1m",
         "preprocessing": [PREP_CHANGE, prep_mult(8)]},
        {"name": base + "Operational status", "key_": "net.if.status[ifOperStatus.{#SNMPINDEX}]", "type": 20,
         "snmp_oid": "1.3.6.1.2.1.2.2.1.8.{#SNMPINDEX}", "value_type": 3, "delay": "1m"},
        {"name": base + "Speed", "key_": "net.if.speed[ifHighSpeed.{#SNMPINDEX}]", "type": 20,
         "snmp_oid": "1.3.6.1.2.1.31.1.1.1.15.{#SNMPINDEX}", "value_type": 3, "units": "bps", "delay": "1h",
         "preprocessing": [prep_mult(1000000)]},
        {"name": base + "Inbound packets with errors", "key_": "net.if.in.errors[ifInErrors.{#SNMPINDEX}]", "type": 20,
         "snmp_oid": "1.3.6.1.2.1.2.2.1.14.{#SNMPINDEX}", "value_type": 0, "units": "/s", "delay": "5m", "preprocessing": [PREP_CHANGE]},
        {"name": base + "Outbound packets with errors", "key_": "net.if.out.errors[ifOutErrors.{#SNMPINDEX}]", "type": 20,
         "snmp_oid": "1.3.6.1.2.1.2.2.1.20.{#SNMPINDEX}", "value_type": 0, "units": "/s", "delay": "5m", "preprocessing": [PREP_CHANGE]},
        {"name": base + "Inbound packets discarded", "key_": "net.if.in.discards[ifInDiscards.{#SNMPINDEX}]", "type": 20,
         "snmp_oid": "1.3.6.1.2.1.2.2.1.13.{#SNMPINDEX}", "value_type": 0, "units": "/s", "delay": "5m", "preprocessing": [PREP_CHANGE]},
        {"name": base + "Outbound packets discarded", "key_": "net.if.out.discards[ifOutDiscards.{#SNMPINDEX}]", "type": 20,
         "snmp_oid": "1.3.6.1.2.1.2.2.1.19.{#SNMPINDEX}", "value_type": 0, "units": "/s", "delay": "5m", "preprocessing": [PREP_CHANGE]},
    ])
    ok("Portas: tráfego, estado, velocidade, erros e descartes" + (" (%d itens novos)" % n if n else ""))

    card_rule = regra("olt.card.discovery", "Placas da OLT", "discovery[{#CPU},%s]" % CPU_BASE)
    cards = [
        {"name": "CPU Load Placa {#SNMPINDEX}", "key_": "zte.card.cpu[{#SNMPINDEX}]", "type": 20,
         "snmp_oid": CPU_BASE + ".{#SNMPINDEX}", "value_type": 3, "units": "%", "delay": "1m"},
        {"name": "Temperatura Placa {#SNMPINDEX}", "key_": "zte.card.temp[{#SNMPINDEX}]", "type": 20,
         "snmp_oid": temp_base + ".{#SNMPINDEX}", "value_type": 0, "units": "°C", "delay": "2m"},
    ]
    if mem_ok:
        cards.append({"name": "Memória Placa {#SNMPINDEX}", "key_": "zte.card.mem[{#SNMPINDEX}]", "type": 20,
                      "snmp_oid": MEM_BASE + ".{#SNMPINDEX}", "value_type": 3, "units": "%", "delay": "1m"})
    n = prototipos(card_rule, cards)
    ok("Placas: CPU, temperatura%s" % (" e memória" if mem_ok else "") + (" (%d itens novos)" % n if n else ""))

    # sinal RX das ONUs: uma coleta walk[] por OLT, resumida por PON no próprio Zabbix
    walk_extra = {"timeout": "180s"} if v7 else {}
    onu_walk = item(dict({"name": "Sinal RX das ONUs (coleta SNMP)", "key_": "zte.onu.rx.walk", "type": 20,
                          "snmp_oid": "walk[{$ONU.RX.OID}]", "value_type": 4, "delay": "10m", "history": "0",
                          "description": "Leitura bruta; os valores ficam nos itens por PON."}, **walk_extra))
    onu_sum = item({"name": "Sinal RX das ONUs por PON (resumo)", "key_": "zte.onu.rx.summary", "type": 18,
                    "master_itemid": onu_walk, "value_type": 4, "history": "0", "preprocessing": [prep_js(JS_ONU_RX)]})
    onu_rule = regra_dependente("zte.onu.rx.discovery", "PONs com sinal de ONU", onu_sum, JS_LLD_PON)
    pon = "{#PON}"
    n = prototipos(onu_rule, [
        {"name": "PON %s: RX da pior ONU" % pon, "key_": "zte.pon.rx.worst[%s]" % pon, "type": 18, "master_itemid": onu_sum,
         "value_type": 0, "units": "dBm", "history": "30d", "trends": "365d", "preprocessing": [prep_jsonpath("$['%s'].min" % pon)]},
        {"name": "PON %s: número da pior ONU" % pon, "key_": "zte.pon.rx.worstonu[%s]" % pon, "type": 18, "master_itemid": onu_sum,
         "value_type": 3, "history": "7d", "trends": "0", "preprocessing": [prep_jsonpath("$['%s'].minOnu" % pon)]},
        {"name": "PON %s: RX médio das ONUs" % pon, "key_": "zte.pon.rx.avg[%s]" % pon, "type": 18, "master_itemid": onu_sum,
         "value_type": 0, "units": "dBm", "history": "30d", "trends": "365d", "preprocessing": [prep_jsonpath("$['%s'].avg" % pon)]},
        {"name": "PON %s: ONUs com leitura de sinal" % pon, "key_": "zte.pon.rx.count[%s]" % pon, "type": 18, "master_itemid": onu_sum,
         "value_type": 3, "history": "30d", "trends": "365d", "preprocessing": [prep_jsonpath("$['%s'].n" % pon)]},
        {"name": "PON %s: ONUs com sinal baixo" % pon, "key_": "zte.pon.rx.low[%s]" % pon, "type": 18, "master_itemid": onu_sum,
         "value_type": 3, "history": "30d", "trends": "365d", "preprocessing": [prep_jsonpath("$['%s'].low" % pon)]},
        {"name": "PON %s: sinal de cada ONU" % pon, "key_": "zte.pon.rx.onus[%s]" % pon, "type": 18, "master_itemid": onu_sum,
         "value_type": 4, "history": "1h", "preprocessing": [prep_jsonpath("$['%s'].onus" % pon)]},
    ], atualizar=True)
    ok("Sinal RX das ONUs por PON: pior, médio, quantidade, sinal baixo e lista" + (" (%d itens novos)" % n if n else ""))

    # TX das PONs e RX/TX dos uplinks: tabela óptica, só as colunas identificadas
    opt_walk = item(dict({"name": "Sinal óptico dos módulos (coleta SNMP)", "key_": "zte.opt.walk", "type": 20,
                          "snmp_oid": "walk[%s.{$OPT.TX.COL},%s.{$OPT.RX.COL}]" % (OPT_TABLE, OPT_TABLE),
                          "value_type": 4, "delay": "5m", "history": "0"}, **walk_extra))
    opt_sum = item({"name": "Sinal óptico dos módulos (resumo)", "key_": "zte.opt.summary", "type": 18,
                    "master_itemid": opt_walk, "value_type": 4, "history": "0", "preprocessing": [prep_js(JS_OPT)]})
    opt_rule = regra_dependente("zte.opt.discovery", "Portas com módulo óptico", opt_sum, JS_LLD_PORT)
    port = "{#PORT}"
    n = prototipos(opt_rule, [
        {"name": "Porta %s: TX do módulo" % port, "key_": "zte.opt.tx[%s]" % port, "type": 18, "master_itemid": opt_sum,
         "value_type": 0, "units": "dBm", "history": "30d", "trends": "365d", "preprocessing": [prep_jsonpath("$['%s'].tx" % port, discard=True)]},
        {"name": "Porta %s: RX do módulo" % port, "key_": "zte.opt.rx[%s]" % port, "type": 18, "master_itemid": opt_sum,
         "value_type": 0, "units": "dBm", "history": "30d", "trends": "365d", "preprocessing": [prep_jsonpath("$['%s'].rx" % port, discard=True)]},
    ], atualizar=True)
    ok("TX das PONs e RX/TX dos uplinks" + (" (%d itens novos)" % n if n else ""))

    # 3. hosts
    hostids = []
    for o in OLTS:
        r = api.call("host.get", {"filter": {"host": [o["nome"]]}, "output": ["hostid"], "selectParentTemplates": ["templateid"],
                                  "selectInterfaces": ["interfaceid", "type", "details"]})
        novo_host = not r
        if r:
            hid = r[0]["hostid"]
            if tid not in [t["templateid"] for t in r[0].get("parentTemplates", [])]:
                api.call("template.massadd", {"templates": [{"templateid": tid}], "hosts": [{"hostid": hid}]})
            if o.get("com"):
                macro(hid, "{$SNMP_COMMUNITY}", o["com"], secreta=True)
                ok("%s: comunidade SNMP atualizada" % o["curto"])
            if v7:
                for itf in r[0].get("interfaces", []):
                    if str(itf.get("type")) == "2":
                        try:
                            det = {"version": 2, "bulk": 1, "community": "{$SNMP_COMMUNITY}", "max_repetitions": 25}
                            api.call("hostinterface.update", {"interfaceid": itf["interfaceid"], "details": det})
                        except ZbxError as e:
                            aviso("%s: não ajustei a coleta em lote da interface (%s)" % (o["curto"], e))
        else:
            if not o.get("com"):
                aviso("%s não existe no Zabbix e ficou sem comunidade: host não criado." % o["nome"])
                continue
            det = {"version": 2, "bulk": 1, "community": "{$SNMP_COMMUNITY}"}
            if v7:
                det["max_repetitions"] = 25
            hid = api.call("host.create", {
                "host": o["nome"], "name": o["nome"], "groups": [{"groupid": gid}], "templates": [{"templateid": tid}],
                "interfaces": [{"type": 2, "main": 1, "useip": 1, "ip": o["ip"], "dns": "", "port": o.get("port", "161"), "details": det}],
                "macros": [{"macro": "{$SNMP_COMMUNITY}", "value": o["com"], "type": 1}],
                "tags": [{"tag": "painel", "value": "olt"}],
            })["hostids"][0]
            ok("Host %s criado (%s)" % (o["nome"], o["ip"]))
        o["hostid"] = hid
        hostids.append(hid)

        # macros do sinal conforme a sondagem desta OLT
        onu, mod = o.get("onu"), o.get("mod")
        if onu:
            macro(hid, "{$ONU.RX.OID}", onu["oid"])
            macro(hid, "{$ONU.RX.FMT}", onu["fmt"])
        if mod is not None:
            macro(hid, "{$OPT.TX.COL}", mod["tx"])
            macro(hid, "{$OPT.RX.COL}", mod["rx"])
            macro(hid, "{$OPT.SCALE}", int(mod["escala"]))
        estados = {}
        if "onu" in o:
            estados["zte.onu.rx.walk"] = onu is not None
        if "mod" in o:
            estados["zte.opt.walk"] = bool(mod and (mod["tx"] or mod["rx"]))
        elif novo_host:
            estados["zte.opt.walk"] = False
        for key, ligado in estados.items():
            its = api.call("item.get", {"hostids": [hid], "filter": {"key_": [key]}, "output": ["itemid", "status"]}) or []
            for it in its:
                quero = "0" if ligado else "1"
                if str(it.get("status")) != quero:
                    api.call("item.update", {"itemid": it["itemid"], "status": int(quero)})
                    motivo = "a OLT não respondeu nesse OID" if key == "zte.onu.rx.walk" else "nenhuma coluna de sinal confirmada"
                    (info if ligado else aviso)("%s: coleta %s %s" % (o["curto"], key, "ligada" if ligado else "desligada (%s)" % motivo))
    for o in OLTS:
        o["com"] = None

    # coleta agora: descoberta e leituras do sinal
    regras = api.call("discoveryrule.get", {"hostids": hostids, "output": ["itemid", "type"]}) or []
    walks = api.call("item.get", {"hostids": hostids, "filter": {"key_": ["zte.onu.rx.walk", "zte.opt.walk"], "status": 0}, "output": ["itemid"]}) or []
    pedir = [x["itemid"] for x in regras if str(x.get("type")) != "18"] + [x["itemid"] for x in walks]
    if pedir:
        try:
            api.call("task.create", [{"type": 6, "request": {"itemid": i}} for i in pedir])
            ok("Coleta disparada agora (descoberta e sinal óptico)")
        except ZbxError as e:
            aviso("Não deu para disparar a coleta agora (%s); ela roda sozinha em até 10 min." % e)

    # 4. usuário e token de leitura para o painel
    token = token_do_painel(api, gid, versao_zbx)

    # 5. primeiros dados
    info("Esperando os primeiros dados (até 5 min)…")
    fim = time.time() + 300
    portas = sinal = 0
    while time.time() < fim:
        its = api.call("item.get", {"hostids": hostids, "search": {"key_": "net.if.in["}, "output": ["lastclock"]}) or []
        portas = sum(1 for i in its if str(i.get("lastclock", "0")) not in ("0", ""))
        rx = api.call("item.get", {"hostids": hostids, "search": {"key_": "zte.pon.rx.worst["}, "output": ["lastclock"]}) or []
        sinal = sum(1 for i in rx if str(i.get("lastclock", "0")) not in ("0", ""))
        print("\r  portas com tráfego: %d · PONs com sinal RX: %d   " % (portas, sinal), end="", flush=True)
        if portas and sinal:
            break
        time.sleep(15)
    print()
    if sinal:
        ok("Sinal RX das ONUs chegando no Zabbix")
    else:
        aviso("O sinal ainda não chegou. A primeira leitura completa pode levar até 10 min; veja Monitoramento → Dados recentes, item \"Sinal RX das ONUs\".")

    os.makedirs(STATE_DIR, exist_ok=True)
    with open(os.path.join(STATE_DIR, "zabbix-olts.json"), "w", encoding="utf-8") as f:
        json.dump({"temp_base": temp_base, "mem": mem_ok, "url": LOCAL_URL, "hosts": [o["nome"] for o in OLTS], "versao_script": 2}, f, indent=2)

    print("\n" + "=" * 64)
    print("URL da API:  %s" % LOCAL_URL)
    print("Token:       %s" % token)
    print("=" * 64)
    print("O token já está no nginx do painel. Recarregue o painel com Ctrl+F5.")


def token_do_painel(api, gid, versao_zbx):
    """Reaproveita o token do nginx se ele ainda lê este Zabbix; senão cria outro e troca o nginx."""
    atual = None
    try:
        conf = open(NGINX_SITE, encoding="utf-8").read()
        m = re.search(r"location = /zbx-api \{.*?proxy_pass\s+(\S+);.*?Bearer ([A-Za-z0-9]+)", conf, re.S)
        if m and "127.0.0.1" in m.group(1):
            atual = m.group(2)
    except OSError:
        conf = ""
    if atual:
        try:
            hs = Api(LOCAL_URL, atual).call("host.get", {"output": ["name"], "groupids": [gid]})
            ok("Token atual do painel continua valendo (enxerga %d hosts)" % len(hs))
            return atual
        except ZbxError:
            aviso("O token que está no nginx não vale mais; vou gerar outro.")

    if versao(versao_zbx) >= (6, 2):
        ug = {"name": PANEL_GROUP, "hostgroup_rights": [{"id": gid, "permission": 2}], "gui_access": 3}
    else:
        ug = {"name": PANEL_GROUP, "rights": [{"id": gid, "permission": 2}], "gui_access": 3}
    ugid, novo = get_or_create(api, "usergroup", {"name": [PANEL_GROUP]}, ug, "usrgrpid")
    if not novo:
        api.call("usergroup.update", dict(ug, usrgrpid=ugid))
    roles = api.call("role.get", {"output": ["roleid", "name", "type"]}) or []
    role = next((r for r in roles if r["name"] == "User role"), None) or next((r for r in roles if str(r["type"]) == "1"), None)
    if not role:
        raise ZbxError("nenhum perfil (role) de usuário comum encontrado no Zabbix")
    u = api.call("user.get", {"filter": {"username": [PANEL_USER]}, "output": ["userid"]})
    if u:
        uid = u[0]["userid"]
        api.call("user.update", {"userid": uid, "usrgrps": [{"usrgrpid": ugid}], "roleid": role["roleid"]})
    else:
        uid = api.call("user.create", {"username": PANEL_USER, "name": "Painel das OLTs", "passwd": secrets.token_urlsafe(24) + "aA1!",
                                       "roleid": role["roleid"], "usrgrps": [{"usrgrpid": ugid}]})["userids"][0]
    antigos = api.call("token.get", {"userids": [uid], "filter": {"name": [TOKEN_NAME]}, "output": ["tokenid"]}) or []
    if antigos:
        api.call("token.delete", [t["tokenid"] for t in antigos])
    tkid = api.call("token.create", {"name": TOKEN_NAME, "userid": uid, "description": "Leitura do Painel das OLTs (nginx /zbx-api)"})["tokenids"][0]
    token = api.call("token.generate", [tkid])[0]["token"]
    ok("Usuário %s (somente leitura) com token de API novo" % PANEL_USER)
    if trocar_nginx(LOCAL_URL, token):
        ok("Painel apontado para o Zabbix da UpDown")
    return token


def trocar_nginx(url, token):
    try:
        conf = open(NGINX_SITE, encoding="utf-8").read()
    except OSError:
        aviso("Não achei %s; troque o /zbx-api à mão." % NGINX_SITE)
        return False
    bloco = (
        "location = /zbx-api {\n"
        "        auth_request /_auth;\n"
        "        proxy_pass %s;\n"
        "        proxy_set_header Host 127.0.0.1;\n"
        "        proxy_set_header Authorization \"Bearer %s\";\n"
        "        proxy_set_header Cookie \"\";\n"
        "        proxy_read_timeout 120s;\n"
        "    }" % (url, token)
    )
    novo, n = re.subn(r"location = /zbx-api \{.*?\n\s*\}", bloco, conf, count=1, flags=re.S)
    if not n:
        aviso("Não achei o bloco /zbx-api no nginx; troque à mão.")
        return False
    era_lv = "zbx7.lv.network" in conf
    backup = NGINX_SITE + (".bak-lv-" if era_lv else ".bak-") + time.strftime("%Y%m%d-%H%M%S")
    shutil.copy2(NGINX_SITE, backup)
    with open(NGINX_SITE, "w", encoding="utf-8") as f:
        f.write(novo)
    os.chmod(NGINX_SITE, 0o640)
    t = subprocess.run(["nginx", "-t"], capture_output=True, text=True)
    if t.returncode != 0:
        shutil.copy2(backup, NGINX_SITE)
        aviso("O nginx recusou a configuração nova; voltei a anterior.\n" + t.stderr[-400:])
        return False
    subprocess.run(["systemctl", "reload", "nginx"], check=False)
    info("Configuração anterior guardada em " + backup)
    return True


if __name__ == "__main__":
    try:
        main()
    except ZbxError as e:
        falha("Erro na API do Zabbix: %s" % e)
    except KeyboardInterrupt:
        print()
        falha("Interrompido.")
