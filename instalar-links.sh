#!/usr/bin/env bash
# Instala o Monitoramento de Links (UpDown NOC) neste servidor.
#
#   bash instalar-links.sh
#
# O que faz:
#   1. instala o serviço painel-links em /opt/painel-links: ele lê o Zabbix da LV
#      e entrega ao painel só os números (o token nunca vai para o navegador)
#   2. guarda o token do Zabbix em /etc/painel-links/token (só root e www-data leem)
#   3. publica o painel em /var/www/painel-links
#   4. cria o site do nginx em https://monitoramento.updown.com.br:9443, com o
#      mesmo login do Painel das OLTs (quem já entrou na 8443 entra direto)
#
# Pode rodar de novo quando quiser: token, links.json e usuários são preservados.
# Outra porta:   PORTA=9444 bash instalar-links.sh
# Outro token:   TOKEN=xxxx bash instalar-links.sh
# Outro Zabbix:  ZABBIX_URL=https://.../api_jsonrpc.php bash instalar-links.sh
set -euo pipefail

DOMINIO="${DOMINIO:-monitoramento.updown.com.br}"
PORTA="${PORTA:-9443}"
PORTA_API="${PORTA_API:-8092}"
PORTA_LOGIN="${PORTA_LOGIN:-8091}"
ZABBIX_URL="${ZABBIX_URL:-http://127.0.0.1:19090/api_jsonrpc.php}"
SITE=/etc/nginx/sites-available/painel-links
SITE_OLT=/etc/nginx/sites-available/painel-olt
CONF=/etc/painel-links
APP=/opt/painel-links
WWW=/var/www/painel-links

ok()   { printf '\033[32m✔\033[0m %s\n' "$*"; }
info() { printf '\033[36m•\033[0m %s\n' "$*"; }
erro() { printf '\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- 0. conferências ----------
[ "$(id -u)" -eq 0 ] || erro "Rode como root."
command -v nginx >/dev/null || erro "nginx não está instalado."
command -v python3 >/dev/null || erro "python3 não encontrado."
command -v curl >/dev/null || erro "curl não encontrado (apt install -y curl)."
command -v ss >/dev/null || erro "ss não encontrado (apt install -y iproute2)."
[[ "$PORTA" =~ ^[0-9]+$ ]] && [ "$PORTA" -ge 1024 ] && [ "$PORTA" -le 65535 ] || erro "PORTA inválida: $PORTA"
case "$PORTA" in 8443|8080|80|443|19090|"$PORTA_API"|"$PORTA_LOGIN") erro "A porta $PORTA já é usada por outro serviço deste servidor. Use outra, por exemplo PORTA=9443.";; esac
[ -f "/etc/letsencrypt/live/$DOMINIO/fullchain.pem" ] || erro "Certificado de $DOMINIO não encontrado em /etc/letsencrypt/live."
NGV="$(nginx -V 2>&1)"
[[ "$NGV" == *http_auth_request_module* ]] || erro "Este nginx não tem o módulo auth_request (instale nginx-full ou nginx-extras)."
id www-data >/dev/null 2>&1 || erro "Usuário www-data não existe."
PY="$(command -v python3)"
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' || erro "Precisa de Python 3.7 ou mais novo."

code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORTA_LOGIN/sessao" || true)"
[ "$code" = "200" ] || erro "O login do Painel das OLTs (painel-auth, 127.0.0.1:$PORTA_LOGIN) não respondeu. Ele precisa estar instalado e rodando: systemctl status painel-auth"
ok "Login do Painel das OLTs respondendo; o painel de links vai usar os mesmos usuários."

porta_em_uso() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }
if porta_em_uso "$PORTA"; then
  if [ -f "$SITE" ] && grep -q "listen $PORTA ssl" "$SITE" && ss -Hltnp "sport = :$PORTA" 2>/dev/null | grep -q nginx; then
    info "A porta $PORTA já é deste painel (reinstalação)."
  else
    ss -Hltnp "sport = :$PORTA" 2>/dev/null || true
    erro "A porta $PORTA já está em uso. Escolha outra: PORTA=9444 bash $0"
  fi
fi
if porta_em_uso "$PORTA_API" && ! systemctl is-active --quiet painel-links 2>/dev/null; then
  ss -Hltnp "sport = :$PORTA_API" 2>/dev/null || true
  erro "A porta interna $PORTA_API já está em uso. Escolha outra: PORTA_API=8093 bash $0"
fi

# ---------- 1. token do Zabbix ----------
ULTIMA_RESP=""
testa_token() {
  local t="$1" h r
  [[ "$t" =~ ^[A-Za-z0-9]{16,}$ ]] || return 1
  h="$(mktemp)"; chmod 600 "$h"
  printf 'Authorization: Bearer %s\nContent-Type: application/json-rpc\n' "$t" > "$h"
  r="$(curl -sS --noproxy '*' -m 25 -H @"$h" -d '{"jsonrpc":"2.0","method":"host.get","params":{"output":["hostid"],"search":{"name":"UPT"},"limit":1},"id":1}' "$ZABBIX_URL" 2>&1 || true)"
  rm -f "$h"
  ULTIMA_RESP="$r"
  [[ "$r" == *'"result"'* ]]
}
URL_SALVA="$( [ -s "$CONF/zabbix_url" ] && tr -d '[:space:]' < "$CONF/zabbix_url" || true)"
TOKEN_OK=""
if [ -n "${TOKEN:-}" ]; then
  testa_token "$TOKEN" && { TOKEN_OK="$TOKEN"; ORIGEM="informado"; }
fi
# o token salvo só vale se for do mesmo Zabbix (o antigo era o da LV)
if [ -z "$TOKEN_OK" ] && [ -s "$CONF/token" ] && [ "$URL_SALVA" = "$ZABBIX_URL" ]; then
  t="$(tr -d '[:space:]' < "$CONF/token")"; testa_token "$t" && { TOKEN_OK="$t"; ORIGEM="já salvo em $CONF/token"; }
fi
if [ -z "$TOKEN_OK" ] && [ -f "$SITE_OLT" ]; then
  for t in $(grep -oP 'Bearer \K[A-Za-z0-9]+' "$SITE_OLT" | sort -u || true); do
    testa_token "$t" && { TOKEN_OK="$t"; ORIGEM="o mesmo do Painel das OLTs"; break; }
  done
fi
if [ -z "$TOKEN_OK" ]; then
  read -rsp "Token da API do Zabbix ($ZABBIX_URL) — não aparece na tela: " t; echo
  testa_token "$t" && { TOKEN_OK="$t"; ORIGEM="digitado"; }
fi
if [ -z "$TOKEN_OK" ]; then
  echo "   Resposta: ${ULTIMA_RESP:0:300}"
  erro "O Zabbix em $ZABBIX_URL recusou o token ou não respondeu. Rode de novo com TOKEN=... bash $0"
fi
TOKEN="$TOKEN_OK"
ok "Zabbix $ZABBIX_URL aceitou o token ($ORIGEM)."

# ---------- 2. serviço ----------
install -d -m 755 "$APP"
cat > "$APP/painel-links.py" <<'__PAINEL_LINKS_PY__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Monitoramento de Links - UpDown NOC

Servico pequeno, so com a biblioteca padrao do Python 3, que consulta o Zabbix
da LV Network e entrega ao painel um JSON compacto. O token do Zabbix fica
neste servidor (/etc/painel-links/token) e nunca vai para o navegador; o nginx
so deixa chegar aqui quem tem sessao valida no login do painel (painel-auth).

  painel-links.py serve     roda o servico (o systemd chama isto)
  painel-links.py testar    confere o token e mostra o que foi achado no Zabbix
  painel-links.py init      cria a pasta e o links.json padrao (o instalador usa)

Os links ficam em /etc/painel-links/links.json. Ao salvar o arquivo, o servico
rele sozinho em ate 30 s (nao precisa reiniciar).
"""
import copy
import json
import math
import os
import re
import ssl
import sys
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = os.environ.get("PAINEL_LINKS_DIR", "/etc/painel-links")
TOKEN_FILE = os.path.join(DIR, "token")
CONFIG_FILE = os.path.join(DIR, "links.json")
ZABBIX_URL = os.environ.get("ZABBIX_URL", "https://zbx7.lv.network/api_jsonrpc.php")
LISTEN = ("127.0.0.1", int(os.environ.get("PAINEL_LINKS_PORT", "8092")))
TLS_VERIFY = os.environ.get("ZABBIX_TLS_VERIFY", "1") != "0"

RAPIDO_SEG = 20          # trafego, estado e velocidade das portas
HIST_SEG = 60            # historico dos graficos pequenos
OPTICO_SEG = 60          # RX/TX (a LV coleta a cada 5 min)
ERROS_SEG = 120          # erros e descartes da ultima hora
DESCOBERTA_SEG = 1800    # rele a lista de itens do Zabbix
CONFIG_SEG = 30          # confere se o links.json mudou
JANELA_SPARK = 6 * 3600
PASSO_SPARK = 300
PONTOS_GRAFICO = 180

PERIODOS = {"1h": 3600, "6h": 6 * 3600, "24h": 86400, "7d": 7 * 86400, "30d": 30 * 86400}

X = "XGigabitEthernet0/0/"
G = "GigabitEthernet0/1/"

DEFAULT_CONFIG = {
    "_leia": [
        "Links do Monitoramento de Links (UpDown NOC). Salve e o painel rele em ate 30 s.",
        "Porta: [EQUIPAMENTO, interface] ou [EQUIPAMENTO, interface, rotulo da rota].",
        "trafego: portas somadas para entrada/saida. membros: portas fisicas de um Eth-Trunk",
        "(estado, erros, RX/TX e capacidade). outra_ponta: o outro lado do enlace (estado, erros, RX/TX).",
        "capacidade_gbps: forca a capacidade. rx_alarme / rx_aviso: limite proprio de RX em dBm.",
    ],
    "filtro_host": "UPT",
    "equipamentos": {
        "S6750_ASC": {"zabbix": "SWITCH01 S6750 ASCENTY", "sigla": "ASC", "nome": "S6750 Ascenty"},
        "S6730_ASC": {"zabbix": "SWITCH02 S6730 ASCENTY", "sigla": "ASC2", "nome": "S6730 Ascenty"},
        "S6750_PG": {"zabbix": "SWITCH S6750 PRAIA GRANDE", "sigla": "PG", "nome": "S6750 Praia Grande"},
        "S6730_PG2": {"zabbix": "SWITCH S6730 PRAIA GRANDE 2", "sigla": "PG2", "nome": "S6730 Praia Grande"},
        "S6730_SANTOS": {"zabbix": "SWITCH S6730 SANTOS", "sigla": "STS", "nome": "S6730 Santos"},
        "S6730_RB": {"zabbix": "SWITCH S6730 RIO BRANCO SV", "sigla": "RB", "nome": "S6730 Rio Branco"},
        "NE8000_CUB": {"zabbix": "NE8000 F1A PPPOE BASE", "sigla": "CUB", "nome": "NE8000 Cubatão"},
        "NE8000_VS": {"zabbix": "NE8000 F1A VS BGP BASE", "sigla": "VS", "nome": "NE8000 VS BGP"},
    },
    "limites": {
        "uso_atencao": 70, "uso_critico": 90,
        "erros_atencao": 1, "erros_critico": 1000,
        "optico_margem_db": 2,
        "dado_velho_seg": 300,
    },
    "totais": [
        {"id": "transito", "nome": "Trânsito", "detalhe": "IX.br + PNIs", "links": ["ixbr", "google", "globo"]},
        {"id": "ip", "nome": "IP", "detalhe": "Mega + Seaborn", "links": ["mega", "seaborn"]},
        {"id": "isp", "nome": "Clientes ISP", "detalhe": "saída = para o cliente", "secao": "isp"},
    ],
    "secoes": [
        {
            "id": "upstream", "titulo": "Trânsito e peering", "detalhe": "entrada = vindo do parceiro",
            "links": [
                {"id": "ixbr", "nome": "IX.br", "trafego": [["S6750_ASC", "100GE1/0/9"]]},
                {"id": "google", "nome": "PNI Google", "trafego": [["S6750_ASC", "Eth-Trunk40"]],
                 "membros": [["S6750_ASC", "100GE1/0/19"]]},
                {"id": "globo", "nome": "PNI Globo", "trafego": [["S6730_ASC", "Eth-Trunk99"]],
                 "membros": [["S6730_ASC", X + "1"]]},
                {"id": "mega", "nome": "IP Mega", "trafego": [["S6750_ASC", "100GE1/0/16"]]},
                {"id": "seaborn", "nome": "Seaborn", "trafego": [["S6750_PG", "Eth-Trunk0"]],
                 "membros": [["S6750_PG", "100GE1/0/11"], ["S6750_PG", "100GE1/0/12"]]},
            ],
        },
        {
            "id": "transporte", "titulo": "Transporte", "detalhe": "DWDM Ascenty ⇄ Praia Grande",
            "links": [
                {"id": "dwdm-datacom", "nome": "DWDM Datacom", "local": "Ascenty ⇄ Praia Grande",
                 "trafego": [["S6750_ASC", "100GE1/0/%d" % n] for n in (29, 30, 31, 32)],
                 "outra_ponta": [["S6750_PG", "100GE1/0/%d" % n] for n in (29, 30, 31, 32)]},
                {"id": "dwdm-nokia", "nome": "DWDM Nokia", "local": "Ascenty ⇄ Praia Grande",
                 "trafego": [["S6750_ASC", "100GE1/0/%d" % n] for n in (33, 34, 35, 36)],
                 "outra_ponta": [["S6750_PG", "100GE1/0/%d" % n] for n in (33, 34, 35, 36)]},
            ],
        },
        {
            "id": "anel", "titulo": "Anel", "detalhe": "tráfego medido na 1ª ponta", "rx_alarme": -13,
            "links": [
                {"id": "cub-pg", "nome": "Cubatão ⇄ Praia Grande", "rx_alarme": -26,
                 "trafego": [["NE8000_CUB", "100GE0/1/50"]], "outra_ponta": [["S6750_PG", "100GE1/0/6"]]},
                {"id": "cub-sts", "nome": "Cubatão ⇄ Santos",
                 "trafego": [["NE8000_CUB", "100GE0/1/49"]], "outra_ponta": [["S6730_SANTOS", "100GE0/0/1"]]},
                {"id": "cub-rb", "nome": "Cubatão ⇄ Rio Branco",
                 "trafego": [["NE8000_CUB", "100GE0/1/48"]], "outra_ponta": [["S6730_RB", "100GE0/0/2"]]},
                {"id": "sts-pg", "nome": "Santos ⇄ Praia Grande",
                 "trafego": [["S6730_SANTOS", "100GE0/0/2"]], "outra_ponta": [["S6750_PG", "100GE1/0/2"]]},
                {"id": "sts-rb", "nome": "Santos ⇄ Rio Branco",
                 "trafego": [["S6730_SANTOS", "100GE0/0/3"]], "outra_ponta": [["S6730_RB", "100GE0/0/3"]]},
                {"id": "rb-pg", "nome": "Rio Branco ⇄ Praia Grande",
                 "trafego": [["S6730_RB", "100GE0/0/1"]], "outra_ponta": [["S6750_PG", "100GE1/0/1"]]},
            ],
        },
        {
            "id": "olt", "titulo": "OLT", "detalhe": "Central (C350) e Casqueiro (C300)",
            "links": [
                {"id": "olt-central", "nome": "OLT Central", "local": "C350 · NE8000",
                 "trafego": [["NE8000_CUB", G + "4"], ["NE8000_CUB", G + "5"], ["NE8000_CUB", G + "20"]]},
                {"id": "olt-casqueiro", "nome": "OLT Casqueiro", "local": "C300",
                 "trafego": [["NE8000_CUB", G + "12", "Cubatão"], ["S6730_SANTOS", X + "23", "Santos"]]},
            ],
        },
        {
            "id": "isp", "titulo": "Clientes ISP", "detalhe": "saída = para o cliente",
            "links": [
                {"id": "wsnet", "nome": "WSNET", "trafego": [["S6750_PG", "Eth-Trunk1"]],
                 "membros": [["S6750_PG", "100GE1/0/3"], ["S6750_PG", "100GE1/0/4"]]},
                {"id": "microchipnet", "nome": "Microchipnet", "trafego": [["S6730_SANTOS", "Eth-Trunk60"]],
                 "membros": [["S6730_SANTOS", X + str(n)] for n in (7, 8, 9, 10)]},
                {"id": "kobertura", "nome": "Kobertura",
                 "trafego": [["S6730_ASC", X + "4", "Ufinet"], ["S6730_ASC", X + "5", "Telium"]]},
                {"id": "netfree", "nome": "Netfree", "trafego": [["S6730_PG2", "Eth-Trunk60"]],
                 "membros": [["S6730_PG2", X + "3"], ["S6730_PG2", X + "4"]]},
                {"id": "it-facilities", "nome": "IT Facilities",
                 "trafego": [["S6730_SANTOS", X + "3", "Santos"], ["S6730_RB", X + "3", "Rio Branco"]]},
                {"id": "conexao-net", "nome": "Conexão Net", "trafego": [["S6730_SANTOS", "Eth-Trunk70"]],
                 "membros": [["S6730_SANTOS", X + "5"], ["S6730_SANTOS", X + "6"]]},
                {"id": "ghost", "nome": "Ghost", "trafego": [["NE8000_VS", G + "8"]]},
                {"id": "nex-telecom", "nome": "NEX Telecom",
                 "trafego": [["S6730_SANTOS", X + "4", "Santos"], ["S6730_RB", X + "4", "Rio Branco"]]},
                {"id": "manalink", "nome": "Manalink", "trafego": [["NE8000_CUB", "Eth-Trunk1"]],
                 "membros": [["NE8000_CUB", G + "2"], ["NE8000_CUB", G + "3"]]},
                {"id": "meles-conect", "nome": "Meles Conect", "trafego": [["S6730_SANTOS", X + "12"]]},
                {"id": "celerix", "nome": "Celerix", "trafego": [["NE8000_CUB", G + "21"]]},
            ],
        },
    ],
}

# chave do item no Zabbix -> o que ele mede
TIPOS = [
    ("in", re.compile(r"^net\.if\.in\[ifHCInOctets\.")),
    ("out", re.compile(r"^net\.if\.out\[ifHCOutOctets\.")),
    ("in32", re.compile(r"^net\.if\.in\[ifInOctets\.")),
    ("out32", re.compile(r"^net\.if\.out\[ifOutOctets\.")),
    ("errIn", re.compile(r"^net\.if\.in\.errors\[")),
    ("errOut", re.compile(r"^net\.if\.out\.errors\[")),
    ("discIn", re.compile(r"^net\.if\.in\.discards\[")),
    ("discOut", re.compile(r"^net\.if\.out\.discards\[")),
    ("status", re.compile(r"^net\.if\.status\[")),
    ("speed", re.compile(r"^net\.if\.speed\[ifHighSpeed\.")),
    ("speed32", re.compile(r"^net\.if\.speed\[ifSpeed\.")),
    ("rx", re.compile(r"^hwEntityOpticalRxPower(Lane\d+)?\[")),
    ("tx", re.compile(r"^hwEntityOpticalTxPower(Lane\d+)?\[")),
    ("rxLA", re.compile(r"^hwEntityOpticalRxLowThreshold\[")),
    ("rxLW", re.compile(r"^hwEntityOpticalRxLowWarnThreshold\[")),
    ("rxHA", re.compile(r"^hwEntityOpticalRxHighThreshold\[")),
    ("rxHW", re.compile(r"^hwEntityOpticalRxHighWarnThreshold\[")),
    ("txLA", re.compile(r"^hwEntityOpticalTxLowThreshold\[")),
    ("txLW", re.compile(r"^hwEntityOpticalTxLowWarnThreshold\[")),
    ("txHA", re.compile(r"^hwEntityOpticalTxHighThreshold\[")),
    ("txHW", re.compile(r"^hwEntityOpticalTxHighWarnThreshold\[")),
]
RAPIDOS = ("in", "out", "in32", "out32", "status", "speed", "speed32")
ERROS = ("errIn", "errOut", "discIn", "discOut")
OPTICOS = ("rx", "tx", "rxLA", "rxLW", "rxHA", "rxHW", "txLA", "txLW", "txHA", "txHW")
SEVERIDADE = {"ok": 0, "sem-dados": 1, "atencao": 2, "critico": 3, "degradado": 4, "fora": 5}
NIVEL = {None: -1, "ok": 0, "aviso": 1, "alarme": 2}


def log(msg):
    sys.stderr.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    sys.stderr.flush()


class ZabbixErro(Exception):
    pass


class Zabbix:
    def __init__(self, url, token):
        self.url = url
        self.token = token
        self.seq = 0
        self.lock = threading.Lock()
        if TLS_VERIFY:
            self.ctx = ssl.create_default_context()
        else:
            self.ctx = ssl._create_unverified_context()

    def call(self, method, params, auth=True, timeout=40):
        with self.lock:
            self.seq += 1
            seq = self.seq
        body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": seq}).encode("utf-8")
        req = urllib.request.Request(self.url, data=body, method="POST", headers={
            "Content-Type": "application/json-rpc",
            "User-Agent": "painel-links/1.0 (UpDown NOC)",
        })
        if auth:
            req.add_header("Authorization", "Bearer " + self.token)
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=self.ctx) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            raise ZabbixErro("HTTP %d em %s" % (e.code, method))
        except urllib.error.URLError as e:
            raise ZabbixErro("sem conexão com o Zabbix (%s)" % (e.reason,))
        except (TimeoutError, OSError) as e:
            raise ZabbixErro("sem conexão com o Zabbix (%s)" % (e,))
        try:
            data = json.loads(raw.decode("utf-8"))
        except ValueError:
            raise ZabbixErro("resposta do Zabbix não é JSON (%s)" % method)
        if data.get("error"):
            err = data["error"]
            raise ZabbixErro("%s: %s %s" % (method, err.get("message", ""), err.get("data", "")))
        return data.get("result")

    def historico(self, itens, t0, t1, campos=("itemid", "clock", "value")):
        """history.get agrupado por tipo de valor. itens: [{'id','vt'}]."""
        por_vt = {}
        for it in itens:
            por_vt.setdefault(it["vt"], []).append(it["id"])
        linhas = []
        for vt, ids in por_vt.items():
            for i in range(0, len(ids), 200):
                linhas += self.call("history.get", {
                    "output": list(campos), "history": int(vt), "itemids": ids[i:i + 200],
                    "time_from": int(t0), "time_till": int(t1),
                    "sortfield": "clock", "sortorder": "ASC",
                }) or []
        return linhas

    def tendencia(self, itens, t0, t1):
        ids = [it["id"] for it in itens]
        linhas = []
        for i in range(0, len(ids), 200):
            linhas += self.call("trend.get", {
                "output": ["itemid", "clock", "num", "value_min", "value_avg", "value_max"],
                "itemids": ids[i:i + 200], "time_from": int(t0), "time_till": int(t1),
            }) or []
        return linhas


# ---------------- utilidades ----------------

def norm_nome(nome):
    return re.sub(r"\s+", " ", str(nome).split("|")[-1]).strip().upper()


NOME_ITEM = re.compile(r"^Interface\s+(.+?):\s")
COM_ALIAS = re.compile(r"^(.*?)\((.*)\)$")


def ler_nome_item(nome):
    m = NOME_ITEM.match(str(nome))
    if not m:
        return None, ""
    rotulo = m.group(1)
    a = COM_ALIAS.match(rotulo)
    if a:
        return a.group(1).strip(), a.group(2).strip()
    return rotulo.strip(), ""


def segundos(delay, padrao=60):
    m = re.match(r"^\s*(\d+)\s*([smhdw]?)", str(delay or "").split(";")[0])
    if not m:
        return padrao
    n = int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}[m.group(2)]
    return n or padrao


def modo_contador(preproc):
    tipos = [str(p.get("type")) for p in (preproc or [])]
    hb = 0
    for p in preproc or []:
        if str(p.get("type")) == "20":  # descarta repetidos com heartbeat
            hb = segundos(p.get("params"), 0)
    if "10" in tipos:
        return "cps", hb   # mudança por segundo
    if "9" in tipos:
        return "delta", hb  # mudança simples
    return "bruto", hb


def contar(linhas, modo, delay, hb, t0, t1):
    """Quantos erros/descartes houve entre t0 e t1, a partir das amostras."""
    if not linhas:
        return 0
    if modo == "delta":
        return int(round(sum(v for c, v in linhas if t0 <= c <= t1 and v > 0)))
    if modo == "bruto":
        total, ant = 0.0, None
        for c, v in linhas:
            if ant is not None and c >= t0 and v >= ant:
                total += v - ant
            ant = v
        return int(round(total))
    segura = max(hb, delay * 2)
    total = 0.0
    for i, (c, v) in enumerate(linhas):
        fim = linhas[i + 1][0] if i + 1 < len(linhas) else t1
        fim = min(fim, c + segura, t1)
        ini = max(c, t0)
        if fim > ini and v > 0:
            total += v * (fim - ini)
    return int(round(total))


def contar_tendencia(linhas, modo, delay):
    total = 0.0
    for r in linhas:
        num = float(r.get("num") or 0)
        avg = float(r.get("value_avg") or 0)
        if modo == "cps":
            total += max(avg, 0) * num * delay
        elif modo == "delta":
            total += max(avg, 0) * num
        else:
            total += max(float(r.get("value_max") or 0) - float(r.get("value_min") or 0), 0)
    return int(round(total))


def soma_por_minuto(series, t0, n, ffill=180):
    """Soma várias séries [(clock, valor)] em baldes de 1 min a partir de t0."""
    tot = [None] * n
    lim = ffill // 60
    for s in series:
        arr = [None] * n
        antes = None
        for c, v in s:
            i = int((c - t0) // 60)
            if i < 0:
                antes = (i, v)
            elif i < n:
                arr[i] = v
        ult, ult_i = (antes[1], antes[0]) if antes else (None, -10 ** 9)
        for i in range(n):
            if arr[i] is not None:
                ult, ult_i = arr[i], i
            elif ult is not None and i - ult_i <= lim:
                arr[i] = ult
        for i in range(n):
            if arr[i] is not None:
                tot[i] = (tot[i] or 0) + arr[i]
    return tot


def reduzir_max(vals, k):
    if k <= 1:
        return list(vals)
    out = []
    for i in range(0, len(vals), k):
        bloco = [v for v in vals[i:i + k] if v is not None]
        out.append(max(bloco) if bloco else None)
    return out


def arred(v):
    return None if v is None else int(round(v))


# ---------------- coletor ----------------

class Coletor:
    def __init__(self, zbx):
        self.zbx = zbx
        self.cfg = None
        self.cfg_mtime = None
        self.cfg_erro = None
        self.hosts = {}       # EQUIP -> hostid
        self.hosts_nome = {}  # hostid -> nome no Zabbix
        self.portas = {}      # (EQUIP, interface) -> porta
        self.ult = {}         # itemid -> (valor, clock)
        self.hist = {}        # itemid -> {clock: valor}
        self.erros1h = {}     # itemid -> contagem
        self.escala = {}      # hostid -> 1 ou 100 (correção dos S6750)
        self.hist_ate = 0     # até quando o histórico já foi lido
        self.prox = {}
        self.descoberto = False
        self.zbx_ok = None
        self.zbx_erro = None
        self.zbx_ultimo_ok = 0
        self.zbx_versao = None
        self.snapshot = json.dumps({"carregando": True}).encode("utf-8")
        self.cache_det = {}
        self.lock = threading.Lock()

    # ----- configuração -----
    def carregar_config(self):
        try:
            mtime = os.path.getmtime(CONFIG_FILE)
        except OSError:
            mtime = None
        if self.cfg is not None and mtime == self.cfg_mtime:
            return False
        cfg = None
        if mtime is not None:
            try:
                with open(CONFIG_FILE, encoding="utf-8") as f:
                    cfg = json.load(f)
                validar_config(cfg)
                self.cfg_erro = None
            except Exception as e:  # noqa
                self.cfg_erro = "links.json inválido: %s" % e
                log(self.cfg_erro)
                if self.cfg is not None:
                    self.cfg_mtime = mtime
                    return False
                cfg = None
        if cfg is None:
            cfg = copy.deepcopy(DEFAULT_CONFIG)
        lim = dict(DEFAULT_CONFIG["limites"])
        lim.update(cfg.get("limites") or {})
        cfg["limites"] = lim
        self.cfg = cfg
        self.cfg_mtime = mtime
        self.descoberto = False
        self.cache_det = {}
        return True

    def todas_portas_cfg(self):
        for sec in self.cfg["secoes"]:
            for d in sec["links"]:
                for papel in ("trafego", "membros", "outra_ponta"):
                    for p in d.get(papel) or []:
                        yield p[0], p[1]

    # ----- descoberta -----
    def descobrir(self):
        if self.zbx_versao is None:
            try:
                self.zbx_versao = self.zbx.call("apiinfo.version", {}, auth=False)
            except ZabbixErro:
                pass
        eqs = self.cfg["equipamentos"]
        filtro = str(self.cfg.get("filtro_host") or "").strip()
        params = {"output": ["hostid", "name"]}
        if filtro:
            params["search"] = {"name": filtro}
        hosts = self.zbx.call("host.get", params) or []
        por_nome = {}
        for h in hosts:
            prefixo = str(h["name"]).split("|")[0] if "|" in str(h["name"]) else ""
            if filtro and "|" in str(h["name"]) and filtro.upper() not in prefixo.upper():
                continue
            por_nome.setdefault(norm_nome(h["name"]), []).append(h)
        self.hosts, self.hosts_nome = {}, {}
        for chave, e in eqs.items():
            cands = por_nome.get(norm_nome(e["zabbix"])) or []
            if len(cands) > 1:
                log("atenção: %d hosts chamados %s; usando o primeiro" % (len(cands), e["zabbix"]))
            if cands:
                h = cands[0]
                self.hosts[chave] = str(h["hostid"])
                self.hosts_nome[str(h["hostid"])] = h["name"]
        quer = {}
        for eq, ifn in self.todas_portas_cfg():
            if eq in self.hosts:
                quer.setdefault(self.hosts[eq], set()).add(ifn)
        portas = {}
        for eq, ifn in self.todas_portas_cfg():
            portas[(eq, ifn)] = {"eq": eq, "if": ifn, "hostid": self.hosts.get(eq), "alias": "", "itens": {}}
        hostid_eq = {}
        for eq, hid in self.hosts.items():
            hostid_eq.setdefault(hid, []).append(eq)
        for hid, ifs in quer.items():
            itens = self.zbx.call("item.get", {
                "output": ["itemid", "hostid", "name", "key_", "delay", "value_type", "lastvalue", "lastclock"],
                "selectPreprocessing": ["type", "params"],
                "hostids": [hid], "monitored": True,
                "search": {"name": ["Interface %s" % i for i in sorted(ifs)]},
                "searchByAny": True, "startSearch": True,
            }) or []
            for it in itens:
                if str(it.get("value_type")) not in ("0", "3"):
                    continue
                ifn, alias = ler_nome_item(it.get("name"))
                if ifn not in ifs:
                    continue
                tipo = None
                for t, rx in TIPOS:
                    if rx.match(it.get("key_", "")):
                        tipo = t
                        break
                if not tipo:
                    continue
                modo, hb = modo_contador(it.get("preprocessing"))
                lane = re.search(r"Lane(\d+)", it.get("key_", ""))
                reg = {"id": str(it["itemid"]), "vt": str(it["value_type"]), "delay": segundos(it.get("delay")),
                       "modo": modo, "hb": hb, "lane": int(lane.group(1)) if lane else None}
                for eq in hostid_eq.get(hid, []):
                    p = portas.get((eq, ifn))
                    if p is None:
                        continue
                    if alias and not p["alias"]:
                        p["alias"] = alias
                    p["itens"].setdefault(tipo, []).append(reg)
                if it.get("lastclock") and it.get("lastvalue") not in (None, ""):
                    try:
                        self.ult[reg["id"]] = (float(it["lastvalue"]), int(it["lastclock"]))
                    except ValueError:
                        pass
        for p in portas.values():
            for regs in p["itens"].values():
                regs.sort(key=lambda r: (r["lane"] is None, r["lane"] or 0))
        validos = set()
        for p in portas.values():
            for regs in p["itens"].values():
                for r in regs:
                    validos.add(r["id"])
        self.hist = {k: v for k, v in self.hist.items() if k in validos}
        self.portas = portas
        self.descoberto = True
        achadas = sum(1 for p in portas.values() if p["itens"])
        log("descoberta: %d equipamentos, %d de %d portas com itens" % (len(self.hosts), achadas, len(portas)))

    def ids(self, tipos, portas=None):
        out = []
        for p in (portas if portas is not None else self.portas.values()):
            for t in tipos:
                out += p["itens"].get(t, [])
        return out

    def portas_trafego(self):
        vistos, out = set(), []
        for sec in self.cfg["secoes"]:
            for d in sec["links"]:
                for e in d.get("trafego") or []:
                    k = (e[0], e[1])
                    if k in self.portas and k not in vistos:
                        vistos.add(k)
                        out.append(self.portas[k])
        return out

    # ----- leituras -----
    def ler_ultimos(self, regs):
        ids = sorted({r["id"] for r in regs})
        for i in range(0, len(ids), 500):
            for it in self.zbx.call("item.get", {"output": ["itemid", "lastvalue", "lastclock"],
                                                 "itemids": ids[i:i + 500]}) or []:
                if it.get("lastvalue") in (None, "") or not it.get("lastclock"):
                    continue
                try:
                    self.ult[str(it["itemid"])] = (float(it["lastvalue"]), int(it["lastclock"]))
                except ValueError:
                    pass

    def ler_hist(self, agora):
        regs = self.ids(("in", "out", "in32", "out32"), self.portas_trafego())
        if not regs:
            return
        inicio = agora - JANELA_SPARK - 600
        novos = [r for r in regs if r["id"] not in self.hist]
        velhos = [r for r in regs if r["id"] in self.hist]
        if novos:
            for r in novos:
                self.hist[r["id"]] = {}
            for row in self.zbx.historico(novos, inicio, agora):
                self.hist[str(row["itemid"])][int(row["clock"])] = float(row["value"])
        if velhos:
            desde = max(inicio, min(agora - HIST_SEG * 4, (self.hist_ate or agora) - 180))
            for row in self.zbx.historico(velhos, desde, agora):
                self.hist[str(row["itemid"])][int(row["clock"])] = float(row["value"])
        for k, h in self.hist.items():
            for c in [c for c in h if c < inicio]:
                del h[c]
        self.hist_ate = agora

    def ler_erros(self, agora):
        regs = self.ids(ERROS)
        if not regs:
            return
        linhas = {}
        for row in self.zbx.historico(regs, agora - 3600 - 900, agora):
            linhas.setdefault(str(row["itemid"]), []).append((int(row["clock"]), float(row["value"])))
        novos = {}
        for r in regs:
            novos[r["id"]] = contar(sorted(linhas.get(r["id"], [])), r["modo"], r["delay"], r["hb"], agora - 3600, agora)
        self.erros1h = novos

    def ajustar_escala(self):
        """Os S6750 da LV dividem por 100 um valor que já vem em dBm (1,04 vira 0,0104)."""
        por_host = {}
        for p in self.portas.values():
            for t in ("rx", "tx"):
                for r in p["itens"].get(t, []):
                    if r["lane"] is None:
                        continue
                    u = self.ult.get(r["id"])
                    if u:
                        por_host.setdefault(p["hostid"], []).append(abs(u[0]))
        for hid, vals in por_host.items():
            self.escala[hid] = 100 if len(vals) >= 4 and max(vals) < 0.5 else 1

    # ----- cálculo -----
    def valor(self, p, tipos, agora=None, velho=None):
        for t in tipos:
            regs = p["itens"].get(t)
            if not regs:
                continue
            u = self.ult.get(regs[0]["id"])
            if not u:
                continue
            if velho and agora and agora - u[1] > velho:
                return None
            return u[0]
        return None

    def estado_porta(self, p):
        v = self.valor(p, ("status",))
        return None if v is None else int(v)

    def velocidade(self, p):
        v = self.valor(p, ("speed",))
        if not v:
            v = self.valor(p, ("speed32",))
        return v or None

    def limites_opticos(self, p, d, esc, rx_alarme=None, rx_aviso=None):
        def g(t):
            regs = p["itens"].get(d + t)
            u = self.ult.get(regs[0]["id"]) if regs else None
            return u[0] if u else None
        la, lw, hw, ha = g("LA"), g("LW"), g("HW"), g("HA")
        if esc != 1 and la is not None and ha is not None and abs(la) < 1 and abs(ha) < 1:
            la, ha = la * esc, ha * esc
            lw = lw * esc if lw is not None else None
            hw = hw * esc if hw is not None else None
        m = float(self.cfg["limites"].get("optico_margem_db", 2))
        if la is not None and ha is not None and ha > la:
            if lw is None or hw is None or (lw == 0 and hw == 0) or not (la <= lw < hw <= ha):
                lw, hw = la + m, ha - m
        else:
            la = lw = hw = ha = None
        if d == "rx" and rx_alarme is not None:
            la = float(rx_alarme)
            lw = float(rx_aviso) if rx_aviso is not None else None
        return la, lw, hw, ha

    @staticmethod
    def nivel(v, lim):
        if v is None:
            return None
        la, lw, hw, ha = lim
        if (la is not None and v < la) or (ha is not None and v > ha):
            return "alarme"
        if (lw is not None and v < lw) or (hw is not None and v > hw):
            return "aviso"
        return "ok" if (la is not None or ha is not None) else None

    def optica_porta(self, p, rx_alarme, rx_aviso):
        esc = self.escala.get(p["hostid"], 1)
        res = {}
        for d in ("rx", "tx"):
            regs = p["itens"].get(d) or []
            if not regs:
                continue
            lim = self.limites_opticos(p, d, esc, rx_alarme, rx_aviso)
            lanes = []
            for r in regs:
                u = self.ult.get(r["id"])
                if not u:
                    continue
                v = u[0] * (esc if r["lane"] is not None else 1)
                lanes.append({"lane": r["lane"], "v": round(v, 2), "nivel": self.nivel(v, lim)})
            if not lanes:
                continue
            pior = sorted(lanes, key=lambda x: (-NIVEL[x["nivel"]], x["v"]))[0]
            res[d] = {"v": pior["v"], "nivel": pior["nivel"], "lane": pior["lane"],
                      "lim": [None if x is None else round(x, 2) for x in lim],
                      "lanes": lanes if len(lanes) > 1 else None}
        return res

    def info_porta(self, p, papel, rotulo, agora, rx_alarme, rx_aviso, erros24=None):
        eqd = self.cfg["equipamentos"].get(p["eq"], {})
        st = self.estado_porta(p)
        velho = self.cfg["limites"]["dado_velho_seg"]
        out = {
            "papel": papel, "eq": p["eq"], "sigla": eqd.get("sigla", p["eq"]), "equip": eqd.get("nome", p["eq"]),
            "if": p["if"], "alias": p["alias"], "rotulo": rotulo,
            "achada": bool(p["itens"]), "status": st,
            "speed": arred(self.velocidade(p)),
            "in": arred(self.valor(p, ("in", "in32"), agora, velho)),
            "out": arred(self.valor(p, ("out", "out32"), agora, velho)),
            "erros1h": sum(self.erros1h.get(r["id"], 0) for r in self.ids(("errIn", "errOut"), [p])),
            "desc1h": sum(self.erros1h.get(r["id"], 0) for r in self.ids(("discIn", "discOut"), [p])),
            "optica": self.optica_porta(p, rx_alarme, rx_aviso),
        }
        if erros24 is not None:
            out["erros24h"] = sum(erros24.get(r["id"], 0) for r in self.ids(("errIn", "errOut"), [p]))
            out["desc24h"] = sum(erros24.get(r["id"], 0) for r in self.ids(("discIn", "discOut"), [p]))
        return out

    def def_portas(self, d):
        """(papel, porta, rotulo) de cada porta configurada no link."""
        out = []
        for papel in ("trafego", "membros", "outra_ponta"):
            for e in d.get(papel) or []:
                p = self.portas.get((e[0], e[1]))
                if p is None:
                    p = {"eq": e[0], "if": e[1], "hostid": None, "alias": "", "itens": {}}
                out.append((papel, p, e[2] if len(e) > 2 else None))
        return out

    def calc_link(self, d, sec, agora, erros24=None):
        L = self.cfg["limites"]
        velho = L["dado_velho_seg"]
        rx_alarme = d.get("rx_alarme", sec.get("rx_alarme"))
        rx_aviso = d.get("rx_aviso", sec.get("rx_aviso") if "rx_alarme" not in d else None)
        lista = self.def_portas(d)
        trafego = [p for papel, p, _ in lista if papel == "trafego"]
        membros = [p for papel, p, _ in lista if papel == "membros"]
        ponta = [p for papel, p, _ in lista if papel == "outra_ponta"]
        fisicas = [p for p in membros if p["itens"]] or trafego
        entrada = saida = None
        com_dado = 0
        for p in trafego:
            vi = self.valor(p, ("in", "in32"), agora, velho)
            vo = self.valor(p, ("out", "out32"), agora, velho)
            if vi is not None or vo is not None:
                com_dado += 1
                entrada = (entrada or 0) + (vi or 0)
                saida = (saida or 0) + (vo or 0)
        # capacidade: portas físicas (membros do trunk, se houver), só as que estão no ar
        cap_total = cap_ativa = 0
        fonte_cap = membros if any(p["itens"] for p in membros) else trafego
        for p in fonte_cap:
            s = self.velocidade(p) or 0
            cap_total += s
            if self.estado_porta(p) in (None, 1):
                cap_ativa += s
        if d.get("capacidade_gbps"):
            cap_total = cap_ativa = float(d["capacidade_gbps"]) * 1e9
        cap = cap_ativa or cap_total
        uso = None
        if cap and (entrada is not None or saida is not None):
            uso = round(max(entrada or 0, saida or 0) / cap * 100, 1)

        sigla = lambda p: "%s %s" % (self.cfg["equipamentos"].get(p["eq"], {}).get("sigla", p["eq"]), p["if"])
        estados = {}
        for grupo, ps in (("fisicas", fisicas), ("trafego", trafego), ("ponta", ponta)):
            estados[grupo] = [(p, self.estado_porta(p)) for p in ps if p["itens"]]
        todas = []
        vistos = set()
        for grupo in ("fisicas", "ponta"):
            for p, st in estados[grupo]:
                k = (p["eq"], p["if"])
                if k not in vistos:
                    vistos.add(k)
                    todas.append((p, st))
        fora_lista = [p for p, st in todas if st is not None and st != 1]
        conhecidas = [st for p, st in todas if st is not None]

        def todos_fora(grupo):
            sts = [st for p, st in estados[grupo] if st is not None]
            return bool(sts) and all(st != 1 for st in sts)

        motivos = []
        sev = "ok"

        def subir(novo, motivo):
            nonlocal sev
            if SEVERIDADE[novo] > SEVERIDADE[sev]:
                sev = novo
            motivos.append(motivo)

        achadas = [p for _, p, _ in lista if p["itens"]]
        if not achadas:
            estado = "nao-encontrado"
            motivos.append("Portas não encontradas no Zabbix")
        else:
            if todos_fora("fisicas") or todos_fora("trafego"):
                n = len([1 for p, st in estados["fisicas"] if st is not None]) or 1
                subir("fora", "Porta fora" if n == 1 else "Todas as %d portas fora" % n)
            elif ponta and todos_fora("ponta"):
                subir("fora", "Outra ponta fora (%s)" % ", ".join(sigla(p) for p, _ in estados["ponta"]))
            elif fora_lista:
                subir("degradado", "%d de %d portas fora: %s" % (
                    len(fora_lista), len(conhecidas), ", ".join(sigla(p) for p in fora_lista)))
            if com_dado == 0 and sev != "fora":
                subir("sem-dados", "Sem leitura de tráfego há mais de %d min" % (velho // 60))
            if uso is not None:
                if uso >= L["uso_critico"]:
                    subir("critico", "Uso em %s%%" % fmt_num(uso))
                elif uso >= L["uso_atencao"]:
                    subir("atencao", "Uso em %s%%" % fmt_num(uso))
        erros = desc = 0
        portas_info = []
        pior_opt = {}
        for papel, p, rotulo in lista:
            info = self.info_porta(p, papel, rotulo, agora, rx_alarme, rx_aviso, erros24)
            portas_info.append(info)
            conta = (papel == "membros") or (papel == "outra_ponta") or (papel == "trafego" and fisicas is trafego)
            if conta:
                erros += info["erros1h"]
                desc += info["desc1h"]
                for dd, o in info["optica"].items():
                    atual = pior_opt.get(dd)
                    if atual is None or (NIVEL[o["nivel"]], -o["v"]) > (NIVEL[atual["nivel"]], -atual["v"]):
                        pior_opt[dd] = dict(o, onde=sigla(p), lanes=None)
        if achadas:
            if erros >= L["erros_critico"]:
                subir("critico", "%s erros na última hora" % fmt_int(erros))
            elif erros >= L["erros_atencao"]:
                subir("atencao", "%s %s na última hora" % (fmt_int(erros), "erro" if erros == 1 else "erros"))
            for dd in ("rx", "tx"):
                o = pior_opt.get(dd)
                if o and o["nivel"] == "alarme":
                    subir("atencao", "%s %s dBm em %s" % (dd.upper(), fmt_dbm(o["v"]), o["onde"]))
            estado = sev
        primeira = trafego[0] if trafego else None
        if d.get("local"):
            local = d["local"]
        elif primeira is not None:
            eqd = self.cfg["equipamentos"].get(primeira["eq"], {})
            local = eqd.get("nome", primeira["eq"])
        else:
            local = ""
        ifs = [p["if"] for p in trafego]
        return {
            "id": d["id"], "nome": d.get("nome", d["id"]), "local": local,
            "interfaces": ifs if len(ifs) <= 2 else ["%d portas" % len(ifs)],
            "rotas": [r for _, _, r in lista if r] or None,
            "estado": estado, "motivos": motivos,
            "in": arred(entrada), "out": arred(saida),
            "cap": arred(cap), "cap_total": arred(cap_total), "uso": uso,
            "portas": {"up": len([1 for st in conhecidas if st == 1]), "total": len(conhecidas)},
            "erros1h": erros, "desc1h": desc,
            "optica": pior_opt,
            "_portas": portas_info,
        }

    def series_link(self, regs_in, regs_out, t0, n):
        def ser(regs):
            return [sorted(self.hist.get(r["id"], {}).items()) for r in regs if r["id"] in self.hist]
        return soma_por_minuto(ser(regs_in), t0, n), soma_por_minuto(ser(regs_out), t0, n)

    def regs_trafego(self, defs):
        rin, rout = [], []
        vistos = set()
        for d in defs:
            for e in d.get("trafego") or []:
                p = self.portas.get((e[0], e[1]))
                if p is None or (e[0], e[1]) in vistos:
                    continue
                vistos.add((e[0], e[1]))
                rin += (p["itens"].get("in") or p["itens"].get("in32") or [])[:1]
                rout += (p["itens"].get("out") or p["itens"].get("out32") or [])[:1]
        return rin, rout

    def spark(self, defs, agora):
        t1 = int(agora // PASSO_SPARK) * PASSO_SPARK
        t0 = t1 - JANELA_SPARK
        n = JANELA_SPARK // 60
        rin, rout = self.regs_trafego(defs)
        si, so = self.series_link(rin, rout, t0, n)
        k = PASSO_SPARK // 60
        kb = lambda v: None if v is None else int(round(v / 1000))
        return t0, [kb(v) for v in reduzir_max(si, k)], [kb(v) for v in reduzir_max(so, k)]

    def montar(self, agora):
        secoes = []
        por_id = {}
        contagem = {}
        t0s = None
        for sec in self.cfg["secoes"]:
            links = []
            for d in sec["links"]:
                info = self.calc_link(d, sec, agora)
                info.pop("_portas", None)
                t0s, si, so = self.spark([d], agora)
                info["spark"] = {"in": si, "out": so}
                por_id[d["id"]] = (info, d)
                contagem[info["estado"]] = contagem.get(info["estado"], 0) + 1
                links.append(info)
            secoes.append({"id": sec["id"], "titulo": sec.get("titulo", sec["id"]),
                           "detalhe": sec.get("detalhe", ""), "links": links})
        totais = []
        for t in self.cfg.get("totais") or []:
            if t.get("secao"):
                ids = [d["id"] for s in self.cfg["secoes"] if s["id"] == t["secao"] for d in s["links"]]
            else:
                ids = [i for i in t.get("links", []) if i in por_id]
            infos = [por_id[i][0] for i in ids if i in por_id]
            defs = [por_id[i][1] for i in ids if i in por_id]
            ent = sum(x["in"] or 0 for x in infos) if any(x["in"] is not None for x in infos) else None
            sai = sum(x["out"] or 0 for x in infos) if any(x["out"] is not None for x in infos) else None
            cap = sum(x["cap"] or 0 for x in infos) or None
            _, si, so = self.spark(defs, agora)
            totais.append({"id": t["id"], "nome": t.get("nome", t["id"]), "detalhe": t.get("detalhe", ""),
                           "links": ids, "in": ent, "out": sai, "cap": cap,
                           "uso": round(max(ent or 0, sai or 0) / cap * 100, 1) if cap and ent is not None else None,
                           "spark": {"in": si, "out": so}})
        nao_achadas = sorted("%s %s" % k for k, p in self.portas.items() if not p["itens"])
        snap = {
            "gerado": int(agora),
            "zabbix": {"ok": bool(self.zbx_ok), "erro": self.zbx_erro, "ultimo_ok": self.zbx_ultimo_ok,
                       "versao": self.zbx_versao},
            "config_erro": self.cfg_erro,
            "limites": self.cfg["limites"],
            "spark": {"inicio": t0s, "passo": PASSO_SPARK},
            "contagem": contagem,
            "totais": totais,
            "secoes": secoes,
            "nao_encontradas": nao_achadas,
        }
        data = json.dumps(snap, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        with self.lock:
            self.snapshot = data

    # ----- laço principal -----
    def devido(self, nome, intervalo, agora):
        if agora >= self.prox.get(nome, 0):
            self.prox[nome] = agora + intervalo
            return True
        return False

    def passo(self):
        agora = time.time()
        mudou = False
        if self.devido("config", CONFIG_SEG, agora):
            mudou = self.carregar_config()
        if not self.descoberto or self.devido("descoberta", DESCOBERTA_SEG, agora) or mudou:
            self.descobrir()
            self.prox["descoberta"] = agora + DESCOBERTA_SEG
            self.prox["rapido"] = self.prox["hist"] = self.prox["optico"] = self.prox["erros"] = 0
        feito = False
        if self.devido("rapido", RAPIDO_SEG, agora):
            self.ler_ultimos(self.ids(RAPIDOS))
            feito = True
        if self.devido("optico", OPTICO_SEG, agora):
            self.ler_ultimos(self.ids(OPTICOS))
            self.ajustar_escala()
            feito = True
        if self.devido("hist", HIST_SEG, agora):
            self.ler_hist(int(agora))
            feito = True
        if self.devido("erros", ERROS_SEG, agora):
            self.ler_erros(int(agora))
            feito = True
        if feito:
            self.zbx_ok = True
            self.zbx_erro = None
            self.zbx_ultimo_ok = int(time.time())
            self.montar(time.time())

    def rodar(self):
        espera = 2
        while True:
            try:
                self.passo()
                espera = 2
            except ZabbixErro as e:
                self.falhou(str(e))
                espera = min(espera * 2, 30)
            except Exception as e:  # noqa
                self.falhou("erro interno: %s" % e)
                traceback.print_exc()
                espera = min(espera * 2, 30)
            time.sleep(espera)

    def falhou(self, msg):
        if self.zbx_erro != msg:
            log("falha: %s" % msg)
        self.zbx_ok = False
        self.zbx_erro = msg
        self.prox = {k: 0 for k in self.prox if k not in ("config", "descoberta")}
        try:
            if self.cfg is not None:
                self.montar(time.time())
        except Exception:  # noqa
            traceback.print_exc()

    # ----- detalhe de um link -----
    def achar(self, link_id):
        for sec in self.cfg["secoes"]:
            for d in sec["links"]:
                if d["id"] == link_id:
                    return d, sec
        for t in self.cfg.get("totais") or []:
            if t["id"] == link_id:
                if t.get("secao"):
                    defs = [d for s in self.cfg["secoes"] if s["id"] == t["secao"] for d in s["links"]]
                else:
                    defs = [d for s in self.cfg["secoes"] for d in s["links"] if d["id"] in t.get("links", [])]
                return {"id": t["id"], "nome": t.get("nome"), "total": True, "defs": defs}, None
        return None, None

    def detalhe(self, link_id, periodo):
        if periodo not in PERIODOS:
            periodo = "6h"
        chave = (link_id, periodo)
        agora = time.time()
        c = self.cache_det.get(chave)
        if c and agora - c[0] < 30:
            return c[1]
        d, sec = self.achar(link_id)
        if d is None:
            return None
        defs = d["defs"] if d.get("total") else [d]
        dur = PERIODOS[periodo]
        t1 = int(agora // 60) * 60
        t0 = t1 - dur
        rin, rout = self.regs_trafego(defs)
        serie = {"in": [], "out": [], "inicio": t0, "passo": 60, "fonte": "historico"}
        if dur <= 86400:
            linhas = self.zbx.historico(rin + rout, t0 - 300, agora)
            por = {}
            for row in linhas:
                por.setdefault(str(row["itemid"]), []).append((int(row["clock"]), float(row["value"])))
            n = dur // 60
            si = soma_por_minuto([por.get(r["id"], []) for r in rin], t0, n)
            so = soma_por_minuto([por.get(r["id"], []) for r in rout], t0, n)
            k = max(1, int(math.ceil(n / float(PONTOS_GRAFICO))))
            serie.update(passo=60 * k, **{"in": [arred(v) for v in reduzir_max(si, k)],
                                          "out": [arred(v) for v in reduzir_max(so, k)]})
            pico = lambda s: max(((v, i) for i, v in enumerate(s) if v is not None), default=(None, None))
            media = lambda s: (sum(v for v in s if v is not None) / len([v for v in s if v is not None])) if any(v is not None for v in s) else None
            pi, po = pico(si), pico(so)
            serie["pico_in"] = {"v": arred(pi[0]), "t": t0 + 60 * pi[1] if pi[1] is not None else None}
            serie["pico_out"] = {"v": arred(po[0]), "t": t0 + 60 * po[1] if po[1] is not None else None}
            serie["media_in"], serie["media_out"] = arred(media(si)), arred(media(so))
        else:
            h0 = (t0 // 3600) * 3600
            n = int((t1 - h0) // 3600) + 1
            linhas = self.zbx.tendencia(rin + rout, h0, agora)
            idx_in = {r["id"] for r in rin}
            hin, hout = [None] * n, [None] * n
            ain, aout = [None] * n, [None] * n
            for row in linhas:
                i = int((int(row["clock"]) - h0) // 3600)
                if not 0 <= i < n:
                    continue
                mx, av = float(row["value_max"]), float(row["value_avg"])
                if str(row["itemid"]) in idx_in:
                    hin[i] = (hin[i] or 0) + mx
                    ain[i] = (ain[i] or 0) + av
                else:
                    hout[i] = (hout[i] or 0) + mx
                    aout[i] = (aout[i] or 0) + av
            k = max(1, int(math.ceil(n / float(PONTOS_GRAFICO))))
            serie.update(inicio=h0, passo=3600 * k, fonte="tendencia",
                         **{"in": [arred(v) for v in reduzir_max(hin, k)], "out": [arred(v) for v in reduzir_max(hout, k)]})
            pico = lambda s: max(((v, i) for i, v in enumerate(s) if v is not None), default=(None, None))
            pi, po = pico(hin), pico(hout)
            serie["pico_in"] = {"v": arred(pi[0]), "t": h0 + 3600 * pi[1] if pi[1] is not None else None}
            serie["pico_out"] = {"v": arred(po[0]), "t": h0 + 3600 * po[1] if po[1] is not None else None}
            vals_i = [v for v in ain if v is not None]
            vals_o = [v for v in aout if v is not None]
            serie["media_in"] = arred(sum(vals_i) / len(vals_i)) if vals_i else None
            serie["media_out"] = arred(sum(vals_o) / len(vals_o)) if vals_o else None
        res = {"id": link_id, "periodo": periodo, "serie": serie, "gerado": int(agora)}
        if not d.get("total"):
            erros24 = self.erros_24h(d)
            info = self.calc_link(d, sec, agora, erros24)
            res["portas"] = info.pop("_portas")
            res["link"] = info
            res["secao"] = sec.get("titulo")
        else:
            res["link"] = {"id": d["id"], "nome": d["nome"], "total": True, "links": [x["id"] for x in defs]}
        data = json.dumps(res, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.cache_det[chave] = (agora, data)
        if len(self.cache_det) > 200:
            self.cache_det = {k: v for k, v in self.cache_det.items() if agora - v[0] < 30}
        return data

    def erros_24h(self, d):
        chave = ("e24", d["id"])
        agora = time.time()
        c = self.cache_det.get(chave)
        if c and agora - c[0] < 300:
            return c[1]
        regs = []
        for _, p, _ in self.def_portas(d):
            regs += self.ids(ERROS, [p])
        out = {}
        if regs:
            try:
                linhas = self.zbx.tendencia(regs, agora - 86400, agora)
            except ZabbixErro:
                linhas = []
            por = {}
            for row in linhas:
                por.setdefault(str(row["itemid"]), []).append(row)
            for r in regs:
                out[r["id"]] = contar_tendencia(por.get(r["id"], []), r["modo"], r["delay"])
        self.cache_det[chave] = (agora, out)
        return out


def fmt_num(v):
    return ("%.1f" % v).replace(".", ",").replace(",0", "") if v < 100 else "%d" % round(v)


def fmt_int(v):
    return "{:,}".format(int(v)).replace(",", ".")


def fmt_dbm(v):
    return ("%.1f" % v).replace(".", ",").replace("-", "−")


def validar_config(cfg):
    if not isinstance(cfg, dict):
        raise ValueError("o arquivo deve ser um objeto JSON")
    eqs = cfg.get("equipamentos")
    if not isinstance(eqs, dict) or not eqs:
        raise ValueError("faltou 'equipamentos'")
    for k, e in eqs.items():
        if not isinstance(e, dict) or not e.get("zabbix"):
            raise ValueError("equipamento %s sem o nome do Zabbix" % k)
    secs = cfg.get("secoes")
    if not isinstance(secs, list) or not secs:
        raise ValueError("faltou 'secoes'")
    ids = set()
    for s in secs:
        if not s.get("id") or not isinstance(s.get("links"), list):
            raise ValueError("seção sem id ou sem links")
        for d in s["links"]:
            if not d.get("id"):
                raise ValueError("link sem id na seção %s" % s["id"])
            if d["id"] in ids:
                raise ValueError("id repetido: %s" % d["id"])
            ids.add(d["id"])
            if not d.get("trafego"):
                raise ValueError("link %s sem portas de tráfego" % d["id"])
            for papel in ("trafego", "membros", "outra_ponta"):
                for p in d.get(papel) or []:
                    if not isinstance(p, list) or len(p) < 2 or p[0] not in eqs:
                        raise ValueError("porta inválida em %s: %r (equipamento precisa existir)" % (d["id"], p))


# ---------------- HTTP ----------------

COLETOR = None


class Handler(BaseHTTPRequestHandler):
    server_version = "painel-links"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def reply(self, code, body, ctype="application/json; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def erro(self, code, msg):
        self.reply(code, json.dumps({"erro": msg}, ensure_ascii=False).encode("utf-8"))

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path, _, query = self.path.partition("?")
        q = urllib.parse.parse_qs(query)
        if path == "/api/links":
            with COLETOR.lock:
                body = COLETOR.snapshot
            return self.reply(200, body)
        if path.startswith("/api/link/"):
            link_id = urllib.parse.unquote(path[len("/api/link/"):])
            if not re.match(r"^[A-Za-z0-9_.-]{1,64}$", link_id):
                return self.erro(400, "id inválido")
            if COLETOR.cfg is None:
                return self.erro(503, "carregando")
            try:
                body = COLETOR.detalhe(link_id, (q.get("periodo") or ["6h"])[0])
            except ZabbixErro as e:
                return self.erro(502, str(e))
            if body is None:
                return self.erro(404, "link não encontrado")
            return self.reply(200, body)
        if path == "/api/saude":
            body = {"zabbix_ok": COLETOR.zbx_ok, "erro": COLETOR.zbx_erro, "ultimo_ok": COLETOR.zbx_ultimo_ok,
                    "config_erro": COLETOR.cfg_erro, "equipamentos": len(COLETOR.hosts),
                    "portas": len(COLETOR.portas),
                    "portas_sem_itens": sorted("%s %s" % k for k, p in COLETOR.portas.items() if not p["itens"])}
            return self.reply(200, json.dumps(body, ensure_ascii=False).encode("utf-8"))
        self.erro(404, "não encontrado")


def ler_token():
    tok = os.environ.get("ZABBIX_TOKEN", "").strip()
    if not tok:
        try:
            with open(TOKEN_FILE, encoding="utf-8") as f:
                tok = f.read().strip()
        except FileNotFoundError:
            pass
    if not tok:
        sys.exit("Token do Zabbix não encontrado em %s" % TOKEN_FILE)
    return tok


def serve():
    global COLETOR
    COLETOR = Coletor(Zabbix(ZABBIX_URL, ler_token()))
    COLETOR.carregar_config()
    COLETOR.prox["config"] = time.time() + CONFIG_SEG
    threading.Thread(target=COLETOR.rodar, daemon=True).start()
    srv = ThreadingHTTPServer(LISTEN, Handler)
    srv.daemon_threads = True
    log("painel-links ouvindo em %s:%d (Zabbix %s)" % (LISTEN[0], LISTEN[1], ZABBIX_URL))
    srv.serve_forever()


def init():
    os.makedirs(DIR, exist_ok=True)
    if not os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump(DEFAULT_CONFIG, f, ensure_ascii=False, indent=2)
            f.write("\n")
        print("Criado %s" % CONFIG_FILE)
    else:
        with open(CONFIG_FILE, encoding="utf-8") as f:
            validar_config(json.load(f))
        print("Mantido %s" % CONFIG_FILE)


def fmt_bps(v):
    if v is None:
        return "—"
    for lim, un in ((1e9, "Gbps"), (1e6, "Mbps"), (1e3, "kbps")):
        if abs(v) >= lim:
            return ("%.2f %s" % (v / lim, un)).replace(".", ",")
    return "%d bps" % v


def testar():
    c = Coletor(Zabbix(ZABBIX_URL, ler_token()))
    try:
        versao = c.zbx.call("apiinfo.version", {}, auth=False)
        print("Zabbix %s em %s" % (versao, ZABBIX_URL))
        c.zbx.call("host.get", {"output": ["hostid"], "limit": 1})
        print("Token aceito.")
    except ZabbixErro as e:
        print("FALHA: %s" % e)
        if "CERTIFICATE" in str(e).upper() or "SSL" in str(e).upper():
            print("Dica: o certificado do Zabbix não foi aceito. Para ignorar, use ZABBIX_TLS_VERIFY=0.")
        return 1
    c.carregar_config()
    if c.cfg_erro:
        print("ATENÇÃO: %s (usando a lista padrão)" % c.cfg_erro)
    c.descobrir()
    agora = int(time.time())
    c.ler_ultimos(c.ids(RAPIDOS + OPTICOS))
    c.ajustar_escala()
    faltam = [k for k, e in c.cfg["equipamentos"].items() if k not in c.hosts]
    print("Equipamentos achados: %d de %d" % (len(c.hosts), len(c.cfg["equipamentos"])))
    for k in faltam:
        print("  não achado: %s (%s)" % (k, c.cfg["equipamentos"][k]["zabbix"]))
    sem = sorted("%s %s" % k for k, p in c.portas.items() if not p["itens"])
    print("Portas com itens: %d de %d" % (len(c.portas) - len(sem), len(c.portas)))
    for s in sem:
        print("  sem itens: %s" % s)
    print()
    for sec in c.cfg["secoes"]:
        print("[%s]" % sec.get("titulo", sec["id"]))
        for d in sec["links"]:
            i = c.calc_link(d, sec, agora)
            print("  %-26s %-10s entrada %-12s saída %-12s uso %s  portas %d/%d%s" % (
                i["nome"][:26], i["estado"], fmt_bps(i["in"]), fmt_bps(i["out"]),
                "—" if i["uso"] is None else "%s%%" % fmt_num(i["uso"]),
                i["portas"]["up"], i["portas"]["total"],
                ("  · " + "; ".join(i["motivos"])) if i["motivos"] else ""))
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "serve"
    if cmd == "serve":
        serve()
    elif cmd == "testar":
        return testar()
    elif cmd == "init":
        init()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
__PAINEL_LINKS_PY__
chmod 755 "$APP/painel-links.py"
"$PY" -m py_compile "$APP/painel-links.py" || erro "painel-links.py não compilou."

install -d -m 750 -o root -g www-data "$CONF"
umask 027
printf '%s\n' "$TOKEN" > "$CONF/token.tmp" && mv -f "$CONF/token.tmp" "$CONF/token"
umask 022
chown root:www-data "$CONF/token"; chmod 640 "$CONF/token"
printf '%s\n' "$ZABBIX_URL" > "$CONF/zabbix_url"; chmod 644 "$CONF/zabbix_url"
if [ -f "$CONF/links.json" ] && [ "${ATUALIZAR_LINKS:-0}" = "1" ]; then
  cp "$CONF/links.json" "$CONF/links.json.bak-$(date +%Y%m%d-%H%M%S)"; rm -f "$CONF/links.json"
  info "links.json antigo guardado como cópia; gravando a lista padrão."
fi
PAINEL_LINKS_DIR="$CONF" "$PY" "$APP/painel-links.py" init || erro "O links.json atual tem erro. Corrija ou rode com ATUALIZAR_LINKS=1 para voltar ao padrão."
chown root:www-data "$CONF/links.json"; chmod 640 "$CONF/links.json"

cat > /etc/systemd/system/painel-links.service <<EOF
[Unit]
Description=Monitoramento de Links (UpDown NOC)
After=network-online.target
Wants=network-online.target

[Service]
Environment=PAINEL_LINKS_DIR=$CONF
Environment=PAINEL_LINKS_PORT=$PORTA_API
Environment=ZABBIX_URL=$ZABBIX_URL
ExecStart=$PY $APP/painel-links.py serve
User=www-data
Group=www-data
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable painel-links >/dev/null 2>&1
systemctl restart painel-links
for i in $(seq 1 20); do
  curl -s --noproxy '*' -o /dev/null "http://127.0.0.1:$PORTA_API/api/saude" && break
  sleep 0.5
done
systemctl is-active --quiet painel-links || { journalctl -u painel-links -n 30 --no-pager; erro "O serviço painel-links não subiu."; }
ok "Serviço painel-links rodando (127.0.0.1:$PORTA_API)."

# ---------- 3. painel ----------
install -d -m 755 "$WWW" "$WWW/assets"
cat > "$WWW/index.html" <<'__INDEX_HTML__'
<!doctype html>
<html lang="pt-BR" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Links · UpDown NOC</title>
<meta name="theme-color" content="#01017a">
<meta name="color-scheme" content="dark light">
<meta name="robots" content="noindex, nofollow">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Links UpDown">
<link rel="manifest" href="/assets/manifest.webmanifest">
<link rel="icon" type="image/svg+xml" href="/assets/favicon.svg">
<link rel="apple-touch-icon" href="/assets/apple-touch-icon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap">
<script>
  try { var t = localStorage.getItem('links-tema'); if (t === 'light' || t === 'dark') document.documentElement.dataset.theme = t; } catch (e) {}
</script>
<style>
/* Tokens do UpDown NOC (Topologia-NOC: public/css/noc/tokens.css) */
:root{
  --brand-500:#0b74ff; --brand-400:#2f8bff; --brand-600:#0a5ed6;
  --cyan-400:#1dc9ff; --cyan-300:#6adfff; --purple-400:#a56bff;
  --grad-brand:linear-gradient(135deg,#0b74ff 0%,#1dc9ff 100%);
  --ok-500:#2fd6a0; --warn-500:#ffb020; --danger-500:#ff5f74; --info-500:#1dc9ff;
  --font-sans:Inter,"Segoe UI Variable","Segoe UI",system-ui,-apple-system,Roboto,Arial,sans-serif;
  --font-mono:ui-monospace,"JetBrains Mono",SFMono-Regular,Consolas,"Liberation Mono",monospace;
  --fs-10:.625rem; --fs-11:.6875rem; --fs-12:.75rem; --fs-13:.8125rem; --fs-14:.875rem; --fs-16:1rem;
  --fs-20:1.25rem; --fs-24:1.5rem; --fs-32:2rem;
  --lh-tight:1.15; --lh-base:1.55; --tracking-caps:.12em;
  --s-1:4px; --s-2:8px; --s-3:12px; --s-4:16px; --s-5:20px; --s-6:24px; --s-8:32px; --s-10:40px; --s-12:48px; --s-16:64px;
  --r-sm:8px; --r-md:12px; --r-lg:16px; --r-xl:22px; --r-full:999px;
  --dur-1:120ms; --dur-2:200ms; --dur-3:320ms; --ease:cubic-bezier(.2,.7,.3,1); --ease-out:cubic-bezier(.16,1,.3,1);
  --appbar-h:56px; --z-drawer:60; --z-modal:70; --z-toast:90;
  --safe-t:env(safe-area-inset-top,0px); --safe-b:env(safe-area-inset-bottom,0px);
  --safe-l:env(safe-area-inset-left,0px); --safe-r:env(safe-area-inset-right,0px);
}
:root,:root[data-theme="dark"]{
  color-scheme:dark;
  --bg:#050d17; --bg-glow-1:rgba(11,116,255,.20); --bg-glow-2:rgba(29,201,255,.09);
  --surface-1:#08192b; --surface-2:#0c2438; --surface-3:#103049; --surface-glass:rgba(8,25,43,.86); --surface-input:#061626;
  --line:rgba(122,190,240,.14); --line-strong:rgba(122,190,240,.28);
  --text-1:#eaf6ff; --text-2:#ffffff; --text-3:#7191a7; --text-on-brand:#ffffff;
  --shadow-1:0 1px 2px rgba(0,0,0,.35); --shadow-2:0 12px 32px rgba(0,0,0,.38); --shadow-3:0 28px 70px rgba(0,0,0,.52);
  --ok-bg:rgba(47,214,160,.12); --ok-line:rgba(47,214,160,.32); --ok-text:#6ceabd;
  --warn-bg:rgba(255,176,32,.12); --warn-line:rgba(255,176,32,.30); --warn-text:#ffd07a;
  --danger-bg:rgba(255,95,116,.12); --danger-line:rgba(255,95,116,.30); --danger-text:#ff9caa;
  --info-bg:rgba(29,201,255,.12); --info-line:rgba(29,201,255,.30); --info-text:#8fe4ff;
  --focus-ring:0 0 0 3px rgba(29,201,255,.45);
  --appbar-bg:#01017a; --appbar-line:rgba(255,255,255,.15);
  /* séries do gráfico (validadas: faixa de luminosidade, daltonismo e contraste no fundo escuro) */
  --serie-in:#0fa0d9; --serie-out:#8f4ff0;
  --meter-track:rgba(122,190,240,.14);
}
:root[data-theme="light"]{
  color-scheme:light;
  --bg:#eef3f9; --bg-glow-1:rgba(11,116,255,.10); --bg-glow-2:rgba(29,201,255,.10);
  --surface-1:#ffffff; --surface-2:#f5f8fc; --surface-3:#e9f0f8; --surface-glass:rgba(255,255,255,.9); --surface-input:#ffffff;
  --line:rgba(14,48,82,.13); --line-strong:rgba(14,48,82,.26);
  --text-1:#0a1c2e; --text-2:#000000; --text-3:#5f7891; --text-on-brand:#ffffff;
  --shadow-1:0 1px 2px rgba(12,40,70,.07); --shadow-2:0 10px 26px rgba(12,40,70,.10); --shadow-3:0 24px 60px rgba(12,40,70,.16);
  --ok-bg:rgba(9,154,106,.10); --ok-line:rgba(9,154,106,.28); --ok-text:#0a7a55;
  --warn-bg:rgba(184,118,0,.10); --warn-line:rgba(184,118,0,.28); --warn-text:#8a5c00;
  --danger-bg:rgba(206,32,58,.09); --danger-line:rgba(206,32,58,.26); --danger-text:#b3182f;
  --info-bg:rgba(11,116,255,.09); --info-line:rgba(11,116,255,.26); --info-text:#0a5ed6;
  --focus-ring:0 0 0 3px rgba(11,116,255,.35);
  --appbar-bg:#01017a; --appbar-line:rgba(0,0,0,.15);
  --serie-in:#0d86c4; --serie-out:#8a3ce8;
  --meter-track:rgba(14,48,82,.10);
}

*,*::before,*::after{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;text-size-adjust:100%}
body{margin:0;min-height:100dvh;background:var(--bg);color:var(--text-1);font-family:var(--font-sans);font-size:var(--fs-14);line-height:var(--lh-base);
  -webkit-font-smoothing:antialiased;-webkit-tap-highlight-color:transparent;
  background-image:radial-gradient(900px 500px at 0% -10%,var(--bg-glow-1),transparent 60%),radial-gradient(700px 400px at 100% 0%,var(--bg-glow-2),transparent 60%);
  background-attachment:fixed}
button,input,select{font:inherit;color:inherit}
button{cursor:pointer}
[hidden]{display:none!important}
:focus-visible{outline:2px solid var(--cyan-400);outline-offset:2px;border-radius:var(--r-sm)}
:root[data-theme="light"] :focus-visible{outline-color:var(--brand-500)}
.sr{position:absolute!important;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
.skip{position:absolute;left:var(--s-2);top:-60px;z-index:var(--z-toast);background:var(--surface-1);padding:var(--s-2) var(--s-3);border-radius:var(--r-sm)}
.skip:focus{top:calc(var(--safe-t) + var(--s-2))}
.num{font-variant-numeric:tabular-nums}

/* ---------- barra do app ---------- */
.appbar{position:sticky;top:0;z-index:30;background:var(--appbar-bg);color:#fff;border-bottom:1px solid var(--appbar-line);
  padding:var(--safe-t) calc(var(--s-3) + var(--safe-r)) 0 calc(var(--s-3) + var(--safe-l))}
.appbar-in{height:var(--appbar-h);display:flex;align-items:center;gap:var(--s-3);max-width:1560px;margin:0 auto}
.brand{display:flex;align-items:center;gap:var(--s-3);min-width:0;text-decoration:none;color:inherit}
.brand img{height:28px;width:auto;display:block}
.brand-sep{width:1px;height:24px;background:rgba(255,255,255,.28)}
.brand b{font-size:var(--fs-16);font-weight:700;letter-spacing:-.01em;white-space:nowrap}
.appbar-sp{flex:1}
.live{display:inline-flex;align-items:center;gap:6px;height:32px;padding:0 var(--s-3);border-radius:var(--r-full);
  background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.16);font-size:var(--fs-12);font-weight:600;white-space:nowrap}
.live i{width:8px;height:8px;border-radius:50%;background:var(--ok-500);box-shadow:0 0 0 0 rgba(47,214,160,.6);animation:pulso 2s infinite}
.live[data-s="velho"] i{background:var(--warn-500);animation:none}
.live[data-s="erro"] i{background:var(--danger-500);animation:none}
@keyframes pulso{0%{box-shadow:0 0 0 0 rgba(47,214,160,.55)}70%{box-shadow:0 0 0 8px rgba(47,214,160,0)}100%{box-shadow:0 0 0 0 rgba(47,214,160,0)}}
.icon-btn{width:44px;height:44px;display:grid;place-items:center;border-radius:var(--r-full);border:0;background:transparent;color:inherit;margin-right:-6px}
.icon-btn:hover{background:rgba(255,255,255,.10)}
.icon-btn svg{width:22px;height:22px}

/* ---------- menu ---------- */
.menu{position:fixed;z-index:var(--z-modal);top:calc(var(--safe-t) + var(--appbar-h) - 4px);right:calc(var(--s-2) + var(--safe-r));min-width:244px;
  background:var(--surface-1);border:1px solid var(--line-strong);border-radius:var(--r-md);box-shadow:var(--shadow-2);padding:var(--s-2)}
.menu .quem{padding:var(--s-2) var(--s-3);font-size:var(--fs-12);color:var(--text-3);border-bottom:1px solid var(--line);margin-bottom:var(--s-1)}
.menu .quem b{color:var(--text-1)}
.menu a,.menu button{display:flex;align-items:center;gap:var(--s-3);width:100%;min-height:44px;padding:0 var(--s-3);border:0;background:none;border-radius:var(--r-sm);
  text-decoration:none;color:var(--text-1);font-size:var(--fs-14);text-align:left}
.menu a:hover,.menu button:hover{background:var(--surface-2)}
.menu svg{width:18px;height:18px;color:var(--text-3);flex:none}
.menu form{margin:0}

/* ---------- avisos ---------- */
.aviso{display:flex;gap:var(--s-2);align-items:flex-start;margin:var(--s-3) auto 0;max-width:1560px;padding:var(--s-3) var(--s-4);border-radius:var(--r-md);
  font-size:var(--fs-13);border:1px solid var(--warn-line);background:var(--warn-bg);color:var(--warn-text)}
.aviso[data-t="erro"]{border-color:var(--danger-line);background:var(--danger-bg);color:var(--danger-text)}
.aviso svg{width:18px;height:18px;flex:none;margin-top:1px}

/* ---------- conteúdo ---------- */
main{padding:0 calc(var(--s-3) + var(--safe-r)) calc(var(--s-8) + var(--safe-b)) calc(var(--s-3) + var(--safe-l))}
.wrap{max-width:1560px;margin:0 auto}

.resumo{display:grid;align-items:start;grid-auto-flow:column;grid-auto-columns:minmax(232px,78%);gap:var(--s-3);overflow-x:auto;scroll-snap-type:x mandatory;
  padding:var(--s-4) var(--s-3) var(--s-2);margin:0 calc(-1 * var(--s-3));scrollbar-width:none;overscroll-behavior-x:contain}
.resumo::-webkit-scrollbar{display:none}
.tile{scroll-snap-align:start;scroll-margin-left:var(--s-3);text-align:left;border:1px solid var(--line);background:var(--surface-1);border-radius:var(--r-lg);padding:var(--s-4);
  box-shadow:var(--shadow-1);display:flex;flex-direction:column;gap:var(--s-2);min-width:0;transition:border-color var(--dur-1)}
.tile:hover{border-color:var(--line-strong)}
.tile-cab{display:flex;align-items:baseline;justify-content:space-between;gap:var(--s-2)}
.kicker{font-size:var(--fs-10);font-weight:800;letter-spacing:var(--tracking-caps);text-transform:uppercase;color:var(--text-3)}
.tile-cab small{font-size:var(--fs-12);color:var(--text-3);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tile-status .big{font-size:var(--fs-32);font-weight:700;letter-spacing:-.02em;line-height:1}
.tile-status .big small{font-size:var(--fs-14);font-weight:600;color:var(--text-3);letter-spacing:0;margin-left:6px}
.alertas-mini{list-style:none;margin:var(--s-1) 0 0;padding:var(--s-2) 0 0;border-top:1px solid var(--line);display:flex;flex-direction:column;gap:6px}
.alertas-mini li{display:flex;align-items:center;gap:var(--s-2);font-size:var(--fs-12);min-width:0}
.alertas-mini li b{font-weight:700;white-space:nowrap}
.alertas-mini li span{color:var(--text-3);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
.alertas-mini .st{width:18px;height:18px;margin:0}
.alertas-mini .st svg{width:11px;height:11px}
.contas{display:flex;flex-wrap:wrap;gap:var(--s-1) var(--s-3);font-size:var(--fs-12);color:var(--text-3)}
.contas span{display:inline-flex;align-items:center;gap:6px}
.contas b{color:var(--text-1);font-weight:700}
.pares{display:grid;grid-template-columns:1fr 1fr;gap:var(--s-2)}
.par small{display:flex;align-items:center;gap:6px;font-size:var(--fs-11);font-weight:600;color:var(--text-3);text-transform:uppercase;letter-spacing:.06em}
.par b{display:block;font-size:var(--fs-20);font-weight:700;letter-spacing:-.02em;line-height:1.2;white-space:nowrap}
.par b u{text-decoration:none;font-size:var(--fs-12);font-weight:600;color:var(--text-3);margin-left:3px;letter-spacing:0}
.chave{display:inline-block;width:12px;height:2px;border-radius:2px;flex:none}
.chave.in{background:var(--serie-in)} .chave.out{background:var(--serie-out)}

.filtros{position:sticky;top:calc(var(--safe-t) + var(--appbar-h));z-index:20;margin:0 calc(-1 * var(--s-3));padding:var(--s-2) var(--s-3);
  background:linear-gradient(var(--bg) 78%,transparent);display:flex;gap:var(--s-2);overflow-x:auto;scrollbar-width:none}
.filtros::-webkit-scrollbar{display:none}
.chip{flex:none;height:36px;padding:0 var(--s-4);border-radius:var(--r-full);border:1px solid var(--line-strong);background:var(--surface-1);color:var(--text-1);
  font-size:var(--fs-13);font-weight:600;display:inline-flex;align-items:center;gap:var(--s-2);white-space:nowrap;transition:background var(--dur-1),border-color var(--dur-1)}
.chip[aria-pressed="true"]{background:var(--brand-500);border-color:var(--brand-500);color:#fff}
.chip .n{min-width:20px;height:20px;padding:0 6px;border-radius:var(--r-full);display:inline-grid;place-items:center;font-size:var(--fs-11);font-weight:800;
  background:var(--danger-500);color:#fff}
.chip[aria-pressed="true"] .n{background:#fff;color:var(--brand-600)}

.secao{margin-top:var(--s-4)}
.secao-cab{display:flex;flex-wrap:wrap;align-items:baseline;gap:0 var(--s-2);margin:0 0 var(--s-3);padding:0 var(--s-1)}
.secao-cab h2{margin:0;font-size:var(--fs-16);font-weight:700;letter-spacing:-.01em}
.secao-cab small{color:var(--text-3);font-size:var(--fs-12);order:3;flex-basis:100%}
@media (min-width:600px){ .secao-cab small{order:0;flex-basis:auto} }
.secao-cab .q{margin-left:auto;color:var(--text-3);font-size:var(--fs-12);font-weight:600;white-space:nowrap}
.grade{display:grid;grid-template-columns:1fr;gap:var(--s-3)}

/* ---------- card de link ---------- */
.card{position:relative;display:flex;flex-direction:column;gap:var(--s-3);width:100%;text-align:left;border:1px solid var(--line);background:var(--surface-1);
  border-radius:var(--r-lg);padding:var(--s-3) var(--s-4);box-shadow:var(--shadow-1);transition:border-color var(--dur-1),transform var(--dur-1);overflow:hidden}
.card:hover{border-color:var(--line-strong)}
.card:active{transform:scale(.995)}
.card::before{content:"";position:absolute;left:0;top:0;bottom:0;width:3px;background:transparent}
.card[data-estado="atencao"]::before{background:var(--warn-500)}
.card[data-estado="critico"]::before,.card[data-estado="degradado"]::before,.card[data-estado="fora"]::before{background:var(--danger-500)}
.card[data-estado="fora"]{border-color:var(--danger-line)}
.card-cab{display:flex;align-items:flex-start;gap:var(--s-3)}
.st{flex:none;width:28px;height:28px;border-radius:var(--r-full);display:grid;place-items:center;margin-top:1px}
.st svg{width:16px;height:16px}
.st[data-e="ok"]{background:var(--ok-bg);color:var(--ok-text)}
.st[data-e="atencao"]{background:var(--warn-bg);color:var(--warn-text)}
.st[data-e="critico"],.st[data-e="degradado"]{background:var(--danger-bg);color:var(--danger-text)}
.st[data-e="fora"]{background:var(--danger-500);color:#fff}
.st[data-e="sem-dados"],.st[data-e="nao-encontrado"]{background:var(--surface-3);color:var(--text-3)}
.ttl{min-width:0;flex:1}
.ttl b{display:block;font-size:var(--fs-16);font-weight:700;letter-spacing:-.01em;line-height:1.25;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ttl small{display:block;font-size:var(--fs-12);color:var(--text-3);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.uso-pct{flex:none;text-align:right;line-height:1.15;display:flex;flex-direction:column;align-items:flex-end;gap:2px}
.uso-pct b{display:block;font-size:var(--fs-20);font-weight:700;letter-spacing:-.02em}
.uso-pct small{font-size:var(--fs-11);color:var(--text-3);white-space:nowrap}
.card-meio{display:grid;grid-template-columns:minmax(0,1fr) 38%;gap:var(--s-3);align-items:end}
.card-meio .pares{gap:var(--s-2)}
.card .par b{font-size:var(--fs-20)}
.card .spark{height:40px}
.card-base{display:flex;flex-direction:column;gap:6px}
.card-base .rodape{justify-content:space-between}
.card-base .rodape .cap{margin-left:auto}
@media (max-width:379px){ .card-meio{grid-template-columns:1fr} }
.badge{display:inline-flex;align-items:center;gap:4px;font-size:var(--fs-10);font-weight:800;letter-spacing:.06em;text-transform:uppercase;
  padding:2px var(--s-2);border-radius:var(--r-full);border:1px solid transparent;white-space:nowrap}
.badge[data-e="atencao"]{background:var(--warn-bg);color:var(--warn-text);border-color:var(--warn-line)}
.badge[data-e="critico"],.badge[data-e="degradado"]{background:var(--danger-bg);color:var(--danger-text);border-color:var(--danger-line)}
.badge[data-e="fora"]{background:var(--danger-500);color:#fff}
.badge[data-e="sem-dados"],.badge[data-e="nao-encontrado"]{background:var(--surface-3);color:var(--text-3)}
.badge[data-e="ok"]{background:var(--ok-bg);color:var(--ok-text);border-color:var(--ok-line)}
.meter{height:6px;border-radius:var(--r-full);background:var(--meter-track);overflow:hidden}
.meter i{display:block;height:100%;width:0;border-radius:var(--r-full);background:var(--grad-brand);transition:width var(--dur-3) var(--ease)}
.meter[data-n="atencao"] i{background:var(--warn-500)} .meter[data-n="critico"] i{background:var(--danger-500)}
.meter-leg{display:flex;justify-content:space-between;font-size:var(--fs-11);color:var(--text-3);margin-top:-2px}
.spark{display:block;width:100%;height:40px;overflow:visible}
.meter.fino{height:4px}
.spark path{fill:none;stroke-width:1.75;stroke-linejoin:round;stroke-linecap:round;vector-effect:non-scaling-stroke}
.spark .a{fill:var(--serie-in);opacity:.10;stroke:none}
.spark .i{stroke:var(--serie-in)} .spark .o{stroke:var(--serie-out)}
.rodape{display:flex;flex-wrap:wrap;gap:var(--s-1) var(--s-3);font-size:var(--fs-12);color:var(--text-3)}
.rodape span{display:inline-flex;align-items:center;gap:4px;white-space:nowrap}
.rodape svg{width:14px;height:14px}
.rodape [data-n="aviso"]{color:var(--warn-text);font-weight:600}
.rodape [data-n="alarme"]{color:var(--danger-text);font-weight:700}
.motivo{display:flex;gap:6px;align-items:flex-start;margin:0;font-size:var(--fs-12);font-weight:600;color:var(--text-1);
  padding:var(--s-2) var(--s-3);border-radius:var(--r-sm);background:var(--surface-2)}
.motivo svg{width:14px;height:14px;flex:none;margin-top:2px}
.card[data-estado="atencao"] .motivo svg{color:var(--warn-text)}
.card[data-estado="critico"] .motivo svg,.card[data-estado="degradado"] .motivo svg,.card[data-estado="fora"] .motivo svg{color:var(--danger-text)}

.vazio{border:1px dashed var(--line-strong);border-radius:var(--r-lg);padding:var(--s-8) var(--s-4);text-align:center;color:var(--text-3)}
.vazio b{display:block;color:var(--text-1);font-size:var(--fs-16);margin-bottom:var(--s-1)}
.carregando .card,.carregando .tile{opacity:.55}
footer.fonte{margin-top:var(--s-6);text-align:center;font-size:var(--fs-12);color:var(--text-3)}

/* ---------- detalhe (folha) ---------- */
.veu{position:fixed;inset:0;z-index:calc(var(--z-drawer) - 1);background:rgba(2,8,16,.55);opacity:0;transition:opacity var(--dur-2)}
.veu.on{opacity:1}
.folha{position:fixed;z-index:var(--z-drawer);inset:0;background:var(--bg);display:flex;flex-direction:column;transform:translateY(100%);
  transition:transform var(--dur-3) var(--ease-out);outline:none}
.folha.on{transform:none}
.folha-cab{position:sticky;top:0;z-index:2;background:var(--appbar-bg);color:#fff;padding:var(--safe-t) calc(var(--s-2) + var(--safe-r)) 0 calc(var(--s-2) + var(--safe-l));
  border-bottom:1px solid var(--appbar-line)}
.folha-cab-in{min-height:var(--appbar-h);display:flex;align-items:center;gap:var(--s-2)}
.folha-cab .t{min-width:0;flex:1}
.folha-cab .t b{display:block;font-size:var(--fs-16);font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;line-height:1.2}
.folha-cab .t small{display:block;font-size:var(--fs-12);color:rgba(255,255,255,.7);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.folha-cab .icon-btn{margin:0}
.folha-corpo{flex:1;overflow-y:auto;-webkit-overflow-scrolling:touch;overscroll-behavior:contain;
  padding:var(--s-4) calc(var(--s-4) + var(--safe-r)) calc(var(--s-10) + var(--safe-b)) calc(var(--s-4) + var(--safe-l))}
.folha-corpo > *{max-width:760px;margin-left:auto;margin-right:auto}
.bloco{background:var(--surface-1);border:1px solid var(--line);border-radius:var(--r-lg);padding:var(--s-4);box-shadow:var(--shadow-1);margin-bottom:var(--s-3)}
.bloco h3{margin:0 0 var(--s-3);font-size:var(--fs-13);font-weight:700;letter-spacing:.02em}
.agora{display:grid;grid-template-columns:1fr 1fr;gap:var(--s-3) var(--s-4)}
.agora .par b{font-size:var(--fs-24)}
.agora .uso{grid-column:1 / -1}
.motivos{list-style:none;margin:0 0 var(--s-3);padding:0;display:flex;flex-direction:column;gap:var(--s-2)}
.motivos li{display:flex;gap:var(--s-2);align-items:flex-start;padding:var(--s-3);border-radius:var(--r-md);font-size:var(--fs-13);font-weight:600;
  background:var(--warn-bg);border:1px solid var(--warn-line);color:var(--text-1)}
.motivos li[data-e="danger"]{background:var(--danger-bg);border-color:var(--danger-line)}
.motivos svg{width:16px;height:16px;flex:none;margin-top:2px}
.motivos li svg{color:var(--warn-text)} .motivos li[data-e="danger"] svg{color:var(--danger-text)}

.seg{display:grid;grid-template-columns:repeat(5,1fr);gap:2px;padding:3px;border-radius:var(--r-md);background:var(--surface-2);border:1px solid var(--line);margin-bottom:var(--s-3)}
.seg button{height:36px;border:0;border-radius:var(--r-sm);background:transparent;font-size:var(--fs-13);font-weight:700;color:var(--text-3)}
.seg button[aria-pressed="true"]{background:var(--surface-1);color:var(--text-1);box-shadow:var(--shadow-1)}
.graf{position:relative;touch-action:pan-y;user-select:none;-webkit-user-select:none}
.graf svg{display:block;width:100%;height:240px;overflow:visible}
.graf svg:focus{outline:none}
.graf svg:focus-visible{outline:2px solid var(--cyan-400);outline-offset:4px}
.graf .grade-l{stroke:var(--line);stroke-width:1}
.graf .eixo{fill:var(--text-3);font-size:11px;font-family:var(--font-sans)}
.graf .li{fill:none;stroke:var(--serie-in);stroke-width:2;stroke-linejoin:round;stroke-linecap:round}
.graf .lo{fill:none;stroke:var(--serie-out);stroke-width:2;stroke-linejoin:round;stroke-linecap:round}
.graf .ar{fill:var(--serie-in);opacity:.10}
.graf .cap{stroke:var(--text-3);stroke-width:1;stroke-dasharray:0}
.graf .cap-t{fill:var(--text-3);font-size:11px;font-weight:600}
.graf .mira{stroke:var(--text-3);stroke-width:1}
.graf .pt{stroke:var(--surface-1);stroke-width:2}
.graf.recarregando svg{opacity:.45;transition:opacity var(--dur-2)}
.dica{position:absolute;top:0;pointer-events:none;background:var(--surface-glass);backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);
  border:1px solid var(--line-strong);border-radius:var(--r-sm);padding:var(--s-2) var(--s-3);box-shadow:var(--shadow-2);font-size:var(--fs-12);min-width:150px;white-space:nowrap}
.dica .h{color:var(--text-3);font-weight:600;margin-bottom:2px}
.dica .l{display:flex;align-items:center;gap:var(--s-2)}
.dica .l b{font-size:var(--fs-14);font-weight:700}
.dica .l span{color:var(--text-3)}
.legenda{display:flex;flex-wrap:wrap;gap:var(--s-2) var(--s-4);align-items:center;font-size:var(--fs-12);color:var(--text-3);margin-top:var(--s-2)}
.legenda span{display:inline-flex;align-items:center;gap:6px}
.legenda .nota{margin-left:auto}
.picos{display:grid;grid-template-columns:1fr 1fr;gap:var(--s-3);margin:var(--s-3) 0 0;padding-top:var(--s-3);border-top:1px solid var(--line)}
.picos dt{font-size:var(--fs-11);font-weight:600;color:var(--text-3);text-transform:uppercase;letter-spacing:.06em;display:flex;align-items:center;gap:6px}
.picos dd{margin:2px 0 0;font-size:var(--fs-16);font-weight:700}
.picos dd small{display:block;font-size:var(--fs-11);font-weight:500;color:var(--text-3)}
.tabela{margin-top:var(--s-3)}
.tabela summary{cursor:pointer;font-size:var(--fs-12);font-weight:600;color:var(--text-3);min-height:32px;display:flex;align-items:center}
.tabela table{width:100%;border-collapse:collapse;font-size:var(--fs-12);margin-top:var(--s-2)}
.tabela th,.tabela td{padding:6px var(--s-2);text-align:right;border-bottom:1px solid var(--line)}
.tabela th:first-child,.tabela td:first-child{text-align:left}
.tabela .rolar{max-height:280px;overflow:auto}

.portas{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:var(--s-2)}
.porta{border:1px solid var(--line);border-radius:var(--r-md);padding:var(--s-3);background:var(--surface-2)}
.porta-cab{display:flex;align-items:center;gap:var(--s-2)}
.porta-cab b{font-size:var(--fs-14);font-weight:700}
.porta-cab .papel{margin-left:auto;font-size:var(--fs-11);color:var(--text-3);font-weight:600;white-space:nowrap}
.porta .alias{display:block;font-family:var(--font-mono);font-size:var(--fs-11);color:var(--text-3);margin:2px 0 var(--s-2);word-break:break-all}
.porta dl{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:var(--s-2) var(--s-3);margin:0}
.porta dt{font-size:var(--fs-10);font-weight:700;color:var(--text-3);text-transform:uppercase;letter-spacing:.06em}
.porta dd{margin:0;font-size:var(--fs-13);font-weight:600;white-space:nowrap}
.porta dd small{font-weight:500;color:var(--text-3);font-size:var(--fs-11);white-space:normal;display:block;line-height:1.3}
.porta dd[data-n="aviso"]{color:var(--warn-text)} .porta dd[data-n="alarme"]{color:var(--danger-text)}
.pill{display:inline-flex;align-items:center;gap:4px;font-size:var(--fs-11);font-weight:700;padding:1px var(--s-2);border-radius:var(--r-full)}
.pill[data-s="up"]{background:var(--ok-bg);color:var(--ok-text)}
.pill[data-s="down"]{background:var(--danger-500);color:#fff}
.pill[data-s="na"]{background:var(--surface-3);color:var(--text-3)}
.rotas{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:var(--s-2)}
.rota{border:1px solid var(--line);border-radius:var(--r-md);padding:var(--s-3);background:var(--surface-2)}
.rota b{display:block;font-size:var(--fs-13)}
.rota span{display:block;font-size:var(--fs-12);color:var(--text-3)}
.nota-p{font-size:var(--fs-12);color:var(--text-3);margin:var(--s-2) 0 0}

@media (min-width:600px){
  .resumo{align-items:stretch;grid-auto-flow:row;grid-template-columns:repeat(2,minmax(0,1fr));overflow:visible;margin:0;padding:var(--s-4) 0 var(--s-2)}
  .grade{grid-template-columns:repeat(2,minmax(0,1fr))}
  .filtros{margin:0;padding-left:0;padding-right:0}
}
@media (min-width:1000px){
  .resumo{grid-template-columns:repeat(4,minmax(0,1fr))}
  .grade{grid-template-columns:repeat(3,minmax(0,1fr))}
  .folha{left:auto;width:min(760px,100vw);box-shadow:var(--shadow-3);border-left:1px solid var(--line);transform:translateX(100%)}
  .folha.on{transform:none}
}
@media (min-width:1440px){ .grade{grid-template-columns:repeat(4,minmax(0,1fr))} }
@media (max-width:359px){ .brand-sep,.brand b{display:none} .par b{font-size:var(--fs-16)} }
@media (prefers-reduced-motion:reduce){ *,*::before,*::after{animation:none!important;transition:none!important} }
@media (forced-colors:active){ .card::before{background:CanvasText} .meter i{background:Highlight} }
</style>
</head>
<body>
<a class="skip" href="#conteudo">Pular para os links</a>

<header class="appbar">
  <div class="appbar-in">
    <a class="brand" href="/" aria-label="Monitoramento de Links — UpDown Internet">
      <img src="/assets/logo-branco.png" alt="UpDown Internet" width="96" height="28">
      <span class="brand-sep" aria-hidden="true"></span>
      <b>Links</b>
    </a>
    <span class="appbar-sp"></span>
    <span class="live" id="live" data-s="carregando" role="status" aria-live="polite"><i aria-hidden="true"></i><span id="liveTxt">Carregando</span></span>
    <button class="icon-btn" id="menuBtn" aria-label="Menu" aria-haspopup="true" aria-expanded="false">
      <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><circle cx="12" cy="5" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="12" cy="19" r="2"/></svg>
    </button>
  </div>
</header>

<div class="menu" id="menu" role="menu" hidden>
  <div class="quem" id="quem">Conectado</div>
  <button type="button" role="menuitem" id="temaBtn">
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>
    <span id="temaTxt">Tema claro</span>
  </button>
  <a role="menuitem" id="oltLink" href="#">
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="4" width="18" height="6" rx="1.5"/><rect x="3" y="14" width="18" height="6" rx="1.5"/><path d="M7 7h.01M7 17h.01"/></svg>
    Painel das OLTs
  </a>
  <form method="post" action="/logout">
    <button type="submit" role="menuitem">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/></svg>
      Sair
    </button>
  </form>
</div>

<main id="conteudo">
  <div class="wrap">
    <div class="aviso" id="aviso" hidden></div>
    <section class="resumo" id="resumo" aria-label="Resumo"></section>
    <nav class="filtros" id="filtros" aria-label="Filtrar links"></nav>
    <div id="lista" aria-live="off"></div>
    <footer class="fonte" id="fonte">Fonte: Zabbix da LV Network</footer>
  </div>
</main>

<div class="veu" id="veu" hidden></div>
<section class="folha" id="folha" role="dialog" aria-modal="true" aria-labelledby="folhaTitulo" tabindex="-1" hidden>
  <div class="folha-cab">
    <div class="folha-cab-in">
      <button class="icon-btn" id="voltar" aria-label="Voltar">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"/></svg>
      </button>
      <div class="t"><b id="folhaTitulo">—</b><small id="folhaSub"></small></div>
      <span class="badge" id="folhaBadge" hidden></span>
    </div>
  </div>
  <div class="folha-corpo" id="folhaCorpo"></div>
</section>

<script>
(function () {
  'use strict';

  var ATUALIZA_MS = 20000, DETALHE_MS = 60000, VELHO_S = 120;
  var ESTADOS = {
    'ok':             { rot: 'Online',          ic: 'ok' },
    'atencao':        { rot: 'Atenção',         ic: 'alerta' },
    'critico':        { rot: 'Crítico',         ic: 'exclama' },
    'degradado':      { rot: 'Degradado',       ic: 'exclama' },
    'fora':           { rot: 'Fora do ar',      ic: 'fora' },
    'sem-dados':      { rot: 'Sem dados',       ic: 'relogio' },
    'nao-encontrado': { rot: 'Não encontrado',  ic: 'menos' }
  };
  var ORDEM = { 'fora': 6, 'degradado': 5, 'critico': 4, 'atencao': 3, 'sem-dados': 2, 'nao-encontrado': 1, 'ok': 0 };
  var ICONES = {
    ok: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
    alerta: '<path d="M12 3.5 2.5 20h19L12 3.5z"/><path d="M12 10v4.5M12 17.4v.2"/>',
    exclama: '<circle cx="12" cy="12" r="9"/><path d="M12 7.5v5.5M12 16.3v.2"/>',
    fora: '<path d="M6 6l12 12M18 6L6 18"/>',
    relogio: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3.2 2"/>',
    menos: '<path d="M6 12h12"/>',
    erro: '<circle cx="12" cy="12" r="9"/><path d="M12 7.5v5.5M12 16.3v.2"/>',
    luz: '<path d="M12 3v3M12 18v3M3 12h3M18 12h3"/><circle cx="12" cy="12" r="4"/>',
    porta: '<rect x="4" y="6" width="16" height="12" rx="2"/><path d="M8 18v-3h8v3"/>'
  };
  function svg(nome, sw) {
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="' + (sw || 2.4) + '" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + ICONES[nome] + '</svg>';
  }

  var $ = function (s, r) { return (r || document).querySelector(s); };
  function el(tag, cls, txt) { var e = document.createElement(tag); if (cls) e.className = cls; if (txt != null) e.textContent = txt; return e; }

  // ---------- formatação ----------
  var NF = {};
  function nf(d) { return NF[d] || (NF[d] = new Intl.NumberFormat('pt-BR', { minimumFractionDigits: d, maximumFractionDigits: d })); }
  function bps(v) {
    if (v == null) return { n: '—', u: '' };
    var a = Math.abs(v), un = 'bps', d = v;
    if (a >= 1e9) { d = v / 1e9; un = 'Gbps'; } else if (a >= 1e6) { d = v / 1e6; un = 'Mbps'; } else if (a >= 1e3) { d = v / 1e3; un = 'kbps'; }
    var ad = Math.abs(d), casas = un === 'bps' ? 0 : ad < 10 ? 2 : ad < 100 ? 1 : 0;
    return { n: nf(casas).format(d), u: un };
  }
  function bpsTxt(v) { var b = bps(v); return b.u ? b.n + ' ' + b.u : b.n; }
  function capTxt(v) {
    if (!v) return '—';
    if (v >= 1e9) return nf(v % 1e9 ? 1 : 0).format(v / 1e9) + ' Gbps';
    return bpsTxt(v);
  }
  function pct(v) { return v == null ? '—' : nf(v < 10 && v % 1 ? 1 : 0).format(v) + '%'; }
  function dbm(v) { return v == null ? '—' : nf(1).format(v).replace('-', '−'); }
  function inteiro(v) { return nf(0).format(v || 0); }
  function hora(t) { var d = new Date(t * 1000); return pad(d.getHours()) + ':' + pad(d.getMinutes()); }
  function dia(t) { var d = new Date(t * 1000); return pad(d.getDate()) + '/' + pad(d.getMonth() + 1); }
  function pad(n) { return n < 10 ? '0' + n : '' + n; }
  function abrev(ifn) {
    return String(ifn).replace(/^XGigabitEthernet/, 'XGE').replace(/^GigabitEthernet/, 'GE');
  }
  function nivelUso(u, lim) {
    if (u == null || !lim) return 'ok';
    return u >= lim.uso_critico ? 'critico' : u >= lim.uso_atencao ? 'atencao' : 'ok';
  }

  // ---------- estado ----------
  var S = { snap: null, filtro: 'todos', ultimoOk: 0, falhou: false, aberto: null, periodo: '6h', det: null, cards: {}, timer: null, timerDet: null };
  try { var f = localStorage.getItem('links-filtro'); if (f) S.filtro = f; var pp = localStorage.getItem('links-periodo'); if (pp) S.periodo = pp; } catch (e) {}

  function api(url) {
    return fetch(url, { credentials: 'same-origin', cache: 'no-store', headers: { 'Accept': 'application/json' } }).then(function (r) {
      if (r.status === 401) { irParaLogin(); throw new Error('sessao'); }
      if (!r.ok) return r.json().catch(function () { return {}; }).then(function (j) { throw new Error(j.erro || ('HTTP ' + r.status)); });
      return r.json();
    });
  }
  function irParaLogin() {
    var next = location.pathname + location.search + location.hash;
    location.replace('/entrar?next=' + encodeURIComponent(next));
  }

  // ---------- ciclo de atualização ----------
  function atualizar() {
    clearTimeout(S.timer);
    document.body.classList.toggle('carregando', !S.snap);
    return api('/api/links').then(function (snap) {
      S.snap = snap; S.ultimoOk = Date.now(); S.falhou = false;
      render();
    }).catch(function (e) {
      if (e.message === 'sessao') return;
      S.falhou = true; renderAviso(); renderLive();
    }).then(function () {
      document.body.classList.remove('carregando');
      if (!document.hidden) S.timer = setTimeout(atualizar, ATUALIZA_MS);
    });
  }
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) { clearTimeout(S.timer); clearTimeout(S.timerDet); }
    else { atualizar(); if (S.aberto) carregarDetalhe(); }
  });
  setInterval(renderLive, 5000);

  function todosLinks() {
    var out = [];
    if (!S.snap || !S.snap.secoes) return out;
    S.snap.secoes.forEach(function (s) { s.links.forEach(function (l) { out.push({ l: l, s: s }); }); });
    return out;
  }
  function alertas() { return todosLinks().filter(function (x) { return x.l.estado !== 'ok'; }); }

  function render() {
    if (!S.snap || !S.snap.secoes) return;
    renderAviso(); renderLive(); renderResumo(); renderFiltros(); renderLista();
    if (S.aberto && S.det) renderCabFolha();
  }

  function renderLive() {
    var live = $('#live'), txt = $('#liveTxt');
    if (!S.snap || !S.snap.gerado) { live.dataset.s = S.falhou ? 'erro' : 'carregando'; txt.textContent = S.falhou ? 'Sem conexão' : 'Carregando'; return; }
    var idade = Math.max(0, Math.round(Date.now() / 1000 - S.snap.gerado));
    var zok = S.snap.zabbix && S.snap.zabbix.ok;
    live.dataset.s = S.falhou || !zok ? 'erro' : idade > VELHO_S ? 'velho' : 'ok';
    txt.textContent = S.falhou ? 'Sem conexão' : !zok ? 'Zabbix fora' : idade < 60 ? 'Ao vivo · ' + idade + ' s' : 'há ' + Math.round(idade / 60) + ' min';
  }

  function renderAviso() {
    var a = $('#aviso'), msg = null, tipo = 'aviso';
    if (S.falhou) { msg = 'Sem conexão com o servidor. Tentando de novo…' + (S.snap ? ' Os números abaixo são de ' + hora(S.snap.gerado) + '.' : ''); tipo = 'erro'; }
    else if (S.snap && S.snap.zabbix && !S.snap.zabbix.ok) {
      msg = 'O Zabbix da LV não está respondendo' + (S.snap.zabbix.ultimo_ok ? ' desde ' + hora(S.snap.zabbix.ultimo_ok) + '. Mostrando os últimos dados lidos.' : '.');
      tipo = 'erro';
    } else if (S.snap && S.snap.config_erro) { msg = S.snap.config_erro + '. O painel está usando a última lista válida.'; }
    a.hidden = !msg;
    if (msg) { a.dataset.t = tipo; a.innerHTML = svg('erro', 2); a.appendChild(el('span', null, msg)); }
  }

  // ---------- resumo ----------
  function renderResumo() {
    var box = $('#resumo'); box.textContent = '';
    var c = S.snap.contagem || {}, tot = todosLinks().length, al = alertas().length;
    var t = el('button', 'tile tile-status'); t.type = 'button';
    t.setAttribute('aria-label', al ? al + ' links com alerta. Mostrar alertas' : 'Todos os links normais');
    t.innerHTML = '<div class="tile-cab"><span class="kicker">Status</span><small></small></div>';
    $('small', t).textContent = tot + ' links';
    var big = el('div', 'big'); big.textContent = al ? al : tot;
    big.appendChild(el('small', null, al ? 'com alerta' : 'online'));
    t.appendChild(big);
    var contas = el('div', 'contas');
    [['ok', 'online'], ['atencao', 'atenção'], ['critico', 'crítico'], ['degradado', 'degradado'], ['fora', 'fora'], ['sem-dados', 'sem dados']].forEach(function (p) {
      var n = c[p[0]] || 0; if (!n && p[0] !== 'ok') return;
      var s = el('span'); var st = el('i', 'st'); st.dataset.e = p[0]; st.style.width = st.style.height = '16px'; st.innerHTML = svg(ESTADOS[p[0]].ic, 3);
      st.firstChild.style.width = st.firstChild.style.height = '10px';
      s.appendChild(st); var b = el('b', null, n); s.appendChild(b); s.appendChild(document.createTextNode(p[1])); contas.appendChild(s);
    });
    t.appendChild(contas);
    var lst = alertas().sort(function (x, y) { return ORDEM[y.l.estado] - ORDEM[x.l.estado]; });
    if (lst.length) {
      var ul = el('ul', 'alertas-mini');
      lst.slice(0, 3).forEach(function (x) {
        var li = el('li'); var st2 = el('i', 'st'); st2.dataset.e = x.l.estado; st2.innerHTML = svg(ESTADOS[x.l.estado].ic, 3); li.appendChild(st2);
        li.appendChild(el('b', null, x.l.nome)); li.appendChild(el('span', null, (x.l.motivos || [])[0] || ESTADOS[x.l.estado].rot)); ul.appendChild(li);
      });
      if (lst.length > 3) { var mais = el('li'); mais.appendChild(el('span', null, '+ ' + (lst.length - 3) + ' em Alertas')); ul.appendChild(mais); }
      t.appendChild(ul);
    }
    t.addEventListener('click', function () { setFiltro(al ? 'alertas' : 'todos'); });
    box.appendChild(t);

    (S.snap.totais || []).forEach(function (to) {
      var b = el('button', 'tile'); b.type = 'button';
      b.setAttribute('aria-label', to.nome + ': entrada ' + bpsTxt(to['in']) + ', saída ' + bpsTxt(to.out) + '. Abrir gráfico');
      var cab = el('div', 'tile-cab'); cab.appendChild(el('span', 'kicker', to.nome)); cab.appendChild(el('small', null, to.detalhe || '')); b.appendChild(cab);
      b.appendChild(pares(to['in'], to.out));
      var nv = nivelUso(to.uso, S.snap.limites);
      b.appendChild(medidor(to.uso, nv));
      var leg = el('div', 'meter-leg'); leg.appendChild(el('span', null, 'Uso ' + pct(to.uso))); leg.appendChild(el('span', null, 'de ' + capTxt(to.cap))); b.appendChild(leg);
      b.appendChild(sparkline(to.spark));
      b.addEventListener('click', function () { abrir(to.id); });
      box.appendChild(b);
    });
  }

  function pares(vi, vo) {
    var p = el('div', 'pares');
    [['in', 'Entrada', vi], ['out', 'Saída', vo]].forEach(function (x) {
      var d = el('div', 'par'); var s = el('small'); s.appendChild(el('i', 'chave ' + x[0])); s.appendChild(document.createTextNode(x[1])); d.appendChild(s);
      var v = bps(x[2]); var b = el('b', 'num', v.n); if (v.u) b.appendChild(el('u', null, v.u)); d.appendChild(b); p.appendChild(d);
    });
    return p;
  }
  function medidor(uso, nv) {
    var m = el('div', 'meter'); m.dataset.n = nv; m.setAttribute('role', 'img'); m.setAttribute('aria-label', 'Uso ' + pct(uso));
    var i = el('i'); i.style.width = Math.min(100, Math.max(uso ? 1.5 : 0, uso || 0)) + '%'; m.appendChild(i); return m;
  }

  // ---------- filtros ----------
  function setFiltro(f) {
    S.filtro = f; try { localStorage.setItem('links-filtro', f); } catch (e) {}
    renderFiltros(); renderLista(); window.scrollTo({ top: 0, behavior: 'smooth' });
  }
  function renderFiltros() {
    var nav = $('#filtros'); nav.textContent = '';
    var al = alertas().length;
    var ops = [['todos', 'Todos'], ['alertas', 'Alertas']].concat(S.snap.secoes.map(function (s) { return [s.id, s.titulo]; }));
    if (!ops.some(function (o) { return o[0] === S.filtro; })) S.filtro = 'todos';
    ops.forEach(function (o) {
      var b = el('button', 'chip', o[1]); b.type = 'button'; b.setAttribute('aria-pressed', S.filtro === o[0] ? 'true' : 'false');
      if (o[0] === 'alertas' && al) { var n = el('span', 'n', al); n.setAttribute('aria-label', al + ' alertas'); b.appendChild(n); }
      b.addEventListener('click', function () { setFiltro(o[0]); });
      nav.appendChild(b);
    });
  }

  // ---------- lista ----------
  function renderLista() {
    var lista = $('#lista'); lista.textContent = '';
    var lim = S.snap.limites;
    if (S.filtro === 'alertas') {
      var al = alertas().sort(function (a, b) { return (ORDEM[b.l.estado] - ORDEM[a.l.estado]) || 0; });
      var sec = el('section', 'secao');
      var cab = el('div', 'secao-cab'); cab.appendChild(el('h2', null, 'Alertas')); cab.appendChild(el('span', 'q', al.length + (al.length === 1 ? ' link' : ' links'))); sec.appendChild(cab);
      if (!al.length) {
        var v = el('div', 'vazio'); v.appendChild(el('b', null, 'Nenhum alerta agora')); v.appendChild(document.createTextNode('Os ' + todosLinks().length + ' links estão normais.')); sec.appendChild(v);
      } else {
        var g = el('div', 'grade'); al.forEach(function (x) { g.appendChild(card(x.l, lim, x.s.titulo)); }); sec.appendChild(g);
      }
      lista.appendChild(sec); return;
    }
    S.snap.secoes.forEach(function (s) {
      if (S.filtro !== 'todos' && S.filtro !== s.id) return;
      var sec = el('section', 'secao'); sec.setAttribute('aria-labelledby', 'sec-' + s.id);
      var cab = el('div', 'secao-cab'); var h = el('h2', null, s.titulo); h.id = 'sec-' + s.id; cab.appendChild(h);
      if (s.detalhe) cab.appendChild(el('small', null, s.detalhe));
      var nal = s.links.filter(function (l) { return l.estado !== 'ok'; }).length;
      cab.appendChild(el('span', 'q', nal ? nal + ' de ' + s.links.length + ' com alerta' : s.links.length + (s.links.length === 1 ? ' link' : ' links')));
      sec.appendChild(cab);
      var g = el('div', 'grade'); s.links.forEach(function (l) { g.appendChild(card(l, lim)); }); sec.appendChild(g);
      lista.appendChild(sec);
    });
    var fonte = $('#fonte');
    fonte.textContent = 'Fonte: Zabbix da LV Network' + (S.snap.zabbix && S.snap.zabbix.versao ? ' ' + S.snap.zabbix.versao : '') + ' · dados de ' + hora(S.snap.gerado);
  }

  function subtitulo(l) {
    var p = [l.local];
    if (l.rotas && l.rotas.length) p.push(l.rotas.join(' + '));
    else if (l.interfaces && l.interfaces.length) p.push(l.interfaces.map(abrev).join(' + '));
    return p.filter(Boolean).join(' · ');
  }

  function card(l, lim, secaoNome) {
    var e = ESTADOS[l.estado] || ESTADOS['sem-dados'];
    var c = el('button', 'card'); c.type = 'button'; c.dataset.estado = l.estado;
    c.setAttribute('aria-label', l.nome + ', ' + e.rot + (l.motivos && l.motivos.length ? ': ' + l.motivos.join('; ') : '') + '. Entrada ' + bpsTxt(l['in']) + ', saída ' + bpsTxt(l.out) + ', uso ' + pct(l.uso) + '. Abrir detalhes');
    var cab = el('div', 'card-cab');
    var st = el('span', 'st'); st.dataset.e = l.estado; st.innerHTML = svg(e.ic); cab.appendChild(st);
    var ttl = el('div', 'ttl'); ttl.appendChild(el('b', null, l.nome)); ttl.appendChild(el('small', null, secaoNome ? secaoNome + ' · ' + subtitulo(l) : subtitulo(l))); cab.appendChild(ttl);
    var up = el('div', 'uso-pct');
    if (l.estado !== 'ok') { var bd = el('span', 'badge', e.rot); bd.dataset.e = l.estado; up.appendChild(bd); up.appendChild(el('small', 'num', pct(l.uso) + ' de uso')); }
    else { up.appendChild(el('b', 'num', pct(l.uso))); up.appendChild(el('small', null, 'de uso')); }
    cab.appendChild(up); c.appendChild(cab);

    var meio = el('div', 'card-meio');
    meio.appendChild(pares(l['in'], l.out));
    meio.appendChild(sparkline(l.spark, l.cap));
    c.appendChild(meio);
    var base = el('div', 'card-base');
    var md = medidor(l.uso, nivelUso(l.uso, lim)); md.classList.add('fino'); base.appendChild(md);

    var rod = el('div', 'rodape');
    var o = l.optica || {};
    if (o.rx) { var r = el('span'); r.innerHTML = svg('luz', 2); r.appendChild(document.createTextNode('RX ' + dbm(o.rx.v) + ' dBm')); if (o.rx.nivel === 'aviso' || o.rx.nivel === 'alarme') r.dataset.n = o.rx.nivel; rod.appendChild(r); }
    if (o.tx && (o.tx.nivel === 'aviso' || o.tx.nivel === 'alarme')) { var tx = el('span'); tx.dataset.n = o.tx.nivel; tx.innerHTML = svg('luz', 2); tx.appendChild(document.createTextNode('TX ' + dbm(o.tx.v) + ' dBm')); rod.appendChild(tx); }
    var er = el('span', null, inteiro(l.erros1h) + (l.erros1h === 1 ? ' erro/1h' : ' erros/1h'));
    if (l.erros1h >= lim.erros_critico) er.dataset.n = 'alarme'; else if (l.erros1h >= lim.erros_atencao) er.dataset.n = 'aviso';
    rod.appendChild(er);
    if (l.portas && l.portas.total > 1) { var pt = el('span', null, l.portas.up + '/' + l.portas.total + ' portas'); if (l.portas.up < l.portas.total) pt.dataset.n = 'alarme'; rod.appendChild(pt); }
    rod.appendChild(el('span', 'cap', 'de ' + capTxt(l.cap)));
    base.appendChild(rod);
    c.appendChild(base);

    // o motivo de uso já aparece no medidor; os outros (portas, RX, erros) vão escritos
    var mots = (l.motivos || []).filter(function (t) { return !/^Uso em/.test(t); });
    if (l.estado !== 'ok' && mots.length) {
      var m = el('span', 'motivo'); m.innerHTML = svg(e.ic, 2.4); m.appendChild(el('span', null, mots.join(' · '))); c.appendChild(m);
    }
    c.addEventListener('click', function () { abrir(l.id); });
    return c;
  }

  // ---------- sparkline (6 h, máximo de cada 5 min) ----------
  function sparkline(sp, cap) {
    var NS = 'http://www.w3.org/2000/svg';
    var s = document.createElementNS(NS, 'svg'); s.setAttribute('class', 'spark'); s.setAttribute('viewBox', '0 0 100 40'); s.setAttribute('preserveAspectRatio', 'none');
    s.setAttribute('aria-hidden', 'true');
    if (!sp || !sp['in']) return s;
    var a = sp['in'], b = sp.out, n = Math.max(a.length, b.length);
    var mx = 1000; // kbps: piso de 1 Mbps, assim um link parado aparece como linha reta
    a.concat(b).forEach(function (v) { if (v != null && v > mx) mx = v; });
    function pts(arr) {
      var d = '', on = false;
      arr.forEach(function (v, i) {
        if (v == null) { on = false; return; }
        var x = n > 1 ? i / (n - 1) * 100 : 0, y = 38 - v / mx * 35;
        d += (on ? 'L' : 'M') + x.toFixed(2) + ' ' + y.toFixed(2); on = true;
      });
      return d;
    }
    var di = pts(a);
    if (di) {
      var first = a.findIndex(function (v) { return v != null; }), last = a.length - 1 - a.slice().reverse().findIndex(function (v) { return v != null; });
      var area = document.createElementNS(NS, 'path'); area.setAttribute('class', 'a');
      area.setAttribute('d', di + 'L' + (last / (n - 1) * 100).toFixed(2) + ' 38L' + (first / (n - 1) * 100).toFixed(2) + ' 38Z'); s.appendChild(area);
    }
    [['o', b], ['i', a]].forEach(function (x) { var p = document.createElementNS(NS, 'path'); p.setAttribute('class', x[0]); p.setAttribute('d', pts(x[1])); s.appendChild(p); });
    return s;
  }

  // ---------- detalhe ----------
  function abrir(id) {
    if (location.hash !== '#/link/' + id) location.hash = '#/link/' + id;
    else rota();
  }
  function fechar() {
    if (/^#\/link\//.test(location.hash)) history.back();
  }
  window.addEventListener('hashchange', rota);

  var ultimoFoco = null;
  function rota() {
    var m = /^#\/link\/([A-Za-z0-9_.-]+)/.exec(location.hash);
    var folha = $('#folha'), veu = $('#veu');
    if (m) {
      var novo = S.aberto !== m[1];
      S.aberto = m[1];
      if (folha.hidden) {
        ultimoFoco = document.activeElement;
        folha.hidden = false; veu.hidden = false; document.body.style.overflow = 'hidden';
        requestAnimationFrame(function () { folha.classList.add('on'); veu.classList.add('on'); folha.focus({ preventScroll: true }); });
      }
      if (novo) { S.det = null; $('#folhaCorpo').textContent = ''; preencherCabProvisorio(); }
      carregarDetalhe();
    } else if (!folha.hidden) {
      S.aberto = null; S.det = null; clearTimeout(S.timerDet);
      folha.classList.remove('on'); veu.classList.remove('on'); document.body.style.overflow = '';
      setTimeout(function () { if (!S.aberto) { folha.hidden = true; veu.hidden = true; } }, 340);
      if (ultimoFoco && ultimoFoco.focus) try { ultimoFoco.focus({ preventScroll: true }); } catch (e) {}
    }
  }
  $('#voltar').addEventListener('click', function () { if (history.length > 1) fechar(); else location.hash = ''; });
  $('#veu').addEventListener('click', fechar);
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') { if (!$('#menu').hidden) fecharMenu(); else if (S.aberto) fechar(); }
  });

  function acharNoSnap(id) {
    if (!S.snap) return null;
    var r = null;
    todosLinks().forEach(function (x) { if (x.l.id === id) r = x; });
    if (!r) (S.snap.totais || []).forEach(function (t) { if (t.id === id) r = { l: t, s: null, total: true }; });
    return r;
  }
  function preencherCabProvisorio() {
    var x = acharNoSnap(S.aberto);
    $('#folhaTitulo').textContent = x ? x.l.nome : 'Carregando…';
    $('#folhaSub').textContent = x ? (x.total ? (x.l.detalhe || 'Total') : x.s.titulo + ' · ' + subtitulo(x.l)) : '';
    $('#folhaBadge').hidden = true;
  }
  function renderCabFolha() {
    var x = acharNoSnap(S.aberto); if (!x) return;
    preencherCabProvisorio();
    var bd = $('#folhaBadge');
    if (!x.total) { var e = ESTADOS[x.l.estado] || ESTADOS['sem-dados']; bd.hidden = false; bd.dataset.e = x.l.estado; bd.textContent = e.rot; }
  }

  function carregarDetalhe() {
    clearTimeout(S.timerDet);
    var id = S.aberto, per = S.periodo; if (!id) return;
    var g = $('.graf', $('#folhaCorpo')); if (g) g.classList.add('recarregando');
    api('/api/link/' + encodeURIComponent(id) + '?periodo=' + per).then(function (d) {
      if (S.aberto !== id) return;
      S.det = d; renderDetalhe();
    }).catch(function (e) {
      if (e.message === 'sessao' || S.aberto !== id) return;
      var corpo = $('#folhaCorpo');
      if (!S.det) { corpo.textContent = ''; var v = el('div', 'vazio'); v.appendChild(el('b', null, 'Não deu para carregar o detalhe')); v.appendChild(document.createTextNode(e.message)); corpo.appendChild(v); }
    }).then(function () {
      var g2 = $('.graf', $('#folhaCorpo')); if (g2) g2.classList.remove('recarregando');
      if (S.aberto === id && !document.hidden) S.timerDet = setTimeout(carregarDetalhe, DETALHE_MS);
    });
  }

  function renderDetalhe() {
    var d = S.det, corpo = $('#folhaCorpo'), x = acharNoSnap(d.id);
    var rolagem = corpo.scrollTop;
    corpo.textContent = '';
    renderCabFolha();
    var link = d.link && !d.link.total ? d.link : (x ? x.l : null);
    var lim = S.snap ? S.snap.limites : null;

    if (link && !d.link.total && link.estado !== 'ok' && link.motivos && link.motivos.length) {
      var ul = el('ul', 'motivos');
      link.motivos.forEach(function (m) {
        var li = el('li'); li.dataset.e = /fora|crítico|portas fora/i.test(m) || ['fora', 'degradado', 'critico'].indexOf(link.estado) >= 0 ? 'danger' : 'warn';
        li.innerHTML = svg(ESTADOS[link.estado].ic, 2.2); li.appendChild(el('span', null, m)); ul.appendChild(li);
      });
      corpo.appendChild(ul);
    }

    // agora
    if (link) {
      var b = el('div', 'bloco');
      var ag = el('div', 'agora'); var p = pares(link['in'], link.out); while (p.firstChild) ag.appendChild(p.firstChild);
      var uso = el('div', 'uso'); var nv = nivelUso(link.uso, lim);
      uso.appendChild(medidor(link.uso, nv));
      var leg = el('div', 'meter-leg'); leg.style.marginTop = '6px';
      leg.appendChild(el('span', null, 'Uso ' + pct(link.uso)));
      var capt = 'de ' + capTxt(link.cap); if (link.cap_total && link.cap && link.cap_total > link.cap) capt += ' no ar (' + capTxt(link.cap_total) + ' no total)';
      leg.appendChild(el('span', null, capt)); uso.appendChild(leg); ag.appendChild(uso);
      b.appendChild(ag);
      corpo.appendChild(b);
    }

    // gráfico
    var bg = el('div', 'bloco');
    var h = el('h3', null, 'Tráfego'); bg.appendChild(h);
    var seg = el('div', 'seg'); seg.setAttribute('role', 'group'); seg.setAttribute('aria-label', 'Período do gráfico');
    [['1h', '1 h'], ['6h', '6 h'], ['24h', '24 h'], ['7d', '7 d'], ['30d', '30 d']].forEach(function (o) {
      var bt = el('button', null, o[1]); bt.type = 'button'; bt.setAttribute('aria-pressed', S.periodo === o[0] ? 'true' : 'false');
      bt.setAttribute('aria-label', 'Últimas ' + o[1].replace(' h', ' horas').replace(' d', ' dias').replace('1 horas', '1 hora'));
      bt.addEventListener('click', function () {
        if (S.periodo === o[0]) return;
        S.periodo = o[0]; try { localStorage.setItem('links-periodo', o[0]); } catch (e) {}
        seg.querySelectorAll('button').forEach(function (z) { z.setAttribute('aria-pressed', z === bt ? 'true' : 'false'); });
        carregarDetalhe();
      });
      seg.appendChild(bt);
    });
    bg.appendChild(seg);
    var graf = el('div', 'graf'); bg.appendChild(graf);
    var legd = el('div', 'legenda');
    [['in', 'Entrada'], ['out', 'Saída']].forEach(function (q) { var s = el('span'); s.appendChild(el('i', 'chave ' + q[0])); s.appendChild(document.createTextNode(q[1])); legd.appendChild(s); });
    legd.appendChild(el('span', 'nota', 'máximo de cada ' + passoTxt(d.serie.passo)));
    bg.appendChild(legd);
    var dl = el('dl', 'picos');
    [['in', 'Pico de entrada', d.serie.pico_in, d.serie.media_in], ['out', 'Pico de saída', d.serie.pico_out, d.serie.media_out]].forEach(function (q) {
      var w = el('div'); var dt = el('dt'); dt.appendChild(el('i', 'chave ' + q[0])); dt.appendChild(document.createTextNode(q[1])); w.appendChild(dt);
      var dd = el('dd', 'num', q[2] && q[2].v != null ? bpsTxt(q[2].v) : '—');
      var quando = q[2] && q[2].t ? (S.periodo === '1h' || S.periodo === '6h' || S.periodo === '24h' ? dia(q[2].t) + ' às ' + hora(q[2].t) : dia(q[2].t) + ' · ' + hora(q[2].t) + ' (hora)') : '';
      dd.appendChild(el('small', null, (quando ? quando + ' · ' : '') + 'média ' + bpsTxt(q[3])));
      w.appendChild(dd); dl.appendChild(w);
    });
    bg.appendChild(dl);
    bg.appendChild(tabelaDados(d.serie));
    corpo.appendChild(bg);
    desenharGrafico(graf, d.serie, link);

    // rotas
    if (d.portas) {
      var comRot = d.portas.filter(function (p) { return p.rotulo && p.papel === 'trafego'; });
      if (comRot.length > 1) {
        var br = el('div', 'bloco'); br.appendChild(el('h3', null, 'Rotas'));
        var rs = el('div', 'rotas');
        comRot.forEach(function (p) {
          var r = el('div', 'rota'); var t = el('b'); t.appendChild(pillPorta(p.status)); t.appendChild(document.createTextNode(' ' + p.rotulo)); r.appendChild(t);
          r.appendChild(el('span', 'num', 'Entrada ' + bpsTxt(p['in']))); r.appendChild(el('span', 'num', 'Saída ' + bpsTxt(p.out))); rs.appendChild(r);
        });
        br.appendChild(rs); corpo.appendChild(br);
      }
      // portas
      var bp = el('div', 'bloco'); bp.appendChild(el('h3', null, 'Portas'));
      var lp = el('ul', 'portas');
      d.portas.forEach(function (p) { lp.appendChild(itemPorta(p)); });
      bp.appendChild(lp);
      if (d.portas.some(function (p) { return p.papel === 'membros'; })) bp.appendChild(el('p', 'nota-p', 'A capacidade soma as portas físicas do trunk que estão no ar. Erros e RX/TX vêm das portas físicas.'));
      corpo.appendChild(bp);
    } else if (d.link && d.link.total) {
      var bt2 = el('div', 'bloco'); bt2.appendChild(el('h3', null, 'Links somados'));
      var lt = el('ul', 'portas');
      d.link.links.forEach(function (id) {
        var y = acharNoSnap(id); if (!y) return;
        var li = el('li', 'porta'); var cb = el('div', 'porta-cab'); var st = el('span', 'st'); st.dataset.e = y.l.estado; st.style.width = st.style.height = '22px'; st.innerHTML = svg(ESTADOS[y.l.estado].ic);
        cb.appendChild(st); cb.appendChild(el('b', null, y.l.nome)); cb.appendChild(el('span', 'papel num', bpsTxt(y.l['in']) + ' / ' + bpsTxt(y.l.out)));
        li.appendChild(cb); li.style.cursor = 'pointer'; li.tabIndex = 0;
        li.addEventListener('click', function () { location.replace('#/link/' + id); });
        li.addEventListener('keydown', function (ev) { if (ev.key === 'Enter') location.replace('#/link/' + id); });
        lt.appendChild(li);
      });
      bt2.appendChild(lt); corpo.appendChild(bt2);
    }
    var nota = el('p', 'nota-p', 'Atualizado às ' + hora(d.gerado) + '. ' + (d.serie.fonte === 'tendencia' ? 'Períodos de 7 e 30 dias usam a tendência horária do Zabbix (máximo de cada hora).' : 'Leituras de 1 minuto do Zabbix.'));
    nota.style.textAlign = 'center'; corpo.appendChild(nota);
    corpo.scrollTop = rolagem;
  }

  function passoTxt(s) {
    if (s < 3600) return Math.round(s / 60) + ' min';
    var hh = s / 3600; return hh === 1 ? 'hora' : hh + ' h';
  }
  function pillPorta(st) {
    var p = el('span', 'pill'); p.dataset.s = st === 1 ? 'up' : st == null ? 'na' : 'down'; p.textContent = st === 1 ? 'No ar' : st == null ? '?' : 'Fora';
    return p;
  }
  var PAPEIS = { trafego: 'tráfego', membros: 'membro do trunk', outra_ponta: 'outra ponta' };
  function itemPorta(p) {
    var li = el('li', 'porta');
    var cab = el('div', 'porta-cab'); cab.appendChild(pillPorta(p.achada ? p.status : null));
    cab.appendChild(el('b', null, p.sigla + ' · ' + abrev(p['if'])));
    cab.appendChild(el('span', 'papel', (p.rotulo ? p.rotulo + ' · ' : '') + (PAPEIS[p.papel] || p.papel))); li.appendChild(cab);
    li.appendChild(el('span', 'alias', p.achada ? (p.equip + (p.alias ? ' — ' + p.alias : '')) : 'Não encontrada no Zabbix'));
    if (!p.achada) return li;
    var dl = el('dl');
    function item(rot, val, sub, nivel) {
      var w = el('div'); w.appendChild(el('dt', null, rot)); var dd = el('dd', 'num', val); if (sub) dd.appendChild(el('small', null, sub)); if (nivel) dd.dataset.n = nivel; w.appendChild(dd); dl.appendChild(w);
    }
    item('Entrada', bpsTxt(p['in'])); item('Saída', bpsTxt(p.out)); item('Velocidade', capTxt(p.speed));
    var o = p.optica || {};
    ['rx', 'tx'].forEach(function (k) {
      var q = o[k]; if (!q) return;
      var sub = [];
      if (q.lanes) sub.push('L' + q.lane);
      if (q.lim && q.lim[0] != null) sub.push('mín. ' + dbm(q.lim[0]));
      item(k.toUpperCase() + ' (dBm)', dbm(q.v), sub.join(' · '), q.nivel === 'aviso' || q.nivel === 'alarme' ? q.nivel : null);
    });
    if (!o.rx && !o.tx) item('RX/TX', '—', p.papel === 'trafego' && /Eth-Trunk/.test(p['if']) ? 'nos membros' : 'sem leitura');
    var lim = S.snap ? S.snap.limites : { erros_atencao: 1, erros_critico: 1000 };
    var ne = p.erros1h >= lim.erros_critico ? 'alarme' : p.erros1h >= lim.erros_atencao ? 'aviso' : null;
    item('Erros 1 h', inteiro(p.erros1h), p.erros24h != null ? inteiro(p.erros24h) + ' em 24 h' : null, ne);
    item('Descartes 1 h', inteiro(p.desc1h), p.desc24h != null ? inteiro(p.desc24h) + ' em 24 h' : null);
    li.appendChild(dl);
    return li;
  }

  function tabelaDados(serie) {
    var det = el('details', 'tabela'); det.appendChild(el('summary', null, 'Ver dados em tabela'));
    var wrap = el('div', 'rolar'); var t = el('table'); var th = el('thead'); var tr = el('tr');
    ['Horário', 'Entrada', 'Saída'].forEach(function (x) { tr.appendChild(el('th', null, x)); }); th.appendChild(tr); t.appendChild(th);
    var tb = el('tbody');
    for (var i = serie['in'].length - 1; i >= 0; i--) {
      var ts = serie.inicio + i * serie.passo; var r = el('tr');
      r.appendChild(el('td', null, (serie.passo >= 3600 ? dia(ts) + ' ' : '') + hora(ts)));
      r.appendChild(el('td', 'num', bpsTxt(serie['in'][i]))); r.appendChild(el('td', 'num', bpsTxt(serie.out[i]))); tb.appendChild(r);
    }
    t.appendChild(tb); wrap.appendChild(t); det.appendChild(wrap);
    return det;
  }

  // ---------- gráfico do detalhe ----------
  function escalaBonita(mx) {
    if (!mx || mx <= 0) return { max: 1e6, passo: 2.5e5 };
    var bruto = mx / 4, pot = Math.pow(10, Math.floor(Math.log10(bruto))), f = bruto / pot;
    var passo = (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * pot;
    return { max: Math.ceil(mx / passo) * passo, passo: passo };
  }
  function rotuloEixo(v, unid) {
    var div = unid === 'Gbps' ? 1e9 : unid === 'Mbps' ? 1e6 : unid === 'kbps' ? 1e3 : 1;
    var x = v / div; return nf(x % 1 ? (x * 10 % 1 ? 2 : 1) : 0).format(x);
  }
  function desenharGrafico(box, serie, link) {
    var NS = 'http://www.w3.org/2000/svg';
    box.textContent = '';
    var W = Math.max(280, box.clientWidth || 320), H = 240, pl = 44, pr = 8, pt = 22, pb = 26;
    var s = document.createElementNS(NS, 'svg'); s.setAttribute('viewBox', '0 0 ' + W + ' ' + H); s.setAttribute('role', 'img');
    var a = serie['in'], b = serie.out, n = a.length;
    var mx = 0; a.concat(b).forEach(function (v) { if (v != null && v > mx) mx = v; });
    var esc = escalaBonita(mx * 1.05);
    var unid = bps(esc.max).u || 'bps';
    s.setAttribute('aria-label', 'Gráfico de tráfego: pico de entrada ' + bpsTxt(serie.pico_in && serie.pico_in.v) + ', pico de saída ' + bpsTxt(serie.pico_out && serie.pico_out.v) + '. A tabela abaixo tem os valores.');
    function X(i) { return pl + (n > 1 ? i / (n - 1) : 0) * (W - pl - pr); }
    function Y(v) { return pt + (1 - v / esc.max) * (H - pt - pb); }
    function mk(tag, attrs, txt) { var e = document.createElementNS(NS, tag); for (var k in attrs) e.setAttribute(k, attrs[k]); if (txt != null) e.textContent = txt; s.appendChild(e); return e; }
    for (var v = 0; v <= esc.max + 1; v += esc.passo) {
      mk('line', { x1: pl, x2: W - pr, y1: Y(v), y2: Y(v), 'class': 'grade-l' });
      mk('text', { x: pl - 6, y: Y(v) + 4, 'text-anchor': 'end', 'class': 'eixo' }, rotuloEixo(v, unid));
    }
    mk('text', { x: pl - 6, y: 10, 'text-anchor': 'end', 'class': 'eixo' }, unid);
    // marcas de tempo
    var dur = n * serie.passo, alvo = W < 420 ? 4 : 6;
    var passos = [600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 172800, 604800];
    var pT = passos.filter(function (p) { return dur / p <= alvo; })[0] || 604800;
    var tz = new Date().getTimezoneOffset() * 60;
    var t0 = serie.inicio, t1 = serie.inicio + (n - 1) * serie.passo;
    var tm = Math.ceil((t0 - tz) / pT) * pT + tz;
    for (; tm <= t1; tm += pT) {
      var xi = (tm - t0) / serie.passo; var xx = X(xi);
      if (xx < pl + 14 || xx > W - pr - 14) continue;
      mk('text', { x: xx, y: H - 8, 'text-anchor': 'middle', 'class': 'eixo' }, pT >= 86400 ? dia(tm) : hora(tm));
    }
    // capacidade (só se o tráfego chega perto)
    if (link && link.cap && link.cap <= esc.max) {
      mk('line', { x1: pl, x2: W - pr, y1: Y(link.cap), y2: Y(link.cap), 'class': 'cap' });
      mk('text', { x: W - pr, y: Y(link.cap) - 4, 'text-anchor': 'end', 'class': 'cap-t' }, 'capacidade ' + capTxt(link.cap));
    }
    function caminho(arr) {
      var d = '', on = false;
      arr.forEach(function (v, i) { if (v == null) { on = false; return; } d += (on ? 'L' : 'M') + X(i).toFixed(1) + ' ' + Y(v).toFixed(1); on = true; });
      return d;
    }
    // área da entrada (por trecho contínuo)
    var trechos = [], cur = null;
    a.forEach(function (v, i) { if (v == null) { cur = null; return; } if (!cur) { cur = []; trechos.push(cur); } cur.push(i); });
    trechos.forEach(function (tr) {
      if (tr.length < 2) return;
      var d = 'M' + X(tr[0]).toFixed(1) + ' ' + Y(0).toFixed(1);
      tr.forEach(function (i) { d += 'L' + X(i).toFixed(1) + ' ' + Y(a[i]).toFixed(1); });
      d += 'L' + X(tr[tr.length - 1]).toFixed(1) + ' ' + Y(0).toFixed(1) + 'Z';
      mk('path', { d: d, 'class': 'ar' });
    });
    mk('path', { d: caminho(b), 'class': 'lo' });
    mk('path', { d: caminho(a), 'class': 'li' });
    if (!mx) mk('text', { x: (pl + W - pr) / 2, y: H / 2, 'text-anchor': 'middle', 'class': 'eixo' }, 'Sem tráfego no período');
    // mira + dica
    var mira = mk('line', { y1: pt, y2: H - pb, 'class': 'mira', visibility: 'hidden' });
    var po = mk('circle', { r: 4, fill: 'var(--serie-out)', 'class': 'pt', visibility: 'hidden' });
    var pi = mk('circle', { r: 4, fill: 'var(--serie-in)', 'class': 'pt', visibility: 'hidden' });
    box.appendChild(s);
    var dica = el('div', 'dica'); dica.hidden = true; box.appendChild(dica);
    function mostrar(clientX) {
      var r = s.getBoundingClientRect(); var x = (clientX - r.left) * W / r.width;
      var i = Math.round((x - pl) / (W - pl - pr) * (n - 1)); i = Math.max(0, Math.min(n - 1, i));
      var xx = X(i); mira.setAttribute('x1', xx); mira.setAttribute('x2', xx); mira.setAttribute('visibility', 'visible');
      [[pi, a[i]], [po, b[i]]].forEach(function (q) { if (q[1] == null) q[0].setAttribute('visibility', 'hidden'); else { q[0].setAttribute('cx', xx); q[0].setAttribute('cy', Y(q[1])); q[0].setAttribute('visibility', 'visible'); } });
      var ts = serie.inicio + i * serie.passo;
      dica.textContent = '';
      var hd = el('div', 'h', (serie.passo >= 3600 ? dia(ts) + ' ' : '') + hora(ts) + (serie.passo > 60 ? '–' + hora(ts + serie.passo) : ''));
      dica.appendChild(hd);
      [['in', 'Entrada', a[i]], ['out', 'Saída', b[i]]].forEach(function (q) {
        var l = el('div', 'l'); l.appendChild(el('i', 'chave ' + q[0])); l.appendChild(el('b', 'num', bpsTxt(q[2]))); l.appendChild(el('span', null, q[1])); dica.appendChild(l);
      });
      dica.hidden = false;
      var bw = box.clientWidth, dw = dica.offsetWidth, px = xx / W * bw;
      var left = px + 12; if (left + dw > bw) left = px - dw - 12; if (left < 0) left = 0;
      dica.style.left = left + 'px';
    }
    function esconder() { dica.hidden = true; [mira, pi, po].forEach(function (e) { e.setAttribute('visibility', 'hidden'); }); }
    s.addEventListener('pointermove', function (e) { mostrar(e.clientX); });
    s.addEventListener('pointerdown', function (e) { mostrar(e.clientX); });
    s.addEventListener('pointerleave', function (e) { if (e.pointerType === 'mouse') esconder(); });
    s.addEventListener('pointercancel', esconder);
    s.tabIndex = 0;
    var foco = n - 1;
    s.addEventListener('keydown', function (e) {
      if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
      e.preventDefault(); foco = Math.max(0, Math.min(n - 1, foco + (e.key === 'ArrowRight' ? 1 : -1)));
      var r = s.getBoundingClientRect(); mostrar(r.left + X(foco) / W * r.width);
    });
    s.addEventListener('blur', esconder);
  }
  var redim = null;
  window.addEventListener('resize', function () {
    clearTimeout(redim);
    redim = setTimeout(function () { if (S.det && S.aberto) { var g = $('.graf', $('#folhaCorpo')); if (g) desenharGrafico(g, S.det.serie, S.det.link && !S.det.link.total ? S.det.link : null); } }, 150);
  });

  // ---------- menu, tema, sessão ----------
  function fecharMenu() { $('#menu').hidden = true; $('#menuBtn').setAttribute('aria-expanded', 'false'); }
  $('#menuBtn').addEventListener('click', function (e) {
    e.stopPropagation(); var m = $('#menu'); m.hidden = !m.hidden; $('#menuBtn').setAttribute('aria-expanded', m.hidden ? 'false' : 'true');
    if (!m.hidden) { var f = m.querySelector('button,a'); if (f) f.focus(); }
  });
  document.addEventListener('click', function (e) { if (!$('#menu').hidden && !$('#menu').contains(e.target)) fecharMenu(); });
  function temaTxt() { $('#temaTxt').textContent = document.documentElement.dataset.theme === 'light' ? 'Tema escuro' : 'Tema claro'; }
  $('#temaBtn').addEventListener('click', function () {
    var t = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
    document.documentElement.dataset.theme = t; try { localStorage.setItem('links-tema', t); } catch (e) {}
    temaTxt(); fecharMenu();
    if (S.det && S.aberto) renderDetalhe();
  });
  temaTxt();
  $('#oltLink').href = location.protocol + '//' + location.hostname + ':8443/';
  fetch('/sessao', { credentials: 'same-origin', cache: 'no-store' }).then(function (r) { return r.ok ? r.json() : null; }).then(function (j) {
    if (j && j.authenticated) { var q = $('#quem'); q.textContent = 'Conectado como '; q.appendChild(el('b', null, j.user)); }
  }).catch(function () {});

  atualizar();
  rota();
})();
</script>
</body>
</html>
__INDEX_HTML__
cat > "$WWW/entrar.html" <<'__ENTRAR_HTML__'
<!doctype html>
<html lang="pt-BR" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Entrar · Links · UpDown NOC</title>
<meta name="theme-color" content="#050d17">
<meta name="color-scheme" content="dark light">
<meta name="robots" content="noindex, nofollow">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Links UpDown">
<link rel="manifest" href="/assets/manifest.webmanifest">
<link rel="icon" type="image/svg+xml" href="/assets/favicon.svg">
<link rel="apple-touch-icon" href="/assets/apple-touch-icon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap">
<script>
  try { var t = localStorage.getItem('links-tema'); if (t === 'light' || t === 'dark') document.documentElement.dataset.theme = t; } catch (e) {}
</script>
<style>
:root{
  --brand-500:#0b74ff; --brand-600:#0a5ed6; --cyan-400:#1dc9ff; --grad-brand:linear-gradient(135deg,#0b74ff 0%,#1dc9ff 100%);
  --font-sans:Inter,"Segoe UI Variable","Segoe UI",system-ui,-apple-system,Roboto,Arial,sans-serif;
  --fs-10:.625rem; --fs-12:.75rem; --fs-13:.8125rem; --fs-14:.875rem; --fs-16:1rem; --fs-24:1.5rem; --fs-32:2rem;
  --s-1:4px; --s-2:8px; --s-3:12px; --s-4:16px; --s-5:20px; --s-6:24px; --s-8:32px; --s-10:40px;
  --r-sm:8px; --r-md:12px; --r-lg:16px; --r-xl:22px; --r-full:999px; --dur-1:120ms;
}
:root,:root[data-theme="dark"]{
  color-scheme:dark;
  --text-1:#eaf6ff; --text-3:#7191a7; --line:rgba(122,190,240,.14); --line-strong:rgba(122,190,240,.28);
  --surface-glass:rgba(8,25,43,.72); --surface-input:#061626;
  --danger-bg:rgba(255,95,116,.12); --danger-line:rgba(255,95,116,.30); --danger-text:#ff9caa;
  --ok-bg:rgba(47,214,160,.12); --ok-line:rgba(47,214,160,.32); --ok-text:#6ceabd;
  --focus-ring:0 0 0 3px rgba(29,201,255,.45); --shadow-3:0 28px 70px rgba(0,0,0,.52);
  --auth-bg:radial-gradient(760px 520px at 14% 10%,rgba(11,116,255,.24),transparent 62%),radial-gradient(620px 460px at 88% 86%,rgba(29,201,255,.14),transparent 58%),linear-gradient(150deg,#030b16 0%,#04152a 52%,#061d31 100%);
}
:root[data-theme="light"]{
  color-scheme:light;
  --text-1:#0a1c2e; --text-3:#5f7891; --line:rgba(14,48,82,.13); --line-strong:rgba(14,48,82,.26);
  --surface-glass:rgba(255,255,255,.86); --surface-input:#ffffff;
  --danger-bg:rgba(206,32,58,.09); --danger-line:rgba(206,32,58,.26); --danger-text:#b3182f;
  --ok-bg:rgba(9,154,106,.10); --ok-line:rgba(9,154,106,.28); --ok-text:#0a7a55;
  --focus-ring:0 0 0 3px rgba(11,116,255,.35); --shadow-3:0 24px 60px rgba(12,40,70,.16);
  --auth-bg:radial-gradient(760px 520px at 14% 10%,rgba(11,116,255,.16),transparent 62%),radial-gradient(620px 460px at 88% 86%,rgba(29,201,255,.16),transparent 58%),linear-gradient(150deg,#f6f9fd 0%,#e9f1fb 52%,#e2f1f9 100%);
}
*,*::before,*::after{box-sizing:border-box}
body{margin:0;min-height:100dvh;font-family:var(--font-sans);font-size:var(--fs-14);color:var(--text-1);background:var(--auth-bg);-webkit-font-smoothing:antialiased;
  display:flex;align-items:center;justify-content:center;padding:calc(var(--s-6) + env(safe-area-inset-top,0px)) var(--s-4) calc(var(--s-6) + env(safe-area-inset-bottom,0px))}
:focus-visible{outline:2px solid var(--cyan-400);outline-offset:2px;border-radius:var(--r-sm)}
.cartao{width:100%;max-width:400px;background:var(--surface-glass);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);border:1px solid var(--line-strong);
  border-radius:var(--r-xl);box-shadow:var(--shadow-3);padding:var(--s-8) var(--s-6)}
.logo{display:block;height:40px;width:auto;margin:0 0 var(--s-6)}
.logo.claro{display:none}
:root[data-theme="light"] .logo.escuro{display:none} :root[data-theme="light"] .logo.claro{display:block}
.kicker{font-size:var(--fs-10);font-weight:800;letter-spacing:.12em;text-transform:uppercase;color:var(--cyan-400)}
:root[data-theme="light"] .kicker{color:var(--brand-600)}
h1{margin:var(--s-1) 0 var(--s-2);font-size:var(--fs-24);font-weight:700;letter-spacing:-.02em;line-height:1.2}
p.sub{margin:0 0 var(--s-6);color:var(--text-3);font-size:var(--fs-13);line-height:1.5}
label{display:block;font-size:var(--fs-12);font-weight:600;margin:0 0 6px}
.campo{margin-bottom:var(--s-4)}
input[type=text],input[type=password]{width:100%;height:48px;padding:0 var(--s-4);border-radius:var(--r-md);border:1px solid var(--line-strong);background:var(--surface-input);
  color:var(--text-1);font:inherit;font-size:var(--fs-16);transition:border-color var(--dur-1),box-shadow var(--dur-1)}
input:focus{outline:none;border-color:var(--cyan-400);box-shadow:var(--focus-ring)}
.senha{position:relative}
.senha input{padding-right:56px}
.ver{position:absolute;right:4px;top:4px;width:44px;height:40px;border:0;background:none;color:var(--text-3);border-radius:var(--r-sm);cursor:pointer;display:grid;place-items:center}
.ver svg{width:20px;height:20px}
.lembrar{display:flex;align-items:center;gap:var(--s-2);font-size:var(--fs-13);color:var(--text-3);margin:var(--s-1) 0 var(--s-5);min-height:32px;cursor:pointer}
.lembrar input{width:18px;height:18px;accent-color:var(--brand-500)}
button.entrar{width:100%;height:48px;border:0;border-radius:var(--r-md);background:var(--grad-brand);color:#fff;font:inherit;font-size:var(--fs-16);font-weight:700;cursor:pointer}
button.entrar[disabled]{opacity:.6;cursor:wait}
.msg{display:none;margin:0 0 var(--s-4);padding:var(--s-3) var(--s-4);border-radius:var(--r-md);font-size:var(--fs-13);font-weight:600;border:1px solid}
.msg.on{display:block}
.msg.erro{background:var(--danger-bg);border-color:var(--danger-line);color:var(--danger-text)}
.msg.ok{background:var(--ok-bg);border-color:var(--ok-line);color:var(--ok-text)}
.rodape{margin-top:var(--s-6);font-size:var(--fs-12);color:var(--text-3);text-align:center}
@media (prefers-reduced-motion:reduce){*{transition:none!important}}
</style>
</head>
<body>
<main class="cartao">
  <img class="logo escuro" src="/assets/logo-branco.png" alt="UpDown Internet" width="137" height="40">
  <img class="logo claro" src="/assets/logo-escuro.png" alt="UpDown Internet" width="137" height="40">
  <span class="kicker">UpDown NOC</span>
  <h1>Monitoramento de Links</h1>
  <p class="sub">Trânsito, peering, transporte, anel, OLTs e clientes ISP. Use o mesmo login do Painel das OLTs.</p>
  <div class="msg" id="msg" role="alert"></div>
  <form id="form" method="post" action="/login" novalidate>
    <input type="hidden" name="next" id="next" value="/">
    <div class="campo">
      <label for="user">Usuário</label>
      <input type="text" id="user" name="username" autocomplete="username" autocapitalize="none" autocorrect="off" spellcheck="false" required>
    </div>
    <div class="campo">
      <label for="pass">Senha</label>
      <div class="senha">
        <input type="password" id="pass" name="password" autocomplete="current-password" required>
        <button type="button" class="ver" id="ver" aria-label="Mostrar senha" aria-pressed="false">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>
        </button>
      </div>
    </div>
    <label class="lembrar"><input type="checkbox" id="remember" name="remember" value="1"> Manter conectado neste aparelho (30 dias)</label>
    <button type="submit" class="entrar" id="btn">Entrar</button>
  </form>
  <p class="rodape">Dados do Zabbix da LV Network</p>
</main>
<script>
(function () {
  'use strict';
  var $ = function (s) { return document.querySelector(s); };
  var q = new URLSearchParams(location.search);
  var raw = q.get('next') || '/';
  var next = (raw.charAt(0) === '/' && raw.charAt(1) !== '/' && !/[\\\r\n]/.test(raw) && raw.indexOf('/login') !== 0 && raw.indexOf('/entrar') !== 0) ? raw : '/';
  $('#next').value = next;
  var MSG = {
    INVALID_CREDENTIALS: 'Usuário ou senha incorretos.',
    TOO_MANY_ATTEMPTS: 'Muitas tentativas. Espere 15 minutos e tente de novo.',
    MISSING_FIELDS: 'Preencha usuário e senha.'
  };
  function msg(t, tipo) { var m = $('#msg'); m.textContent = t; m.className = 'msg on ' + (tipo || 'erro'); }
  if (q.get('saiu')) msg('Você saiu. Até a próxima!', 'ok');
  if (q.get('erro')) msg(MSG[String(q.get('erro')).toUpperCase()] || 'Não deu para entrar.');

  // já tem sessão? vai direto
  fetch('/sessao', { credentials: 'same-origin', cache: 'no-store' }).then(function (r) { return r.ok ? r.json() : null; })
    .then(function (d) { if (d && d.authenticated && !q.get('saiu')) location.replace(next); }).catch(function () {});

  $('#ver').addEventListener('click', function () {
    var p = $('#pass'), on = p.type === 'password'; p.type = on ? 'text' : 'password';
    this.setAttribute('aria-pressed', on ? 'true' : 'false'); this.setAttribute('aria-label', on ? 'Esconder senha' : 'Mostrar senha');
  });
  $('#form').addEventListener('submit', function (e) {
    e.preventDefault();
    var u = $('#user').value.trim(), p = $('#pass').value;
    if (!u || !p) { msg(MSG.MISSING_FIELDS); (u ? $('#pass') : $('#user')).focus(); return; }
    var btn = $('#btn'); btn.disabled = true; btn.textContent = 'Entrando…';
    fetch('/login', {
      method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: u, password: p, remember: $('#remember').checked, next: next })
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (d) {
        if (r.ok && d.ok) { location.replace(d.next || next); return; }
        msg(MSG[d.error] || 'Não deu para entrar (HTTP ' + r.status + ').');
        $('#pass').value = ''; $('#pass').focus();
      });
    }).catch(function () { msg('Sem conexão com o servidor.'); }).then(function () { btn.disabled = false; btn.textContent = 'Entrar'; });
  });
  $('#user').focus();
})();
</script>
</body>
</html>
__ENTRAR_HTML__
cat > "$WWW/assets/manifest.webmanifest" <<'__MANIFEST__'
{
  "name": "Links · UpDown NOC",
  "short_name": "Links UpDown",
  "description": "Monitoramento de links da UpDown Internet",
  "lang": "pt-BR",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "orientation": "any",
  "background_color": "#050d17",
  "theme_color": "#01017a",
  "icons": [
    { "src": "/assets/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any maskable" },
    { "src": "/assets/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable" }
  ]
}
__MANIFEST__
cat > "$WWW/assets/favicon.svg" <<'__FAVICON__'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="590 290 830 830">
  <title>UpDown Internet</title>
  <g fill="#0DBBEF">
    <path d="M612 682L680 727L748 682V800C748 892 814 967 898 967C978 967 1044 906 1044 830V727L1113 675L1183 727V820C1183 972 1055 1097 898 1097C740 1097 612 968 612 810Z"/>
    <path d="M1398 730L1329 685L1261 730V600C1261 515 1198 445 1113 445C1032 445 966 508 966 585V685L897 737L827 685V585C827 436 956 315 1113 315C1270 315 1398 443 1398 600Z"/>
  </g>
  <g fill="#9B00FF">
    <path d="M610 500L680 550L750 500V620L680 673L610 620Z"/>
    <path d="M827 738L897 788L967 738V858L897 910L827 858Z"/>
    <path d="M1042 553L1112 500L1182 553V672L1112 623L1042 672Z"/>
    <path d="M1259 790L1329 738L1399 790V910L1329 860L1259 910Z"/>
  </g>
</svg>
__FAVICON__
base64 -d > "$WWW/assets/logo-branco.png" <<'__B64__'
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
f/1t4DAxnFEOAAAAAElFTkSuQmCC
__B64__
base64 -d > "$WWW/assets/logo-escuro.png" <<'__B64__'
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
__B64__
base64 -d > "$WWW/assets/icon-192.png" <<'__B64__'
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
__B64__
base64 -d > "$WWW/assets/icon-512.png" <<'__B64__'
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
2g4gAJCka+pgjtmvvTWwo9m3xOzZ1lWT+3b5ZnvuenveOqmN0FIAAYBUhkGOz+zT3uxeZHRrY3Zr
Y7QvTPOr2J21W+0VW5xlFfaKLSoap0UAAgAZyoOA3+jS2mjdTBXmqhYho0WeapGrCnNVi1yjMLeB
nxmN6x11zrbdesduvb3O2VbrrNvmVOyUil0UHGgYixIg+ZcVkZheusne1z8uzFWFIdUsqEJ+CfhU
wCdBvwpYYn7jxTU6HNvT1+sddc72WlUfo7AAAQCP21mnd9bpA0oUigakAO8NBwACAABAAAAACAAA
AAEAACAAAAAEAACAAAAAEAAAAAIAAEAAAAAIAAAAAQAAIAAAAAQAAIAAAAAQAAAAAgAAQAAAAAgA
AAABAAAgAAAABAAAgAAAAAIAAEAAAAAIAAAAAQAAIAAAAAQAAIAAAAAQAAAAAgAAQAAAAAgAAAAB
AAAgAAAABAAAgAAAABAAAAACAABAAAAACAAAAAEAACAAAAAEAACAAAAAAoASAAABAAAgAAAABAAA
gAAAABAAAAACAABAAAAACAAAAAEAACAAAAAEAACAAAAAEAAAAAIAAEAAAAAIAAAAAQAAIAAAAAQA
AIAAAAAQAAAAAgAAQAAAAAEAACAAAAAEAACAAAAAEAAAAAIAAEAAAAAIAAAAAQAAIAAAAAQAAIAA
AAAQAAAAAgAAQAAAAAgAAAABAAAgAAAABAAAgAAAABAAAAACAABAAAAAAQAAIAAAAAQAAIAAAAAQ
AAAAAgAAQAAAAAgAAAABAAAgAAAABAAAgAAAABAAAAACAABAAAAAUuj/AYmA4eeHpQAWAAAAAElF
TkSuQmCC
__B64__
base64 -d > "$WWW/assets/apple-touch-icon.png" <<'__B64__'
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
RK5CYII=
__B64__
chmod -R a+rX "$WWW"
ok "Painel publicado em $WWW."

# ---------- 4. nginx ----------
BAK=""
if [ -f "$SITE" ]; then BAK="$SITE.bak-$(date +%Y%m%d-%H%M%S)"; cp "$SITE" "$BAK"; fi
cat > "$SITE" <<'EOF'
# Monitoramento de Links (UpDown NOC) — gerado por instalar-links.sh
map $uri $painel_links_cache {
    ~^/assets/  "public, max-age=86400";
    default     "no-store";
}

server {
    listen __PORTA__ ssl;
    server_name __DOMINIO__;
    ssl_certificate     /etc/letsencrypt/live/__DOMINIO__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMINIO__/privkey.pem;

    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Cache-Control $painel_links_cache always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; manifest-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'" always;

    gzip on;
    gzip_min_length 1024;
    gzip_types application/json text/css application/javascript image/svg+xml application/manifest+json;

    root /var/www/painel-links;
    index index.html;

    # consulta de sessão: o mesmo login do Painel das OLTs (uso interno do nginx)
    location = /_auth {
        internal;
        proxy_pass http://127.0.0.1:__PORTA_LOGIN__/auth;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Real-IP $remote_addr;
    }

    # tela de login própria; a senha é conferida pelo serviço de login das OLTs
    location = /entrar {
        try_files /entrar.html =404;
    }
    location = /login {
        if ($request_method != POST) { return 302 /entrar$is_args$args; }
        proxy_pass http://127.0.0.1:__PORTA_LOGIN__;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
    location ~ ^/(logout|sessao)$ {
        proxy_pass http://127.0.0.1:__PORTA_LOGIN__;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # logo, ícones e manifesto (precisam abrir antes do login)
    location /assets/ {
        try_files $uri =404;
    }

    # dados dos links: só com sessão
    location /api/ {
        auth_request /_auth;
        proxy_pass http://127.0.0.1:__PORTA_API__;
        proxy_set_header Host $host;
        proxy_read_timeout 90s;
    }

    # painel: sem sessão vai para o login
    location / {
        auth_request /_auth;
        error_page 401 = @login;
        try_files $uri $uri/ =404;
    }
    location @login {
        return 302 /entrar?next=$request_uri;
    }
}
EOF
sed -i "s|__DOMINIO__|$DOMINIO|g; s|__PORTA__|$PORTA|g; s|__PORTA_API__|$PORTA_API|g; s|__PORTA_LOGIN__|$PORTA_LOGIN|g" "$SITE"
ln -sf "$SITE" /etc/nginx/sites-enabled/painel-links
if ! nginx -t >/tmp/painel-links-nginx.log 2>&1; then
  cat /tmp/painel-links-nginx.log
  if [ -n "$BAK" ]; then cp "$BAK" "$SITE"; else rm -f /etc/nginx/sites-enabled/painel-links; fi
  erro "O nginx recusou a configuração nova; nada foi alterado no nginx."
fi
systemctl reload nginx
ok "nginx atualizado${BAK:+ (cópia da configuração anterior em $BAK)}."

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORTA/tcp" >/dev/null && ok "Firewall (ufw): porta $PORTA liberada."
fi

# ---------- 5. conferência ----------
sleep 1
URL="https://$DOMINIO:$PORTA"
c() { curl -sk --noproxy '*' -o /dev/null -w '%{http_code}' --resolve "$DOMINIO:$PORTA:127.0.0.1" "$URL$1" || true; }
[ "$(c /entrar)" = "200" ] && ok "Tela de login respondendo." || info "A tela de login respondeu HTTP $(c /entrar)."
[ "$(c /)" = "302" ] && ok "Painel protegido: sem sessão vai para o login." || info "O painel respondeu HTTP $(c /) sem sessão (esperado 302)."
[ "$(c /api/links)" = "401" ] && ok "Dados protegidos: sem sessão a API responde 401." || info "A API respondeu HTTP $(c /api/links) sem sessão (esperado 401)."

echo
info "O que o Zabbix devolveu agora:"
runuser -u www-data -- env PAINEL_LINKS_DIR="$CONF" ZABBIX_URL="$ZABBIX_URL" "$PY" "$APP/painel-links.py" testar 2>/dev/null || info "Não deu para listar os links agora: veja journalctl -u painel-links -n 30"

echo
ok "Pronto: $URL"
echo "   Login: o mesmo do Painel das OLTs (python3 /opt/painel-olt/painel-auth.py users)."
echo "   Links: edite $CONF/links.json; o painel relê sozinho em até 30 s."
echo "   Logs:  journalctl -u painel-links -f"
echo "   Se o servidor fica atrás de um roteador/firewall, libere ou redirecione a porta $PORTA/TCP para ele, como a 8443."
