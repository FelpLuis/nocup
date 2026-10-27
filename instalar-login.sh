#!/usr/bin/env bash
# Instala a tela de login do Painel das OLTs (UpDown NOC) neste servidor.
#
#   bash instalar-login.sh
#
# O que faz:
#   1. instala o servico de login (painel-auth) em /opt/painel-olt, rodando como www-data
#   2. cria o primeiro usuario do painel
#   3. reescreve o site do nginx: login proprio no lugar da janela do navegador,
#      painel e /zbx-api so com sessao valida
#   4. copia o painel (painel-olt.html, se estiver na mesma pasta) para /var/www/painel-olt
#
# Pode rodar de novo quando quiser: usuarios, chave e token sao preservados.
set -euo pipefail

DOMINIO="${DOMINIO:-monitoramento.updown.com.br}"
PORTA="${PORTA:-8443}"
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE=/etc/nginx/sites-available/painel-olt

ok()   { printf '\033[32m✔\033[0m %s\n' "$*"; }
info() { printf '\033[36m•\033[0m %s\n' "$*"; }
erro() { printf '\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || erro "Rode como root."
command -v nginx >/dev/null || erro "nginx não está instalado (apt install -y nginx)."
command -v python3 >/dev/null || erro "python3 não encontrado."
[ -f "/etc/letsencrypt/live/$DOMINIO/fullchain.pem" ] || erro "Certificado de $DOMINIO não encontrado em /etc/letsencrypt/live. Gere com o certbot antes."
NGV="$(nginx -V 2>&1)"
[[ "$NGV" == *http_auth_request_module* ]] || erro "Este nginx não tem o módulo auth_request. Instale o pacote nginx-full ou nginx-extras."

# 1. token do Zabbix: reaproveita o que já está no site, senão pergunta
TOKEN=""
[ -f "$SITE" ] && TOKEN="$(grep -oP 'Bearer \K[A-Za-z0-9]+' "$SITE" | head -n1 || true)"
if [[ "$TOKEN" =~ ^[A-Za-z0-9]{16,}$ ]]; then
  ok "Usando o token do Zabbix que já estava no nginx."
else
  read -rsp "Token da API do Zabbix (não aparece na tela): " TOKEN; echo
fi
[[ "$TOKEN" =~ ^[A-Za-z0-9]{16,}$ ]] || erro "Token inválido: esperava só letras e números."

# 2. serviço de login
install -d -m 755 /opt/painel-olt
cat > /opt/painel-olt/painel-auth.py <<'__PAINEL_AUTH_PY__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Login do Painel das OLTs - UpDown NOC

Servico pequeno, so com a biblioteca padrao do Python 3, que o nginx consulta
(auth_request) antes de entregar o painel e o /zbx-api. As senhas ficam com
PBKDF2-SHA256 e a sessao vai num cookie HttpOnly assinado.

  painel-auth.py serve              roda o servico (o systemd chama isto)
  painel-auth.py adduser NOME       cria o usuario ou troca a senha dele
  painel-auth.py deluser NOME       remove o usuario
  painel-auth.py users              lista os usuarios
  painel-auth.py logout-all NOME    derruba todas as sessoes do usuario
  painel-auth.py init               cria a pasta e a chave (o instalador usa)
"""
import base64
import getpass
import grp
import hashlib
import hmac
import json
import os
import re
import secrets
import sys
import threading
import time
import urllib.parse
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = os.environ.get("PAINEL_AUTH_DIR", "/etc/painel-olt")
USERS_FILE = os.path.join(DIR, "users.json")
SECRET_FILE = os.path.join(DIR, "secret.key")
LISTEN = ("127.0.0.1", int(os.environ.get("PAINEL_AUTH_PORT", "8091")))
COOKIE = "painel_olt"
TTL_SHORT = 12 * 3600          # sem "manter conectado": um turno
TTL_LONG = 30 * 86400          # com "manter conectado": 30 dias (telao)
ITERATIONS = 310_000
MAX_FAILS, FAIL_WINDOW, LOCKOUT = 5, 15 * 60, 15 * 60
USER_RE = re.compile(r"^[a-z0-9._-]{2,32}$")
MIN_PASSWORD = 8

LOGIN_HTML = r"""<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Entrar — Painel das OLTs</title>
<meta name="theme-color" content="#050d17">
<meta name="color-scheme" content="dark light">
<meta name="robots" content="noindex, nofollow">
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjU5MCAyOTAgODMwIDgzMCI+CiAgPHRpdGxlPlVwRG93biBJbnRlcm5ldDwvdGl0bGU+CiAgPGcgZmlsbD0iIzBEQkJFRiI+CiAgICA8cGF0aCBkPSJNNjEyIDY4Mkw2ODAgNzI3TDc0OCA2ODJWODAwQzc0OCA4OTIgODE0IDk2NyA4OTggOTY3Qzk3OCA5NjcgMTA0NCA5MDYgMTA0NCA4MzBWNzI3TDExMTMgNjc1TDExODMgNzI3VjgyMEMxMTgzIDk3MiAxMDU1IDEwOTcgODk4IDEwOTdDNzQwIDEwOTcgNjEyIDk2OCA2MTIgODEwWiIvPgogICAgPHBhdGggZD0iTTEzOTggNzMwTDEzMjkgNjg1TDEyNjEgNzMwVjYwMEMxMjYxIDUxNSAxMTk4IDQ0NSAxMTEzIDQ0NUMxMDMyIDQ0NSA5NjYgNTA4IDk2NiA1ODVWNjg1TDg5NyA3MzdMODI3IDY4NVY1ODVDODI3IDQzNiA5NTYgMzE1IDExMTMgMzE1QzEyNzAgMzE1IDEzOTggNDQzIDEzOTggNjAwWiIvPgogIDwvZz4KICA8ZyBmaWxsPSIjOUIwMEZGIj4KICAgIDxwYXRoIGQ9Ik02MTAgNTAwTDY4MCA1NTBMNzUwIDUwMFY2MjBMNjgwIDY3M0w2MTAgNjIwWiIvPgogICAgPHBhdGggZD0iTTgyNyA3MzhMODk3IDc4OEw5NjcgNzM4Vjg1OEw4OTcgOTEwTDgyNyA4NThaIi8+CiAgICA8cGF0aCBkPSJNMTA0MiA1NTNMMTExMiA1MDBMMTE4MiA1NTNWNjcyTDExMTIgNjIzTDEwNDIgNjcyWiIvPgogICAgPHBhdGggZD0iTTEyNTkgNzkwTDEzMjkgNzM4TDEzOTkgNzkwVjkxMEwxMzI5IDg2MEwxMjU5IDkxMFoiLz4KICA8L2c+Cjwvc3ZnPgo=">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@600;700&display=swap">
<style>
/* Mesma tela de acesso do UpDown NOC (public/login.html do Topologia-NOC):
   malha de rede atravessando a página, cartão de vidro à direita. */
:root{
  --brand-500:#0b74ff; --brand-600:#0a5ed6; --cyan-400:#1dc9ff; --cyan-300:#6adfff; --purple-400:#a56bff;
  --grad-brand:linear-gradient(135deg,#0b74ff 0%,#1dc9ff 100%);
  --danger-500:#ff5f74; --ok-500:#2fd6a0;
  --font-sans:Inter,"Segoe UI Variable","Segoe UI",system-ui,-apple-system,Roboto,Arial,sans-serif;
  --font-mono:"JetBrains Mono",ui-monospace,SFMono-Regular,Consolas,monospace;
  --fs-10:.625rem; --fs-11:.6875rem; --fs-12:.75rem; --fs-13:.8125rem; --fs-14:.875rem; --fs-16:1rem; --fs-24:1.5rem; --fs-32:2rem; --fs-44:2.75rem;
  --s-1:4px; --s-2:8px; --s-3:12px; --s-4:16px; --s-5:20px; --s-6:24px; --s-8:32px; --s-10:40px; --s-12:48px;
  --r-sm:8px; --r-md:12px; --r-lg:16px; --r-xl:22px; --r-full:999px;
  --dur-1:120ms; --dur-2:200ms; --ease:cubic-bezier(.2,.7,.3,1);

  color-scheme:dark;
  --bg:#050d17; --surface-2:#0c2438; --surface-3:#103049; --surface-input:#061626; --surface-glass:rgba(8,25,43,.72);
  --line:rgba(122,190,240,.14); --line-strong:rgba(122,190,240,.28);
  --text-1:#eaf6ff; --text-2:#ffffff; --text-3:#7191a7; --text-on-brand:#ffffff;
  --shadow-2:0 12px 32px rgba(0,0,0,.38); --shadow-3:0 28px 70px rgba(0,0,0,.52); --shadow-brand:0 12px 30px rgba(11,116,255,.28);
  --danger-bg:rgba(255,95,116,.12); --danger-line:rgba(255,95,116,.30); --danger-text:#ff9caa;
  --ok-bg:rgba(47,214,160,.12); --ok-line:rgba(47,214,160,.32); --ok-text:#6ceabd;
  --warn-text:#ffd07a;
  --focus-ring:0 0 0 3px rgba(29,201,255,.45);
  --kicker:var(--cyan-400);
  --net-edge:rgba(80,190,255,.22); --net-hot:rgba(29,201,255,.55); --net-node-fill:#071b2c; --net-node-stroke:#55d0ff;
  --net-core-fill:rgba(17,129,255,.16); --net-core-stroke:#1dc9ff; --net-pulse:#6adfff;
  --auth-bg:
    radial-gradient(760px 520px at 14% 10%, rgba(11,116,255,.24), transparent 62%),
    radial-gradient(620px 460px at 88% 86%, rgba(29,201,255,.14), transparent 58%),
    linear-gradient(150deg,#030b16 0%,#04152a 52%,#061d31 100%);
}
@media (prefers-color-scheme: light){
  :root:not([data-theme="dark"]){
    color-scheme:light;
    --bg:#eef3f9; --surface-2:#f5f8fc; --surface-3:#e9f0f8; --surface-input:#ffffff; --surface-glass:rgba(255,255,255,.82);
    --line:rgba(14,48,82,.13); --line-strong:rgba(14,48,82,.26);
    --text-1:#0a1c2e; --text-2:#000000; --text-3:#6b849b;
    --shadow-2:0 10px 26px rgba(12,40,70,.10); --shadow-3:0 24px 60px rgba(12,40,70,.16); --shadow-brand:0 10px 26px rgba(11,116,255,.22);
    --danger-bg:rgba(206,32,58,.09); --danger-line:rgba(206,32,58,.26); --danger-text:#b3182f;
    --ok-bg:rgba(9,154,106,.10); --ok-line:rgba(9,154,106,.28); --ok-text:#0a7a55; --warn-text:#8a5c00;
    --focus-ring:0 0 0 3px rgba(11,116,255,.35);
    --kicker:var(--brand-600);
    --net-edge:rgba(11,116,255,.26); --net-hot:rgba(11,116,255,.5); --net-node-fill:#ffffff; --net-node-stroke:var(--brand-500);
    --net-core-fill:rgba(11,116,255,.12); --net-core-stroke:var(--brand-500); --net-pulse:var(--brand-500);
    --auth-bg:
      radial-gradient(760px 520px at 14% 10%, rgba(11,116,255,.16), transparent 62%),
      radial-gradient(620px 460px at 88% 86%, rgba(29,201,255,.16), transparent 58%),
      linear-gradient(150deg,#f6f9fd 0%,#e9f1fb 52%,#e2f1f9 100%);
  }
}
:root[data-theme="light"]{
  color-scheme:light;
  --bg:#eef3f9; --surface-2:#f5f8fc; --surface-3:#e9f0f8; --surface-input:#ffffff; --surface-glass:rgba(255,255,255,.82);
  --line:rgba(14,48,82,.13); --line-strong:rgba(14,48,82,.26);
  --text-1:#0a1c2e; --text-2:#000000; --text-3:#6b849b;
  --shadow-2:0 10px 26px rgba(12,40,70,.10); --shadow-3:0 24px 60px rgba(12,40,70,.16); --shadow-brand:0 10px 26px rgba(11,116,255,.22);
  --danger-bg:rgba(206,32,58,.09); --danger-line:rgba(206,32,58,.26); --danger-text:#b3182f;
  --ok-bg:rgba(9,154,106,.10); --ok-line:rgba(9,154,106,.28); --ok-text:#0a7a55; --warn-text:#8a5c00;
  --focus-ring:0 0 0 3px rgba(11,116,255,.35);
  --kicker:var(--brand-600);
  --net-edge:rgba(11,116,255,.26); --net-hot:rgba(11,116,255,.5); --net-node-fill:#ffffff; --net-node-stroke:var(--brand-500);
  --net-core-fill:rgba(11,116,255,.12); --net-core-stroke:var(--brand-500); --net-pulse:var(--brand-500);
  --auth-bg:
    radial-gradient(760px 520px at 14% 10%, rgba(11,116,255,.16), transparent 62%),
    radial-gradient(620px 460px at 88% 86%, rgba(29,201,255,.16), transparent 58%),
    linear-gradient(150deg,#f6f9fd 0%,#e9f1fb 52%,#e2f1f9 100%);
}

*,*::before,*::after{box-sizing:border-box}
[hidden]{display:none!important}
html,body{margin:0;min-height:100%}
body{font-family:var(--font-sans);font-size:var(--fs-14);line-height:1.55;color:var(--text-1);background:var(--bg);-webkit-font-smoothing:antialiased}
button,input{font:inherit}
:focus-visible{outline:2px solid var(--cyan-400);outline-offset:2px;border-radius:var(--r-sm)}

.auth{position:relative;overflow:hidden;min-height:100vh;min-height:100dvh;display:grid;grid-template-columns:minmax(0,1.85fr) minmax(448px,1fr);background:var(--auth-bg);color:var(--text-1)}
.auth-visual{position:relative;display:flex;flex-direction:column;justify-content:space-between;gap:var(--s-8);padding:var(--s-10) clamp(var(--s-6),3.4vw,var(--s-12))}
.auth-net{position:absolute;inset:0 auto 0 0;z-index:0;width:100vw;pointer-events:none;opacity:.9}
.auth-net svg{width:100%;height:100%}
.net-edge{fill:none;stroke:var(--net-edge);stroke-width:1.2}
.net-edge.is-hot{stroke:var(--net-hot);stroke-width:1.8}
.net-node{fill:var(--net-node-fill);stroke:var(--net-node-stroke);stroke-width:1.4}
.net-core{fill:var(--net-core-fill);stroke:var(--net-core-stroke);stroke-width:1.6}
.net-label{fill:var(--text-3);font:700 9px var(--font-mono);letter-spacing:.08em}
.net-pulse{fill:var(--net-pulse);filter:drop-shadow(0 0 6px #1dc9ff)}
.net-pulse-anim{animation:net-travel 4.6s linear infinite}
.net-pulse-anim.d2{animation-delay:-1.6s}
.net-pulse-anim.d3{animation-delay:-3.1s}
@keyframes net-travel{0%{transform:translate(0,0);opacity:0}12%{opacity:1}84%{opacity:1}100%{transform:translate(250px,96px);opacity:0}}

.logo{display:block;width:180px;height:auto}
.logo.on-light{display:none}
@media (prefers-color-scheme: light){:root:not([data-theme="dark"]) .logo.on-dark{display:none}:root:not([data-theme="dark"]) .logo.on-light{display:block}}
:root[data-theme="light"] .logo.on-dark{display:none}
:root[data-theme="light"] .logo.on-light{display:block}

.brand-row,.hero,.auth-stats{position:relative}
.auth-tagline{display:block;font-size:clamp(var(--fs-32),3.4vw,var(--fs-44));font-weight:700;letter-spacing:-.035em;line-height:1.15;max-width:13ch;margin:0 0 var(--s-4);text-wrap:balance}
.auth-tagline em{font-style:normal;background:linear-gradient(90deg,var(--text-1),var(--cyan-400));-webkit-background-clip:text;background-clip:text;color:transparent}
.hero p{margin:0;color:var(--text-2);max-width:46ch}
.auth-stats{display:grid;grid-auto-flow:column;grid-auto-columns:minmax(0,1fr);gap:var(--s-5)}
.auth-stats div{min-width:0}
.auth-stats strong{display:block;font-size:clamp(var(--fs-16),1.35vw,var(--fs-24));letter-spacing:-.03em}
.auth-stats small{color:var(--text-2);font-size:var(--fs-11);text-transform:uppercase;letter-spacing:.06em;overflow-wrap:break-word}

.auth-panel{position:relative;z-index:1;display:grid;place-items:center;padding:var(--s-8) max(var(--s-6),env(safe-area-inset-right,0px)) var(--s-8) max(var(--s-6),env(safe-area-inset-left,0px))}
.auth-card{width:min(400px,100%);padding:var(--s-8);border:1px solid var(--line);border-radius:var(--r-xl);background:var(--surface-glass);-webkit-backdrop-filter:blur(18px);backdrop-filter:blur(18px);box-shadow:var(--shadow-3)}
.auth-card .card-logo{display:none;margin-bottom:var(--s-6)}
.kicker{display:block;font-size:var(--fs-10);font-weight:800;letter-spacing:.12em;text-transform:uppercase;color:var(--kicker)}
.auth-card h1{margin:var(--s-2) 0 0;font-size:var(--fs-32);line-height:1.15;font-weight:700;letter-spacing:-.02em}
.sub{margin:var(--s-2) 0 0;color:var(--text-3)}

.auth-form{display:grid;gap:var(--s-4);margin-top:var(--s-6)}
.field{display:grid;gap:var(--s-2);min-width:0}
.field>label{font-size:var(--fs-11);font-weight:700;letter-spacing:.04em;color:var(--text-2);text-transform:uppercase}
.input{width:100%;min-height:44px;padding:0 var(--s-4);border:1px solid var(--line-strong);border-radius:var(--r-md);background:var(--surface-input);color:var(--text-1);font-size:var(--fs-14);outline:none;transition:border-color var(--dur-1) var(--ease),box-shadow var(--dur-1) var(--ease)}
.input::placeholder{color:var(--text-3)}
.input:focus{border-color:var(--cyan-400);box-shadow:var(--focus-ring)}
.input[aria-invalid="true"]{border-color:var(--danger-500)}
.input-affix{position:relative;display:flex;align-items:center}
.input-affix .input{padding-left:42px}
.input-affix.has-action .input{padding-right:46px}
.affix-icon{position:absolute;left:14px;color:var(--text-3);pointer-events:none;display:grid}
.affix-btn{position:absolute;right:6px;width:34px;height:34px;display:grid;place-items:center;border:0;border-radius:var(--r-sm);background:transparent;color:var(--text-2);cursor:pointer}
.affix-btn:hover{background:var(--surface-3);color:var(--text-1)}
.affix-icon svg,.affix-btn svg{width:18px;height:18px}
.field-error{font-size:var(--fs-12);color:var(--danger-text);display:flex;gap:6px;align-items:center}
.field-error svg{width:14px;height:14px;flex:none}
.caps-warn{font-size:var(--fs-12);color:var(--warn-text)}

.switch{display:inline-flex;align-items:center;gap:var(--s-3);cursor:pointer;font-size:var(--fs-13)}
.switch input{position:absolute;opacity:0;width:0;height:0}
.switch-track{position:relative;width:42px;height:24px;flex:none;border-radius:var(--r-full);background:var(--surface-3);border:1px solid var(--line-strong);transition:background var(--dur-2) var(--ease),border-color var(--dur-2) var(--ease)}
.switch-track::after{content:"";position:absolute;top:2px;left:2px;width:18px;height:18px;border-radius:var(--r-full);background:var(--text-2);transition:transform var(--dur-2) var(--ease),background var(--dur-2) var(--ease)}
.switch input:checked+.switch-track{background:var(--grad-brand);border-color:transparent}
.switch input:checked+.switch-track::after{transform:translateX(18px);background:#fff}
.switch input:focus-visible+.switch-track{box-shadow:var(--focus-ring)}
.switch small{display:block;color:var(--text-3);font-size:var(--fs-11)}

.alert{display:flex;gap:var(--s-2);align-items:flex-start;padding:var(--s-3) var(--s-4);border:1px solid var(--danger-line);border-radius:var(--r-md);background:var(--danger-bg);color:var(--danger-text);font-size:var(--fs-13)}
.alert svg{width:16px;height:16px;flex:none;margin-top:2px}
.alert.is-ok{border-color:var(--ok-line);background:var(--ok-bg);color:var(--ok-text)}

.btn-primary{position:relative;display:inline-flex;align-items:center;justify-content:center;width:100%;min-height:48px;padding:0 var(--s-6);border:0;border-radius:var(--r-md);background:var(--grad-brand);color:var(--text-on-brand);font-weight:600;font-size:var(--fs-14);cursor:pointer;transition:transform var(--dur-1),box-shadow var(--dur-1)}
.btn-primary:hover{box-shadow:var(--shadow-brand);transform:translateY(-1px)}
.btn-primary.is-loading{color:transparent;pointer-events:none}
.btn-primary.is-loading::after{content:"";position:absolute;width:16px;height:16px;border:2px solid rgba(255,255,255,.35);border-top-color:#fff;border-radius:var(--r-full);animation:spin .7s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
@keyframes shake{0%,100%{transform:none}25%{transform:translateX(-4px)}75%{transform:translateX(4px)}}
.auth-card.shake{animation:shake .32s var(--ease)}

.auth-foot{margin-top:var(--s-6);padding-top:var(--s-5);border-top:1px solid var(--line);display:flex;gap:var(--s-3);align-items:flex-start;color:var(--text-3);font-size:var(--fs-11);line-height:1.5}
.auth-foot .shield{width:26px;height:26px;flex:none;display:grid;place-items:center;border:1px solid rgba(29,201,255,.30);border-radius:var(--r-sm);color:var(--cyan-400)}
.auth-foot .shield svg{width:14px;height:14px}

@media (max-width:980px){
  .auth{grid-template-columns:1fr}
  .auth-visual{display:none}
  .auth-card .card-logo{display:block}
  .auth-panel{align-items:start;padding-top:calc(var(--s-10) + env(safe-area-inset-top,0px))}
}
@media (max-width:420px){.auth-card{padding:var(--s-6)}}
@media (prefers-reduced-motion: reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
</style>
</head>
<body>
<div class="auth">
  <section class="auth-visual" aria-label="Painel das OLTs da UpDown">
    <div class="auth-net" aria-hidden="true">
      <svg viewBox="0 0 620 620" preserveAspectRatio="xMidYMid slice">
        <path class="net-edge is-hot" d="M70 250 C170 140 220 120 320 160 S470 200 560 110"/>
        <path class="net-edge" d="M70 250 C140 280 200 320 300 300 S440 265 560 360"/>
        <path class="net-edge" d="M150 430 C190 350 220 290 320 160"/>
        <path class="net-edge" d="M300 300 C350 350 400 420 490 450"/>
        <path class="net-edge" d="M320 160 C332 230 318 265 300 300"/>
        <path class="net-edge" d="M490 450 C515 375 480 330 560 360"/>
        <circle class="net-node" cx="70" cy="250" r="12"/>
        <circle class="net-node" cx="150" cy="430" r="12"/>
        <circle class="net-node" cx="560" cy="110" r="12"/>
        <circle class="net-node" cx="560" cy="360" r="12"/>
        <circle class="net-node" cx="490" cy="450" r="12"/>
        <circle class="net-core" cx="320" cy="160" r="26"/>
        <circle class="net-core" cx="300" cy="300" r="22"/>
        <text class="net-label" x="298" y="164">CORE</text>
        <text class="net-label" x="280" y="304">S6730</text>
        <text class="net-label" x="40" y="280">C300</text>
        <text class="net-label" x="120" y="460">C350</text>
        <text class="net-label" x="528" y="92">BGP</text>
        <text class="net-label" x="510" y="386">CASQUEIRO</text>
        <text class="net-label" x="450" y="476">VILA NATAL</text>
        <circle class="net-pulse net-pulse-anim" cx="70" cy="250" r="4"/>
        <circle class="net-pulse net-pulse-anim d2" cx="150" cy="430" r="4"/>
        <circle class="net-pulse net-pulse-anim d3" cx="320" cy="160" r="4"/>
      </svg>
    </div>
    <div class="brand-row">
      <img class="logo on-dark" alt="UpDown Internet" src="data:image/png;base64,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" width="180" height="54">
      <img class="logo on-light" alt="UpDown Internet" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAWgAAABrCAMAAABt2Oj9AAABgFBMVEUkresJbrOsYtvGcPcaH1QnKzJ0ZqnbYedwpfG/P/8hbfgN1vEAwOR/Cf+9bPi+cPpkXd5kNZqvOq+YV63DbvhVqqr/AAA3N6UTr+4A/wB///+6bfzDb/oAagAfY3YfqLqZmf//AH//rP8AqlUA/6oAwOhVKn9VVQBISG1//3+qqqr/P/8AAAAJHC4IuO3IdP0JGy0JGy0JGy0JGy0HGi8A//8JGy3/AP////8JGy1/f/8AAP8AvOb+fv4KtewAuvEFuOkGJSurVf7PafgAx+8Au9wBqfe8fv4DuegAOzsAveQAvOTKbPQAf/8AwuTEcfoAADoAHR1/f38AAFUAf38Amc7HbfZVVaoAAH8Avr5/AH/SePeqVaoAwOXMcfUAqtNVVVW9c/wAydLGbvcAqao9PXy8cfwVrvN/P7+qqv/FcPgAVVUA1PrEbvfDcfmXZ8/Fbv3NmP94PHi4bfvvaPf/qv8CmfwA1ti8bfu2bP+9bfq/f7//VfxVAFVVqv+YZv+RS9tWAAAAgHRSTlMPBA9fBw0FCAUEAxZkAmqzBAUEB60DAQTUAQLn1gIFBQUCBAMDhwYDBwIDBAD8+/0t0o+xEwFOAQFuAgFsAtAMsA4DDgwKBQSNBE0uLgIuzQQIAgMCBVADAgQCDwNKLQYD9A1vAwTR8gQDiAMIiLEF9AUEkQoDBgnLB6oEAwMDBfAw68kAABiDSURBVHja7V0He9pIt8ZxejZle/v67fdOYiE0kpAQooMpNsaAe7fjOHZ62/S/fs+MJNCMRgI7OHH2YfZZxwaNEO8cnTnlPUcxdMYHRn+OERsDPQa6N8wx0J9j5M5ZY6A/x1hYGKuOzzU0bQz0aY1mUu6NpDKW6FMbSuJ2f0hjoE9tzPmAjo+BHgM9BnoM9BjoMdBjoMdAj4EeAz0Gegz0GOgx0GOg3dHgMyGmMQb6s0h0fmUM9Fh1/ImAxsMmVXtpKsPVNYb2FQFt6XDBeu9PXddznwdo3TIgk2pi3BgSabMM+K6S31bpT8tCQwJNDtNXmQ///EDnvM+c/rwSjTdeNjxhLtn2MFjn3m6eTHXktNYy88LyW+3Mq45eTs7UBuTuNDOCgWGWinbBtmu1me1CsdOwi0vDXkZWUZRs8yQ6msxUsl8KvnvkhyKpzpAkpTlIonPuzRgJsxF6g1LZLRZr1VQlk8mk4f9KagYwtzuYvofD6RqmpCYTiUQ8Hk8kkpIyFNDOTEVKynQizJR9U9FnZJooqgxX0LvQeEJWs2FAG6i+k0e34JecXt7pauUQQ/n5I5S/v3MJWX6htttoF7aDol0qVFOZ9J07+3e8kc6kqjG7WIhZCAdEuw3XCjSCRSmZiPuSg7fjsqpQhRcGNLm672CxJVVmJpKpyQuHgetWfEleNfDugq7235YFNw47veVKWXuZ/jItJblr6H0FEdAWqm89rMNun0f5B1v3rRBPA/bT+s2pqYcryL+x4tUneNdESzWKMj8A69rS/5E7QedvFyMPPyRZcKEJdbDqEE4k3zF4pP/Mgq8l+95X0UX2zUNu+ne9q39CL+J2yEioIUBPTf3RfWGY6w+3pna0K2K9gZ53707BmK0jvdxXM1buSsPeTmXuhIxM1S6VGsHzwU4WeqGEXhAK9Koe8Q1v3+ahlnwrkuBsgxcBoOej1klG6K8e0Icg6/HbkZcxLQR6amonf4MAeR/lxDjn729NOWMnXzb8Yr/0TSjMDtTFkmALnY+40ITE0A38QE8P+Ia348lsKNC84RIA+ukAoH1vJG5HjriKQoDemqUo3te1EJyneuP+d66bcdACLb2dSt+JHOmU3dH40ypy5GVKSAS0pnOEj7Bl6m/aUUAHVQcarHkMejdL8UFXwZ2tD7QHopC7qaH6bP+Yu8891WGUtwuDcIbxH7HYjzDjinPq69ZguBKSEOgLw3xDcnzrXU4AdPOTgKYS/TGXsw4HyrN7um/L4UA/GALoh/mejrbt1P6dwaNSIy7MLXd1WkOIZfx2EGh9KEly7ttb5mAdfRKgcxasYDYx1FVI6Hv92ECv+4CevQQvmMQ23i2k7gwz9is2Qhuukbc8QG+IrtjbP+NDz1g4HaADk6KuQtEjVEeI2+IH+uFz8EBIBBpvVNN3hhuVQgM5QOeWUfL2iYBGSvyYU04HaHXYq5AjdfRrgX33kZVoS1sxLBLUqIlwTsMIvpoqTWCk58vc1YdoCzFqQkmKC+fJxGnItQYCnTwm0Np7wXKDQwgjEbwQqWeZU88w/6aP4bqWM3axwTraVhnlKdA/0J+zTZh0gDG2K0EXpZJam5lZqwYcmPRacQMZr/MNLFDQ4LlKMNSk0BHxgFaDDkoydJ5KbPxTkWj+foRrpxZlUwl4q3IvYkFjHbhnI7+po+tap4C5gDHYZhToB/n8Mzjyh+9JJPQIoTVecivVwiu8/UGf2Hi1PcOaI/uZmim+UHCk+j5rVmAlu0DzkhRXlb6Doaj8uwpqXVk8BaA5OUlI04zLyov0og/oGLq085jqjRV0cEXksOgE6L904b4/B0eCjtba9itU4AQ6s2aXcAnCSDaJR+NrM6wj88016iFmA3hdgFc398ItbAq0xi+Q7I8oXA/Ok9HH/PtTAFoVXoWGtNa97wNiJDPRO/zoycr6zanZroWuWu9Q/kkg7wrm3V8eriP9J62hd2dvPgenCpCscuI883LJ52zjwkaNWYn0TAkHBdpxL9rk3qH78MWginAkmhNoQOXCAhtOU7lZ5sJpqA6Zw/kp9aTKDtrTZfb7xRU/0BCiv4zyN+roH/Br0bD0gIX3FuW7K+hyqVaLxdC5LrGjDe0VK9AVmMuuUKHDynxqGwds0ERfLp0klrWc45F2gE4G/S7eQmLnJdHmKQDNWJiAI70T+2H677gvKLlufYzEimuVmh2D6EXMrFVSRRDKQBCoBfoExwrfpMGdjqHc67+TF2cYHZyp2RsdL2jtSFlp96iY2feLNBcPczHkytsuvOdAjRNNx6rGpMgEnWbnUUdw5ECr3HJrRtSc3oU6QKfT1cLRh1gBlGqlRDY6f6wUO7mVkj1TcZy80jUd1AnerrJ6oVPiguMQCMU2sxqpiWlO6iSBYLZ4NQFAN9nL990HzGRempqjB9q/loksDR9HnVP2A11N76dTNRsE9s5+agn0HfaFgMwCuS1+Ldk1VzhBdDsY641ixe98p+ziBPd570BSC8UUo10WORWHghlDyDycZ5cDgJ5nhVVCIqD1TXZeEqaNFGhIHTNLScXVDCha/0Uk5nw6es2JZhKB3U+9Agne5SkB2O8Dpqu2dnAZFTKM4rBWhD4l9vs06RprcziesvGCnXJFu8cqCqJf/suPSGI+LMHEzEuMWnWsPmWBphMMM2qStxtSifabw5XtYLADXpiwfbBmbDA5TFYpFC+tiDKDJvJPvFNl9xJZcPcLvAICtMJK0hNhRp2fNzdioOGW8Su1sKSxX5h8QJvIH7CoFIRRpYbfJs5sGyZu+4FOVxuvXwhTsNj2644Uq2rV8PSnygHNLJCE3ofNkyLmjUJHM+fLDlEjeUygEQN0DPZL5N8LMzONUKqH/7gKZgCMoAlInOSIbkfhl2QX5HSBDrsOObidnAzoGQB6iQHQDuN74OLML76ZDNCJwwi+RgTQiWGBVr8+oNss0OBhM+ZECpQ2MkWUj6WiX8WwQMtouBJlAjSzQBEErOnEmQUas0AXh1EdNjZZoBu4gXKiHWqpw5gd10YBtHxIXXbhaJ4y0MrIgH41GOj0zBJGLNAvkSn+7ni79suJgOZ2bkZ1TItbpZT5jehMA300DNC7eJm1JoohhEYDl5hNE0tDAs1shlkO6PP/QmHm3RkGmtfRQsgmrjFAY6PMunyFcJpaigFaGXJT462Ts2J1MEDPHRNoZrva5oFuY+sAMVta+hrwDI5STKRDMwyY2Oj77s7W2MZH/gBe5mi4PhwLbEhhLmBHL34ROxq3BwONI4DmvOQDdmapo2ntRo1ZDLOsdZj8dxX/dgCBpiWDC7HEbCatWClieQiHpdVi1kOGOFMwxiAYq9+znqHCSWA26IYOuBx2S2m3meuQURTQ8YQL9F4faL9aqCIg4Qf4+g1G0xKOF6M6AMEGhiApzvWBhmCe8e5ciTkstcvaadkwgeaCQ3ssIommkDxs/K8eiHVwLnOrrDE6PWz9PCp/cO/uJ3LkUA0mOykuml1T0GvTA5oJD6VsfoWeGIUGE8GvgHWHWEZHulaKYT7MoSNrgc2TV//G64DlwU4sufue8tE7oe4IRO+4xBkkpb/zLwyn0uUgATrJr0MbTSd75Lpzmqh7nEaAlrPoAiU0SYi2k3OAZtRojXVZSsgyNmIMXlUM5p3NUmdS2y2zFIgoTbB58nTtJ3Q+MYBIG8imgAa494iLR8+h4RaIdWCSkTpYEBIICrzV0hCRVMjALUyIqORGjoSC4djdixdB/OOSP2fI3t6ly3ijL52NJWSwAp2uLXUanESDytnABWz/avbrsqzfitxqAF/pVkDo2jldj/r6JDx5neXx9iDTuOquYIaFVTlzjsIE2dGQEWSKqE7Bk8MqtPgLUdH3GGvllbewnqA2JtBKXhR3hPi0qiLt3y5bcIc11X5QCXERz8xM5wj7YkQfrtolhpCUKWBc4oEm03DsctnyUc0LNktk2k91rJ+57ImK3p8zoIzMXz3DEb9cqnEwZ2jlyv0KAlHOcDmYenpEwdFzBwbS9/hPgqXZ7FFZ/qUtMOsAsvm0hPMPJqFU9W8TaM/s3s+HlqM8NVYe/NFF7csesYMAbWJGSe9nZjBqL7U9wTRuFVm8UkUExnaAdZeZeQlA9wW6DNqF5X2ka/ggoBecrd5ygSaQcgwNx9p+KsiC791jpZrPgkMtz2JA5XyreZPemwHqk4o2vZyCvneRPSFRVx/Q89mtZyvow+VcfnLrrhhoDXUm0DqQkrZ2nsPC5sq6pzpKHGiZWmeiWNjFJtwFHUCV5ckQ1oAd0NFO5uVVY7cNGyVqbBRwYYbnMX0D6wO7PpcH59oHZpNhPOPkbdG8xYUQPoiQ79K3FADQuWQ4qXkzcGdBYkxziERQiAJAbk3dXRGVTmGodCl3HQbdzTraW7asflUWm9CGDGLsaGOJ6umX9lqFpyvSKUcpEbl/5uUu0dKlYnEmwJsGE30Xk1pTjk2Q8EEdpPMTE3AaalIXAlTSuH+JAgyneFYXrU9CXYwk7ffPyV+KhH62XMbWbHfyL/DPH3kB0I0NhFZu9Ch2XcO3GW6XAuKZrqxVa7GZ2lqQQ1d1ZnaEhN1Mam0N6gzXUpUgzxEMR+yoUzlYyCRRDp2Aeqe6BFxNyL1z5okmqiSbjgSUyoT3WWGlGS6djzsjNXSAsfUHBZASu4RAY3CJJ32kfVfqKdC7/0CxtJAUKqCFVmzHiiuGMaN/EbNJQYc72QEs5vvHQ1ih08iI5CXHxRNlz1RbFLDGQz4rkqCqIj/QDIiB8cxHz113rt9RHXnr34ci7lO4tl9GAx1WybJGSpbJh9rTQxPK6U6oxZxuIIvWMfjRngZ4uxjGEj4mR7spADovinSa1k+hQGu5TqEyJFwvXSf2mEDDTumQGLTflpYOh0Wa8BF0DfcKgo/B+H90/RgE/cQQBSnndZfs6QdaYHWYWijQENnAG7XMMHil7ELsShDo9CDiP1DJNiy30LlEIilDQUbcKtg9da/DxN6wNSxSeOhUXNg4COmkj1XrB1oX0kue9fX4VN1xgGJewAlrwyCdspdKbiyEzbAMKLEAnF/1L2QCbW4OAxmRZ0y5S3qYMzMMzgMngc034IjEnOUC/dxf+TAU0MAQ9YA2LBrTGIg0wNUPZ7BARxcNAbXPTcE4spnP578dXDFECb3aMsKNnB4WzgivM2TIj2pklWt20FrATrHqNSRx6ocJjLPdsIp8CvSbHbomK+hRD+jXEC8sQSVPoRIll/ugZl/iMKDBe9wPL36zi37eRzlfr3+Ez4wugSUVsPX6Sj4HMZRefxqUHVw5Kwo4RSAN8rxsLkaVDsJKLHi0UcOq33TKI96sh6Z5nk1tbT1YQesPwTvMO9fea4xiXr1aKNlr4UKdrsyUioRm2hAD/bIaMjeTKtglfwg1X67fBGlotqKKuqlYgn81eQm1NAu9K0fUL/C14KuChmVh9w8JASyUX2xeCD/C8WGMA2c7+6g9f0DrBFfQ9XCg7+6soHPQxGBqa92x573NsJxH7aNSm0CdFsO8VkAbhJm7OyECeqPYATZqRgRzzUZLbK6aFIfO3qCAhLQpIF0vziHqxwLSuRe+iIZWXhzU3UALdgW6iObVRMgE0zqYRxaQzERH9Kr4NUKOhbgQIGV1Z+92EQprOLdo3p+tG+ZVEmDbuVv3OSy+4HMxZlcrgHVfDew73SAC2VcWaHsDOnfg2jfMMkGJVrVm41+5mU4RLom4PCVUaJUrG4tDfxSyHM8nnVsUYmSCrxSYRuZF90YJFE3RD+otDCz7XNgR/Lqdq0e0cCq/OHcO0f0bYiPr+QNL2FOp1N4ubpNOMqSVDOkkA+VssVdHu/Z2IwpoWkgLeGy7TWiciTNgofzItlbSn3S9fRsiLugRKL8mKV+DXjIwZFLPNke/S/3hY/e4ZyvChgvTkuRNI/MkCslCKxxo3Wla434SfJAiXI2kd84kLWsTnJDknSN6HpHwes5tn5Sj/bhEQL87+BB72Vg6KhahUU+xQHokdexdIJ5jMxpoCKdcjeFSo7RhF+E/MnG7YbQMts8PGKIP+/bRDuwnh0/dO7057dbEl0E55Xd69hGx+S1R2sqNwk33mjFtHubyEU8hMr1w0vT5/3Z/2+Pajh2698501ouWitPtwAsI40qRkieCrUWlQ8tD8bgeABr2xxc5zYAoKAZergMQ3qVhPGOA6sCOssevSj2FvFTCH3S++Yyud7f6SP+xU/8nQWjVoiWk+urqwuYCulTf8Tm6Uzvn/sfkvVxIkCwHHqMF4clyKMrmoM5t5DLN1UBm6kRN3l5YnkKC0iu6kcfE7b7cLdKM6F7HAt3pOK8+yZEKQxzZ9a7rR3HqTbf+zv/uSr37xv/+40k0jwNdtCxN9zolBNAK7k6+/oVh9zoaafc/60lPvAza6OYT+t6xQB85Eo3ygx8glgf160dyavbNg53uep2M7uSDH2bZNyeBVnbyZ+0ZKNw6ICWN5ttTaEsoamoXO/E6cxKNh3z4oGnl9nxtg3qK+PHdu3enguNBHT0p59GnAA3sItj27kWuxWkMbUig9QHCyQJd7BzjEiyUm2TUx+Mp4dia3XkNSiL3xPikHo3gXYurTZZz2TlFGT3Synll3tJz5mhaZrJAl4a+u2GP1aCZRP3B1MDxAIwSnTQvzZ0YaJhNA/9i4uo0tDZMolE/LlEC21DSR9abtCSwOoa9qUgDKH3yYTTMD9dbn/58Pc1tKyQL+12StxKoH4ftt9DtzbcMizd5BO29DP9USUTjGxXQhc7xleel9WezYSjP3l+3RtU/V+1/ceNR6+ke5BJchh8FmqeYri4ycN/7uMC2oETliyEUy4NcL0mpoqxXBfxlgTaosOr1Gz8EtkBI4//QrWuja1PcVpOS44kYyzojgI5E+7wS/NYvuJZYZ+kh5rhF2v8SVo5vYfUvDLTDuvqRiEG9e+PN7OzvxAx5/Pvvs7MPb3TX4eu1NU0fQZtii7+5FchwKx592wO6r010egA54l6OGN+k0YM7pSf5TfcI6IDkP6uU9RHaVP7zv5jqcAPTr0mo8RLEpye7k5Pdbr1+6ZKzBuBWHozIHJD6/V2doBGwFJC+4gIdd1u8Ki6Zg8aqEs6EMuwmkjtF8tSAE80iLywynVLjXiMdiZ7AebYoOhtA516/1gyLE1zNoqKMwyuvTqyjk1wO0M9sldj0DcSpW2/LH/uZF9dCnE+yBIScvzgBVuuQIZL0CeBfFmj3jgYt0dINnQ5t9A8BVz0YVSarvcymxUjPCYcC4rI64IhNP33N4QCqHNWj5eLsTIJj5s8m0BHjoGyMFmjKSZdBmVJCvtJa5VTHRcpLiKvuEfEL7lzySsK9CxT3HDRHQMlLkndWmi1LurTKM6Y6okMzL8xRAu30AJFJSPWC7LbW5TZDgplbKZakoDktbST3Ldk7R0/JkD4ick8RkWO8ksgR2dGmBt3YBLGOT7AKwvrZjwzo//RAm3bgIoUx512gaSDEfVlx2Hwu5rJLeponRyrLPeCznuana+VMoTxYtQf08giALuc3/s6UCaS+wKM5jgk07WFDQDM3XfnsmXc01tra43nBpNJC7ulmmXaUl3tsM3KOZJCmkOwB/YimDz9RdawcvLrqcmYISQkYpvjsAy33qlQUCvQirzrkQMPLHtB/deOZ7DkEQMs9oHVrBC74C818B73Z1qrV6tpMda22gdFXDbRC/Q0i0Yn+kJU+0PfQ4eJqy/JJtAv0BaKYfZP6qsPc8/yaT9oMG45f35igEP8TfSVAKz6gfZ5hEoi8iqd2m/Pz0z4hp0C7Nn07AHSWnqLZbPbnOEA34ezxeJI8k+DkQLvPDoLeEaUC/nD51gf0dQKNEi6OCfqWz+qQkiplGshMxXo5KNFI7tkYWTWZJE9hcbU3BTzpPZ/hRECXSlxlHfqqgF7QHaDfO1acLClJR7k2ZacjrUI7yoIruEmBvtCLwb3tnWPTBdp1T5LwdCPJC8cSez2uOn/3Gk7G0J98GPMu0D+7OvpeeVnPUqBzrrfsOHX0Zo/76gGSxEJzJLpfIevp+Ucu0N8+cWwVdw4swiPX04/3+fAjAJrUI2KMzr5Eq73NcFnz3I/lli/6AUTGMmNDJJuWC+x5X8CAVx3fPtLnZD9hcEG/p/U9e/VTrQ5sO+1lgViTO9NAk8QnTS2B3ZCkhsRqDhmKTFJYRNSaDjWVEhl1velRVSESh/ZIBIDMmfYstdU8/du1XGRiYtzTNtGiy9kjT4ABkqz+3uNL+h8wdEKgTWxYvv46Z1hzwGXOK8rcPKUfKRecoKEBz4ybdu9phWxhvtyt8/ecG+86zz1a7rD/N+R1my61AJ7/llRpkNRz3CRyFuVreBTqn22MgUbzYARH/T3UIIZ05AtjoD/T+H9s8KZ0f/V+wwAAAABJRU5ErkJggg==" width="180" height="54">
    </div>
    <div class="hero">
      <span class="auth-tagline">Cada porta PON <em>à vista</em>.</span>
      <p>Tráfego, processamento, memória e temperatura da C300 Casqueiro e da C350 Vila Natal, com alerta antes de a porta saturar.</p>
    </div>
    <div class="auth-stats">
      <div><strong>PON</strong><small>Tráfego por porta ao vivo</small></div>
      <div><strong>Saúde</strong><small>CPU, memória e temperatura</small></div>
      <div><strong>Uplinks</strong><small>Enlaces e LACP da OLT</small></div>
      <div><strong>Alertas</strong><small>Aviso ao passar de 90%</small></div>
    </div>
  </section>

  <section class="auth-panel">
    <main class="auth-card" id="card">
      <div class="card-logo">
        <img class="logo on-dark" alt="UpDown Internet" src="data:image/png;base64,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" width="180" height="54">
        <img class="logo on-light" alt="UpDown Internet" src="data:image/png;base64,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" width="180" height="54">
      </div>
      <span class="kicker">UpDown NOC</span>
      <h1>Painel das OLTs</h1>
      <p class="sub">Entre com o seu usuário do NOC.</p>

      <form class="auth-form" id="formLogin" method="post" action="/login" novalidate>
        <input type="hidden" name="next" id="next" value="/">
        <div class="field">
          <label for="username">Usuário</label>
          <div class="input-affix">
            <span class="affix-icon" data-icon="user"></span>
            <input class="input" id="username" name="username" autocomplete="username" autocapitalize="none" spellcheck="false" placeholder="seu.usuario" required autofocus aria-describedby="errUsername">
          </div>
          <span class="field-error" id="errUsername" hidden></span>
        </div>
        <div class="field">
          <label for="password">Senha</label>
          <div class="input-affix has-action">
            <span class="affix-icon" data-icon="lock"></span>
            <input class="input" id="password" name="password" type="password" autocomplete="current-password" placeholder="••••••••" required aria-describedby="errPassword capsWarn">
            <button class="affix-btn" id="togglePassword" type="button" aria-label="Mostrar senha" aria-pressed="false"></button>
          </div>
          <span class="field-error" id="errPassword" hidden></span>
          <span class="caps-warn" id="capsWarn" hidden>Caps Lock está ativado.</span>
        </div>
        <label class="switch">
          <input type="checkbox" id="remember" name="remember" value="on">
          <span class="switch-track"></span>
          <span>Manter conectado<small>Por 30 dias neste computador, bom para o telão do NOC</small></span>
        </label>
        <div class="alert" id="loginMsg" role="alert" hidden></div>
        <button class="btn-primary" id="submitLogin" type="submit">Entrar no painel</button>
      </form>

      <div class="auth-foot">
        <span class="shield" data-icon="shield"></span>
        <span>Acesso restrito à equipe da UpDown. Esqueceu a senha? Peça a um administrador do NOC para redefinir.</span>
      </div>
    </main>
  </section>
</div>

<script>
(function(){
  'use strict';
  var ICON = {
    user:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>',
    lock:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>',
    eye:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>',
    eyeOff:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9.9 4.2A10 10 0 0 1 12 4c6.5 0 10 8 10 8a17 17 0 0 1-2.2 3.2M6.6 6.6A17 17 0 0 0 2 12s3.5 8 10 8a9.8 9.8 0 0 0 5.4-1.6"/><path d="M14.1 14.1a3 3 0 0 1-4.2-4.2"/><path d="m2 2 20 20"/></svg>',
    alert:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><path d="M12 8v4M12 16h.01"/></svg>',
    check:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 6 9 17l-5-5"/></svg>',
    shield:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>'
  };
  var $ = function(s){ return document.querySelector(s); };
  var form = $('#formLogin'), user = $('#username'), pass = $('#password'), btn = $('#submitLogin'), box = $('#loginMsg'), card = $('#card');
  var MSG = {
    INVALID_CREDENTIALS:'Usuário ou senha incorretos.',
    TOO_MANY_ATTEMPTS:'Muitas tentativas seguidas. Aguarde 15 minutos e tente de novo.',
    MISSING_FIELDS:'Informe usuário e senha.'
  };
  var q = new URLSearchParams(location.search);
  var raw = q.get('next') || '/';
  var next = (raw.charAt(0) === '/' && raw.charAt(1) !== '/' && !/[\\\r\n]/.test(raw) && raw.indexOf('/login') !== 0) ? raw : '/';
  $('#next').value = next;

  if (q.has('password') || q.has('username')){ q.delete('password'); q.delete('username'); history.replaceState(null, '', location.pathname + (q.toString() ? '?' + q : '')); }

  form.addEventListener('submit', onSubmit);

  Array.prototype.forEach.call(document.querySelectorAll('[data-icon]'), function(el){ el.innerHTML = ICON[el.getAttribute('data-icon')] || ''; });

  var toggle = $('#togglePassword');
  function paintToggle(){
    var shown = pass.type === 'text';
    toggle.innerHTML = shown ? ICON.eyeOff : ICON.eye;
    toggle.setAttribute('aria-pressed', String(shown));
    toggle.setAttribute('aria-label', shown ? 'Ocultar senha' : 'Mostrar senha');
  }
  toggle.addEventListener('click', function(){ pass.type = pass.type === 'password' ? 'text' : 'password'; paintToggle(); pass.focus(); });
  paintToggle();

  var caps = $('#capsWarn');
  function checkCaps(e){ caps.hidden = !(e.getModifierState && e.getModifierState('CapsLock')); }
  pass.addEventListener('keyup', checkCaps);
  pass.addEventListener('keydown', checkCaps);
  pass.addEventListener('blur', function(){ caps.hidden = true; });

  function fieldError(input, msg){
    var el = $('#err' + input.id.charAt(0).toUpperCase() + input.id.slice(1));
    el.hidden = !msg;
    el.innerHTML = msg ? ICON.alert + '<span></span>' : '';
    if (msg) el.querySelector('span').textContent = msg;
    input.setAttribute('aria-invalid', msg ? 'true' : 'false');
  }
  function show(msg, ok){
    box.className = 'alert' + (ok ? ' is-ok' : '');
    box.innerHTML = (ok ? ICON.check : ICON.alert) + '<span></span>';
    box.querySelector('span').textContent = msg;
    box.hidden = false;
  }
  function shake(){ card.classList.remove('shake'); void card.offsetWidth; card.classList.add('shake'); }

  function onSubmit(e){
    e.preventDefault();
    box.hidden = true;
    var ok = true;
    if (!user.value.trim()){ fieldError(user, 'Informe o usuário.'); ok = false; } else fieldError(user, '');
    if (!pass.value){ fieldError(pass, 'Informe a senha.'); ok = false; } else fieldError(pass, '');
    if (!ok){ (user.value.trim() ? pass : user).focus(); return; }
    btn.classList.add('is-loading'); btn.setAttribute('aria-busy', 'true');
    fetch('/login', {
      method:'POST', credentials:'same-origin', cache:'no-store',
      headers:{ 'Content-Type':'application/json', 'Accept':'application/json' },
      body: JSON.stringify({ username:user.value.trim(), password:pass.value, remember:$('#remember').checked, next:next })
    }).then(function(r){
      return r.json().catch(function(){ return {}; }).then(function(d){
        if (!r.ok) throw new Error(MSG[d.error] || 'Não foi possível entrar. Tente de novo.');
        location.replace(d.next || next);
      });
    }).catch(function(err){
      btn.classList.remove('is-loading'); btn.removeAttribute('aria-busy');
      show(err instanceof TypeError ? 'Sem resposta do servidor de login. Confira a conexão e tente de novo.' : err.message);
      shake();
      pass.select();
    });
  }

  if (q.has('saiu')) show('Você saiu do painel com segurança.', true);
  var erro = (q.get('erro') || '').toUpperCase();
  if (erro) show(MSG[erro] || 'Não foi possível entrar. Tente de novo.');

  fetch('/sessao', { credentials:'same-origin', cache:'no-store' })
    .then(function(r){ return r.ok ? r.json() : null; })
    .then(function(d){ if (d && d.authenticated) location.replace(next); })
    .catch(function(){});
})();
</script>
</body>
</html>
"""

LOGIN_CSP = ("default-src 'none'; style-src 'unsafe-inline' https://fonts.googleapis.com; "
             "font-src https://fonts.gstatic.com; img-src data:; script-src 'unsafe-inline'; "
             "connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, file=sys.stderr, flush=True)


def b64e(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def hash_password(pw, salt=None, iterations=ITERATIONS):
    salt = salt or secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"), salt, iterations)
    return "pbkdf2_sha256$%d$%s$%s" % (iterations, b64e(salt), b64e(dk))


def check_password(pw, stored):
    try:
        algo, it, salt, dk = stored.split("$")
        if algo != "pbkdf2_sha256":
            return False
        calc = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"), b64d(salt), int(it))
        return hmac.compare_digest(calc, b64d(dk))
    except Exception:
        return False


# Hash de mentira: usuario inexistente custa o mesmo tempo que senha errada,
# entao o tempo de resposta nao revela quais usuarios existem.
DUMMY_HASH = hash_password(secrets.token_urlsafe(12))


class UserStore:
    """Le users.json e recarrega sozinho quando o arquivo muda."""

    def __init__(self):
        self._lock = threading.Lock()
        self._mtime = None
        self._users = {}

    def get(self):
        with self._lock:
            try:
                mtime = os.stat(USERS_FILE).st_mtime_ns
                if mtime != self._mtime:
                    with open(USERS_FILE, encoding="utf-8") as f:
                        self._users = json.load(f)
                    self._mtime = mtime
            except FileNotFoundError:
                self._users, self._mtime = {}, None
            except (OSError, ValueError) as e:
                log("erro lendo %s: %s" % (USERS_FILE, e))
            return self._users


STORE = UserStore()


class Limiter:
    """Bloqueia por 15 min o IP ou o usuario apos 5 senhas erradas em 15 min."""

    def __init__(self):
        self._lock = threading.Lock()
        self._fails = {}
        self._locked = {}

    def blocked(self, *keys):
        now = time.time()
        with self._lock:
            return any(self._locked.get(k, 0) > now for k in keys)

    def fail(self, *keys):
        now = time.time()
        with self._lock:
            for k in keys:
                recent = [t for t in self._fails.get(k, []) if now - t < FAIL_WINDOW]
                recent.append(now)
                if len(recent) >= MAX_FAILS:
                    self._locked[k] = now + LOCKOUT
                    recent = []
                self._fails[k] = recent
            if len(self._fails) > 10000:
                self._fails = {k: v for k, v in self._fails.items() if v and now - v[-1] < FAIL_WINDOW}
                self._locked = {k: v for k, v in self._locked.items() if v > now}

    def clear(self, *keys):
        with self._lock:
            for k in keys:
                self._fails.pop(k, None)


LIMIT = Limiter()
SECRET = b""


def sign(payload):
    return b64e(hmac.new(SECRET, payload.encode("utf-8"), hashlib.sha256).digest())


def make_session(user, version, ttl):
    exp = int(time.time()) + ttl
    payload = "%s|%d|%s" % (user, exp, version)
    return "%s.%s" % (b64e(payload.encode("utf-8")), sign(payload)), exp


def read_session(cookie_header):
    if not cookie_header:
        return None
    for part in cookie_header.split(";"):
        name, _, value = part.strip().partition("=")
        if name != COOKIE or not value:
            continue
        try:
            p64, sig = value.split(".", 1)
            payload = b64d(p64).decode("utf-8")
            if not hmac.compare_digest(sign(payload), sig):
                continue
            user, exp, version = payload.split("|")
            if int(exp) < time.time():
                continue
            info = STORE.get().get(user)
            if not info or str(info.get("sv", 0)) != version:
                continue
            return {"user": user, "exp": int(exp)}
        except Exception:
            continue
    return None


def safe_next(value):
    value = value or "/"
    if (not value.startswith("/") or value.startswith("//") or re.search(r"[\\\r\n]", value)
            or value.startswith("/login")):
        return "/"
    return value


class Handler(BaseHTTPRequestHandler):
    server_version = "painel-auth"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def client_ip(self):
        return self.headers.get("X-Real-IP") or self.client_address[0]

    def reply(self, code, body=b"", ctype="text/plain; charset=utf-8", headers=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def reply_json(self, code, obj, headers=()):
        self.reply(code, json.dumps(obj).encode("utf-8"), "application/json; charset=utf-8", headers)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path, _, query = self.path.partition("?")
        q = urllib.parse.parse_qs(query)
        sess = read_session(self.headers.get("Cookie"))
        if path == "/auth":
            if sess:
                return self.reply(204, headers=[("X-Painel-User", sess["user"])])
            return self.reply(401)
        if path == "/sessao":
            body = {"authenticated": bool(sess)}
            if sess:
                body.update(user=sess["user"], exp=sess["exp"])
            return self.reply_json(200, body)
        if path == "/login":
            nxt = safe_next((q.get("next") or ["/"])[0])
            if sess:
                return self.reply(302, headers=[("Location", nxt)])
            return self.reply(200, LOGIN_HTML.encode("utf-8"), "text/html; charset=utf-8", [
                ("Content-Security-Policy", LOGIN_CSP),
                ("X-Frame-Options", "DENY"),
                ("Referrer-Policy", "no-referrer"),
                ("X-Content-Type-Options", "nosniff"),
            ])
        if path == "/logout":
            return self.logout(sess)
        self.reply(404)

    def do_POST(self):
        path = self.path.partition("?")[0]
        if path == "/logout":
            return self.logout(read_session(self.headers.get("Cookie")))
        if path != "/login":
            return self.reply(404)
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length > 4096:
            return self.reply_json(413, {"error": "TOO_LARGE"})
        raw = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        is_json = "application/json" in (self.headers.get("Content-Type") or "")
        if is_json:
            try:
                data = json.loads(raw or "{}")
            except ValueError:
                data = {}
        else:
            data = {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}
        if not isinstance(data, dict):
            data = {}
        user = str(data.get("username", "")).strip().lower()
        password = str(data.get("password", ""))
        remember = data.get("remember") in (True, "on", "1", "true")
        nxt = safe_next(str(data.get("next") or "/"))
        ip = self.client_ip()

        def refuse(error, status):
            if is_json:
                return self.reply_json(status, {"error": error})
            target = "/login?erro=%s&next=%s" % (error.lower(), urllib.parse.quote(nxt, safe="/"))
            return self.reply(303, headers=[("Location", target)])

        if not user or not password:
            return refuse("MISSING_FIELDS", 400)
        keys = ("ip:" + ip, "user:" + user)
        if LIMIT.blocked(*keys):
            log("bloqueado: tentativa de '%s' a partir de %s" % (user, ip))
            return refuse("TOO_MANY_ATTEMPTS", 429)
        info = STORE.get().get(user)
        valid = check_password(password, info["hash"] if info else DUMMY_HASH) and bool(info)
        if not valid:
            LIMIT.fail(*keys)
            log("senha errada para '%s' a partir de %s" % (user, ip))
            return refuse("INVALID_CREDENTIALS", 401)
        LIMIT.clear(*keys)
        ttl = TTL_LONG if remember else TTL_SHORT
        value, _ = make_session(user, str(info.get("sv", 0)), ttl)
        cookie = "%s=%s; Path=/; HttpOnly; Secure; SameSite=Lax" % (COOKIE, value)
        if remember:
            cookie += "; Max-Age=%d" % ttl
        log("login de '%s' a partir de %s%s" % (user, ip, " (30 dias)" if remember else ""))
        if is_json:
            return self.reply_json(200, {"ok": True, "user": user, "next": nxt}, [("Set-Cookie", cookie)])
        return self.reply(303, headers=[("Location", nxt), ("Set-Cookie", cookie)])

    def logout(self, sess):
        if sess:
            log("saida de '%s'" % sess["user"])
        self.reply(303, headers=[
            ("Location", "/login?saiu=1"),
            ("Set-Cookie", "%s=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0" % COOKIE),
        ])


# ---------------- linha de comando ----------------

def www_gid():
    try:
        return grp.getgrnam("www-data").gr_gid
    except KeyError:
        return -1


def write_private(path, data):
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.chmod(tmp, 0o640)
    if os.geteuid() == 0:
        os.chown(tmp, 0, www_gid())
    os.replace(tmp, path)


def init():
    os.makedirs(DIR, exist_ok=True)
    os.chmod(DIR, 0o750)
    if os.geteuid() == 0:
        os.chown(DIR, 0, www_gid())
    if not os.path.exists(SECRET_FILE):
        write_private(SECRET_FILE, secrets.token_bytes(32))
    if not os.path.exists(USERS_FILE):
        write_private(USERS_FILE, b"{}\n")


def load_users():
    try:
        with open(USERS_FILE, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save_users(users):
    write_private(USERS_FILE, (json.dumps(users, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))


def cmd_adduser(name):
    name = name.strip().lower()
    if not USER_RE.match(name):
        sys.exit("Nome invalido. Use 2 a 32 caracteres: letras minusculas, numeros, ponto, hifen ou sublinhado.")
    init()
    users = load_users()
    exists = name in users
    while True:
        pw = getpass.getpass("Senha para %s: " % name)
        if len(pw) < MIN_PASSWORD:
            print("A senha precisa de pelo menos %d caracteres." % MIN_PASSWORD)
            continue
        if pw != getpass.getpass("Repita a senha: "):
            print("As senhas nao conferem. Tente de novo.")
            continue
        break
    old = users.get(name, {})
    users[name] = {
        "hash": hash_password(pw),
        "sv": int(old.get("sv", 0)) + (1 if exists else 0),
        "criado": old.get("criado") or datetime.now().strftime("%Y-%m-%d %H:%M"),
        "senha_alterada": datetime.now().strftime("%Y-%m-%d %H:%M"),
    }
    save_users(users)
    print("Senha de '%s' alterada; as sessoes abertas dele foram encerradas." % name if exists
          else "Usuario '%s' criado." % name)


def cmd_deluser(name):
    users = load_users()
    if users.pop(name.strip().lower(), None) is None:
        sys.exit("Usuario '%s' nao existe." % name)
    save_users(users)
    print("Usuario '%s' removido; as sessoes dele deixam de valer." % name)


def cmd_logout_all(name):
    users = load_users()
    name = name.strip().lower()
    if name not in users:
        sys.exit("Usuario '%s' nao existe." % name)
    users[name]["sv"] = int(users[name].get("sv", 0)) + 1
    save_users(users)
    print("Sessoes de '%s' encerradas em todos os aparelhos." % name)


def cmd_users():
    users = load_users()
    if not users:
        print("Nenhum usuario. Crie com: painel-auth.py adduser NOME")
        return
    for name, info in sorted(users.items()):
        print("%-20s criado %s  senha alterada %s" % (name, info.get("criado", "-"), info.get("senha_alterada", "-")))


def cmd_serve():
    global SECRET
    try:
        with open(SECRET_FILE, "rb") as f:
            SECRET = f.read()
    except FileNotFoundError:
        sys.exit("Chave %s nao encontrada. Rode 'painel-auth.py init' como root." % SECRET_FILE)
    if len(SECRET) < 32:
        sys.exit("Chave %s invalida." % SECRET_FILE)
    httpd = ThreadingHTTPServer(LISTEN, Handler)
    httpd.daemon_threads = True
    log("login do painel ouvindo em http://%s:%d" % LISTEN)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    cmd, args = argv[1], argv[2:]
    if cmd == "serve":
        cmd_serve()
    elif cmd == "init":
        init()
    elif cmd == "adduser" and len(args) == 1:
        cmd_adduser(args[0])
    elif cmd == "deluser" and len(args) == 1:
        cmd_deluser(args[0])
    elif cmd == "logout-all" and len(args) == 1:
        cmd_logout_all(args[0])
    elif cmd == "users":
        cmd_users()
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
__PAINEL_AUTH_PY__
chmod 755 /opt/painel-olt/painel-auth.py
python3 -m py_compile /opt/painel-olt/painel-auth.py || erro "painel-auth.py não compilou."
python3 /opt/painel-olt/painel-auth.py init
ok "Serviço de login em /opt/painel-olt/painel-auth.py"

cat > /etc/systemd/system/painel-auth.service <<'EOF'
[Unit]
Description=Login do Painel das OLTs (UpDown NOC)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/painel-olt/painel-auth.py serve
User=www-data
Group=www-data
Restart=always
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable painel-auth >/dev/null 2>&1
systemctl restart painel-auth
sleep 1
systemctl is-active --quiet painel-auth || { journalctl -u painel-auth -n 20 --no-pager; erro "O serviço painel-auth não subiu."; }
ok "Serviço painel-auth rodando (127.0.0.1:8091)."

# 3. primeiro usuário
if python3 -c "import json,sys; sys.exit(0 if json.load(open('/etc/painel-olt/users.json')) else 1)"; then
  info "Usuários já cadastrados:"
  python3 /opt/painel-olt/painel-auth.py users
else
  read -rp "Nome do primeiro usuário do painel [noc]: " U
  python3 /opt/painel-olt/painel-auth.py adduser "${U:-noc}"
fi

# 4. painel
install -d -m 755 /var/www/painel-olt /var/www/letsencrypt
if [ -f "$AQUI/painel-olt.html" ]; then
  install -m 644 "$AQUI/painel-olt.html" /var/www/painel-olt/index.html
  ok "Painel copiado para /var/www/painel-olt/index.html"
elif [ -f /var/www/painel-olt/index.html ]; then
  info "Mantido o painel que já estava em /var/www/painel-olt/index.html"
else
  info "Atenção: falta o painel. Coloque o painel-olt.html em /var/www/painel-olt/index.html"
fi

# 5. nginx
BAK=""
if [ -f "$SITE" ]; then BAK="$SITE.bak-$(date +%Y%m%d-%H%M%S)"; cp "$SITE" "$BAK"; fi
cat > "$SITE" <<'EOF'
server {
    listen 80;
    server_name __DOMINIO__;
    location /.well-known/acme-challenge/ { root /var/www/letsencrypt; }
    location / { return 301 https://$host:__PORTA__$request_uri; }
}

server {
    listen __PORTA__ ssl;
    server_name __DOMINIO__;
    ssl_certificate     /etc/letsencrypt/live/__DOMINIO__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMINIO__/privkey.pem;

    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Cache-Control "no-store" always;

    root /var/www/painel-olt;
    index index.html;

    # consulta de sessão (uso interno do nginx)
    location = /_auth {
        internal;
        proxy_pass http://127.0.0.1:8091/auth;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Real-IP $remote_addr;
    }

    # tela de login, saída e estado da sessão
    location ~ ^/(login|logout|sessao)$ {
        proxy_pass http://127.0.0.1:8091;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # painel: sem sessão vai para o login
    location / {
        auth_request /_auth;
        error_page 401 = @login;
        try_files $uri $uri/ =404;
    }
    location @login {
        return 302 /login?next=$request_uri;
    }

    # API do Zabbix: só com sessão; o token fica aqui, nunca no navegador
    location = /zbx-api {
        auth_request /_auth;
        proxy_pass https://zbx7.lv.network/api_jsonrpc.php;
        proxy_ssl_server_name on;
        proxy_set_header Host zbx7.lv.network;
        proxy_set_header Authorization "Bearer __TOKEN__";
        proxy_set_header Cookie "";
        proxy_read_timeout 60s;
    }
}
EOF
sed -i "s|__DOMINIO__|$DOMINIO|g; s|__PORTA__|$PORTA|g; s|__TOKEN__|$TOKEN|g" "$SITE"
chmod 640 "$SITE"
ln -sf "$SITE" /etc/nginx/sites-enabled/painel-olt
if ! nginx -t >/tmp/painel-nginx-teste.log 2>&1; then
  cat /tmp/painel-nginx-teste.log
  if [ -n "$BAK" ]; then cp "$BAK" "$SITE"; erro "O nginx recusou a configuração nova; a anterior foi restaurada."; fi
  erro "O nginx recusou a configuração nova."
fi
systemctl reload nginx
ok "nginx atualizado${BAK:+ (cópia da configuração anterior em $BAK)}."
[ -f /etc/nginx/.painel-olt ] && rm -f /etc/nginx/.painel-olt && info "Removido o login antigo do navegador (/etc/nginx/.painel-olt)."

# 6. conferência
code="$(curl -s -o /dev/null -w '%{http_code}' --resolve "$DOMINIO:$PORTA:127.0.0.1" "https://$DOMINIO:$PORTA/login" || true)"
[ "$code" = "200" ] && ok "Tela de login respondendo." || info "A tela de login respondeu HTTP $code. Veja: journalctl -u painel-auth -n 30"
code="$(curl -s -o /dev/null -w '%{http_code}' --resolve "$DOMINIO:$PORTA:127.0.0.1" "https://$DOMINIO:$PORTA/" || true)"
[ "$code" = "302" ] && ok "Painel protegido: sem sessão vai para o login." || info "O painel respondeu HTTP $code sem sessão (esperado 302)."

echo
ok "Pronto: https://$DOMINIO:$PORTA"
echo "   Usuários:  python3 /opt/painel-olt/painel-auth.py adduser NOME   (cria ou troca a senha)"
echo "              python3 /opt/painel-olt/painel-auth.py deluser NOME"
echo "              python3 /opt/painel-olt/painel-auth.py users"
echo "   Registro:  journalctl -u painel-auth -f"
