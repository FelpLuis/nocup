#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Monitoramento das OLTs no Zabbix da UpDown (UPT-UBUNTU02, porta 19090)

  python3 provisionar-zabbix.py

O que faz, em ordem:
  1. entra na API do Zabbix local com o usuário administrador (você digita a senha)
  2. copia do Zabbix da LV os endereços SNMP e o OID de temperatura das OLTs
  3. testa o SNMP do servidor até cada OLT e sonda memória e sinal óptico
  4. cria o template "UpDown ZTE OLT SNMP" (tráfego, estado, velocidade, erros e
     descartes de cada porta; CPU, memória e temperatura de cada placa)
  5. cria os hosts OLT C350 VILA NATAL e OLT C300 CASQUEIRO com esse template
  6. cria o usuário somente leitura "painel-olt" e um token de API para ele
  7. espera chegarem os primeiros dados e, se você confirmar, troca o painel
     (nginx /zbx-api) para este Zabbix

Pode rodar de novo: o que já existe é reaproveitado, nada é duplicado.
Nenhuma senha fica gravada; a comunidade SNMP vai como macro secreta no host.
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
    {"nome": "OLT C350 VILA NATAL", "ip": "172.16.255.1", "lv_hostid": "29174"},
    {"nome": "OLT C300 CASQUEIRO", "ip": "172.16.255.3", "lv_hostid": "29173"},
]
HOST_GROUP = "OLTs UpDown"
TEMPLATE = "UpDown ZTE OLT SNMP"
TEMPLATE_GROUP = "Templates/UpDown"
PANEL_USER = "painel-olt"
PANEL_GROUP = "Painel OLT - leitura"
TOKEN_NAME = "Painel das OLTs"

# Tabela de placas da ZTE (ZXAN): índice rack.shelf.slot, ex. 1.1.13
CPU_BASE = "1.3.6.1.4.1.3902.1015.2.1.1.3.1.9"     # carga de CPU (%), o mesmo que a LV coleta
MEM_BASE = "1.3.6.1.4.1.3902.1015.2.1.1.3.1.11"    # uso de memória (%), confirmado pela sondagem
TEMP_BASE_DEFAULT = "1.3.6.1.4.1.3902.1015.2.1.3.13.5.1.1"
OPT_CANDIDATES = [
    ("Tabela óptica das portas", "1.3.6.1.4.1.3902.1015.3.1.13.1"),
    ("RX das ONUs medido na OLT", "1.3.6.1.4.1.3902.1015.1010.11.2.1.2"),
    ("Óptica das ONUs (GPON)", "1.3.6.1.4.1.3902.1012.3.50.12.1.1"),
]

IF_FILTER = r"^(gpon|xgs|xg-pon|epon|xgei|gei|smartgroup)"
PREP_CHANGE = {"type": 10, "params": "", "error_handler": 0, "error_handler_params": ""}
def prep_mult(n):
    return {"type": 1, "params": str(n), "error_handler": 0, "error_handler_params": ""}


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
            with urllib.request.urlopen(req, timeout=90) as resp:
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
    if shutil.which("snmpget") and shutil.which("snmpwalk"):
        return True
    info("Instalando as ferramentas SNMP (pacote snmp) para testar as OLTs…")
    r = subprocess.run(["apt-get", "install", "-y", "snmp"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if r.returncode != 0 or not shutil.which("snmpget"):
        aviso("Não consegui instalar o pacote snmp: " + r.stderr.strip()[-200:])
        return False
    return True


def snmp(cmd, comunidade, ip, oid, timeout=40):
    args = [cmd, "-v2c", "-c", comunidade, "-On", "-t", "3", "-r", "1"]
    if cmd == "snmpbulkwalk":
        args += ["-Cr25"]
    try:
        r = subprocess.run(args + [ip, oid], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return ""
    return r.stdout


def valores(saida, base):
    """{índice: valor} de uma saída snmpwalk -On."""
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
    print("\nMonitoramento das OLTs no Zabbix da UpDown\n")

    # 1. Zabbix local
    api = Api(LOCAL_URL)
    try:
        v = api.call("apiinfo.version", auth=False)
    except ZbxError as e:
        falha("A API do Zabbix não respondeu em %s (%s). Se ela estiver em outro endereço, rode com ZBX_URL=http://…/api_jsonrpc.php" % (LOCAL_URL, e))
    ok("Zabbix %s respondendo em %s" % (v, LOCAL_URL))
    if versao(v) < (6, 4):
        falha("Este Zabbix é anterior ao 6.4; o painel precisa do token no cabeçalho, que só existe a partir do 6.4.")
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


def executar(api, versao_zbx):
    # 2. dados do Zabbix da LV (IP, comunidade, OID de temperatura)
    estado = {}
    try:
        with open(os.path.join(STATE_DIR, "zabbix-olts.json"), encoding="utf-8") as f:
            estado = json.load(f)
    except (OSError, ValueError):
        pass
    temp_base = estado.get("temp_base", TEMP_BASE_DEFAULT)
    comunidade_lv = None
    lv_token = None
    try:
        conf = open(NGINX_SITE, encoding="utf-8").read()
        if "zbx7.lv.network" in conf:
            m = re.search(r"Bearer ([A-Za-z0-9]{16,})", conf)
            lv_token = m.group(1) if m else None
    except OSError:
        pass
    if lv_token:
        lv = Api(LV_URL, lv_token)
        try:
            hosts = lv.call("host.get", {"hostids": [o["lv_hostid"] for o in OLTS], "output": ["hostid", "name"], "selectInterfaces": "extend"})
            for h in hosts or []:
                olt = next((o for o in OLTS if o["lv_hostid"] == h["hostid"]), None)
                snmpif = next((i for i in h.get("interfaces", []) if str(i.get("type")) == "2"), None)
                if olt and snmpif:
                    olt["ip"] = snmpif.get("ip") or olt["ip"]
                    olt["port"] = snmpif.get("port") or "161"
                    com = (snmpif.get("details") or {}).get("community", "")
                    if com and not com.startswith("{$"):
                        comunidade_lv = com
            temps = lv.call("item.get", {"hostids": [OLTS[0]["lv_hostid"]], "output": ["name", "snmp_oid"],
                                         "search": {"name": "Temperatura Placa"}, "limit": 5})
            for it in temps or []:
                m = re.search(r"(\d+\.\d+\.\d+)\s*$", it["name"])
                oid = (it.get("snmp_oid") or "").lstrip(".")
                if m and oid.endswith("." + m.group(1)):
                    temp_base = oid[: -len(m.group(1)) - 1]
                    break
            ok("Copiado do Zabbix da LV: endereços SNMP das OLTs e o OID de temperatura")
        except ZbxError as e:
            aviso("Não consegui ler o Zabbix da LV (%s); sigo com os endereços conhecidos." % e)
    for o in OLTS:
        info("%s → %s:%s" % (o["nome"], o["ip"], o.get("port", "161")))

    # 3. SNMP até as OLTs
    comunidade = None
    if comunidade_lv and pergunta("Usar a mesma comunidade SNMP que o Zabbix da LV usa?", "s"):
        comunidade = comunidade_lv
    if not comunidade:
        comunidade = getpass.getpass("Comunidade SNMP das OLTs (não aparece na tela): ").strip()
    if not comunidade:
        falha("Sem comunidade SNMP não dá para monitorar as OLTs.")

    mem_ok = False
    sondagem = []
    if garantir_snmp():
        alcancadas = 0
        for o in OLTS:
            nome = snmp("snmpget", comunidade, o["ip"], "1.3.6.1.2.1.1.5.0", timeout=15).strip()
            if not nome:
                aviso("%s (%s) não respondeu ao SNMP a partir deste servidor." % (o["nome"], o["ip"]))
                o["snmp"] = False
                continue
            o["snmp"] = True
            alcancadas += 1
            ok("%s respondeu ao SNMP (%s)" % (o["nome"], nome.split("=", 1)[-1].strip()))
            cpu = valores(snmp("snmpbulkwalk", comunidade, o["ip"], CPU_BASE), CPU_BASE)
            mem = valores(snmp("snmpbulkwalk", comunidade, o["ip"], MEM_BASE), MEM_BASE)
            bons = [v for k, v in mem.items() if isinstance(v, float) and 0 <= v <= 100 and k in cpu]
            if cpu and len(bons) >= max(1, len(cpu) // 2):
                mem_ok = True
                ok("  memória por placa encontrada (%d placas, ex.: %s%%)" % (len(bons), int(bons[0])))
            else:
                aviso("  a OLT não devolveu memória por placa no OID esperado")
            sondagem.append("== %s (%s)" % (o["nome"], o["ip"]))
            sondagem.append("CPU %s: %d placas %s" % (CPU_BASE, len(cpu), dict(list(cpu.items())[:6])))
            sondagem.append("MEM %s: %d placas %s" % (MEM_BASE, len(mem), dict(list(mem.items())[:6])))
            for rotulo, oid in OPT_CANDIDATES:
                out = snmp("snmpbulkwalk", comunidade, o["ip"], oid, timeout=60)
                linhas = [l for l in out.splitlines() if l.startswith(".") and not re.search(r"No Such|No more variables|No Such Instance", l)]
                sondagem.append("%s %s: %d linhas" % (rotulo, oid, len(linhas)))
                sondagem.extend("   " + l for l in linhas[:25])
                if linhas:
                    info("  sinal óptico: %s respondeu (%d valores)" % (rotulo.lower(), len(linhas)))
        if sondagem:
            with open(PROBE_FILE, "w", encoding="utf-8") as f:
                f.write("\n".join(sondagem) + "\n")
            os.chmod(PROBE_FILE, 0o600)
            info("Resultado da sondagem SNMP salvo em " + PROBE_FILE)
        if not alcancadas and not pergunta("Nenhuma OLT respondeu ao SNMP deste servidor. Criar os hosts mesmo assim?"):
            falha("Parado antes de criar os hosts. Libere o SNMP (UDP 161) deste servidor até 172.16.255.1 e .3 e rode de novo.")
    else:
        aviso("Sem as ferramentas SNMP não deu para testar as OLTs; a memória entra no template e será validada pelo próprio Zabbix.")
        mem_ok = True

    # 4. grupos e template
    gid, novo = get_or_create(api, "hostgroup", {"name": [HOST_GROUP]}, {"name": HOST_GROUP}, "groupid")
    (ok if novo else info)("Grupo de hosts %s" % HOST_GROUP)
    if versao(versao_zbx) >= (6, 2):
        tgid, _ = get_or_create(api, "templategroup", {"name": [TEMPLATE_GROUP]}, {"name": TEMPLATE_GROUP}, "groupid")
    else:
        tgid, _ = get_or_create(api, "hostgroup", {"name": [TEMPLATE_GROUP]}, {"name": TEMPLATE_GROUP}, "groupid")
    tid, novo = get_or_create(api, "template", {"host": [TEMPLATE]},
                              {"host": TEMPLATE, "name": TEMPLATE, "groups": [{"groupid": tgid}],
                               "description": "Tráfego das portas PON e uplinks, CPU, memória e temperatura das placas ZTE (C300/C350). Criado pelo provisionar-zabbix.py do Painel das OLTs."},
                              "templateid")
    (ok if novo else info)("Template %s" % TEMPLATE)

    def regra(key, nome, oid, filtro=None, delay="10m"):
        r = api.call("discoveryrule.get", {"templateids": [tid], "filter": {"key_": [key]}, "output": ["itemid"]})
        if r:
            return r[0]["itemid"]
        p = {"hostid": tid, "name": nome, "key_": key, "type": 20, "snmp_oid": oid, "delay": delay, "lifetime": "7d"}
        if filtro:
            p["filter"] = filtro
        return api.call("discoveryrule.create", p)["itemids"][0]

    def prototipos(ruleid, lista):
        existentes = {x["key_"] for x in api.call("itemprototype.get", {"discoveryids": [ruleid], "output": ["key_"]}) or []}
        novos = [dict(p, ruleid=ruleid, hostid=tid) for p in lista if p["key_"] not in existentes]
        if novos:
            api.call("itemprototype.create", novos)
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
         "snmp_oid": "1.3.6.1.2.1.2.2.1.14.{#SNMPINDEX}", "value_type": 0, "delay": "5m", "preprocessing": [PREP_CHANGE]},
        {"name": base + "Outbound packets with errors", "key_": "net.if.out.errors[ifOutErrors.{#SNMPINDEX}]", "type": 20,
         "snmp_oid": "1.3.6.1.2.1.2.2.1.20.{#SNMPINDEX}", "value_type": 0, "delay": "5m", "preprocessing": [PREP_CHANGE]},
        {"name": base + "Inbound packets discarded", "key_": "net.if.in.discards[ifInDiscards.{#SNMPINDEX}]", "type": 20,
         "snmp_oid": "1.3.6.1.2.1.2.2.1.13.{#SNMPINDEX}", "value_type": 0, "delay": "5m", "preprocessing": [PREP_CHANGE]},
        {"name": base + "Outbound packets discarded", "key_": "net.if.out.discards[ifOutDiscards.{#SNMPINDEX}]", "type": 20,
         "snmp_oid": "1.3.6.1.2.1.2.2.1.19.{#SNMPINDEX}", "value_type": 0, "delay": "5m", "preprocessing": [PREP_CHANGE]},
    ])
    ok("Descoberta de portas: tráfego, estado, velocidade, erros e descartes" + (" (%d itens novos no template)" % n if n else ""))

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
    ok("Descoberta de placas: CPU, temperatura%s" % (" e memória" if mem_ok else " (memória não respondeu)") + (" (%d itens novos)" % n if n else ""))

    # 5. hosts
    hostids = []
    for o in OLTS:
        r = api.call("host.get", {"filter": {"host": [o["nome"]]}, "output": ["hostid"], "selectParentTemplates": ["templateid"]})
        if r:
            hid = r[0]["hostid"]
            if tid not in [t["templateid"] for t in r[0].get("parentTemplates", [])]:
                api.call("template.massadd", {"templates": [{"templateid": tid}], "hosts": [{"hostid": hid}]})
            macros = api.call("usermacro.get", {"hostids": [hid], "filter": {"macro": ["{$SNMP_COMMUNITY}"]}, "output": ["hostmacroid"]})
            if macros:
                api.call("usermacro.update", {"hostmacroid": macros[0]["hostmacroid"], "value": comunidade, "type": 1})
            else:
                api.call("usermacro.create", {"hostid": hid, "macro": "{$SNMP_COMMUNITY}", "value": comunidade, "type": 1})
            info("Host %s já existia: template e comunidade conferidos" % o["nome"])
        else:
            hid = api.call("host.create", {
                "host": o["nome"], "name": o["nome"], "groups": [{"groupid": gid}], "templates": [{"templateid": tid}],
                "interfaces": [{"type": 2, "main": 1, "useip": 1, "ip": o["ip"], "dns": "", "port": o.get("port", "161"),
                                "details": {"version": 2, "bulk": 1, "community": "{$SNMP_COMMUNITY}"}}],
                "macros": [{"macro": "{$SNMP_COMMUNITY}", "value": comunidade, "type": 1}],
                "tags": [{"tag": "painel", "value": "olt"}],
            })["hostids"][0]
            ok("Host %s criado (%s)" % (o["nome"], o["ip"]))
        hostids.append(hid)
    comunidade = None

    regras = api.call("discoveryrule.get", {"hostids": hostids, "output": ["itemid"]}) or []
    if regras:
        try:
            api.call("task.create", [{"type": 6, "request": {"itemid": r["itemid"]}} for r in regras])
            ok("Descoberta de portas e placas disparada agora")
        except ZbxError as e:
            aviso("Não deu para disparar a descoberta agora (%s); ela roda sozinha em até 10 min." % e)

    # 6. usuário e token de leitura para o painel
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
    ok("Usuário %s (somente leitura no grupo %s) com token de API novo" % (PANEL_USER, HOST_GROUP))

    # confere o token como o painel vai usar
    try:
        teste = Api(LOCAL_URL, token).call("host.get", {"output": ["name"], "groupids": [gid]})
        ok("Token testado: enxerga %d host(s) — %s" % (len(teste), ", ".join(h["name"] for h in teste)))
    except ZbxError as e:
        aviso("O token não conseguiu ler os hosts: %s" % e)

    # 7. primeiros dados
    info("Esperando os primeiros dados das portas (até 4 min)…")
    fim = time.time() + 240
    com_dados = 0
    while time.time() < fim:
        its = api.call("item.get", {"hostids": hostids, "search": {"key_": "net.if.in["}, "output": ["lastclock"]}) or []
        com_dados = sum(1 for i in its if str(i.get("lastclock", "0")) not in ("0", ""))
        print("\r  portas descobertas: %d · com dados: %d   " % (len(its), com_dados), end="", flush=True)
        if its and com_dados >= len(its) * 0.8:
            break
        time.sleep(15)
    print()
    if com_dados:
        ok("Dados chegando no Zabbix da UpDown")
    else:
        aviso("Ainda sem dados. Pode ser só a primeira coleta (até 10 min) ou o SNMP bloqueado; veja Monitoramento → Hosts.")

    os.makedirs(STATE_DIR, exist_ok=True)
    with open(os.path.join(STATE_DIR, "zabbix-olts.json"), "w", encoding="utf-8") as f:
        json.dump({"temp_base": temp_base, "mem": mem_ok, "url": LOCAL_URL, "hosts": [o["nome"] for o in OLTS]}, f, indent=2)

    # 8. troca do painel
    url_painel = LOCAL_URL
    if com_dados or pergunta("Trocar o painel para este Zabbix mesmo sem dados ainda?"):
        if trocar_nginx(url_painel, token):
            ok("Painel apontado para o Zabbix da UpDown")
    else:
        info("Painel continua no Zabbix da LV. Rode o script de novo quando os dados chegarem.")

    print("\n" + "=" * 64)
    print("URL da API:  %s" % url_painel)
    print("Token:       %s" % token)
    print("=" * 64)
    print("O token já está no nginx do painel; guarde-o só se for usar em outro lugar.")
    print("Sondagem SNMP (memória e sinal óptico): %s" % PROBE_FILE)


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
        "        proxy_read_timeout 60s;\n"
        "    }" % (url, token)
    )
    novo, n = re.subn(r"location = /zbx-api \{.*?\n\s*\}", bloco, conf, count=1, flags=re.S)
    if not n:
        aviso("Não achei o bloco /zbx-api no nginx; troque à mão.")
        return False
    backup = NGINX_SITE + ".bak-lv-" + time.strftime("%Y%m%d-%H%M%S")
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
    info("Configuração anterior (Zabbix da LV) guardada em " + backup)
    info("Para voltar para a LV: cp %s %s && systemctl reload nginx" % (backup, NGINX_SITE))
    return True


if __name__ == "__main__":
    try:
        main()
    except ZbxError as e:
        falha("Erro na API do Zabbix: %s" % e)
    except KeyboardInterrupt:
        print()
        falha("Interrompido.")
