#!/usr/bin/env bash
# Tela de TV de alertas GPON (PON down / CTO down) — UpDown NOC
#
#   sudo bash instalar-pon.sh
#
# O que faz:
#   1. copia painel-pon/ para /opt/painel-pon (mantém config.env e cto_map.json se já existirem)
#   2. pede o token da API do Zabbix próprio (127.0.0.1:19090) na primeira vez
#   3. instala e liga o serviço painel-pon (systemd, usuário www-data)
#   4. se houver certificado de monitoramento.updown.com.br, publica em HTTPS na porta 8446
#   5. confere se a tela respondeu; se algo falhar, desfaz e volta como estava
#
# Pode rodar de novo para atualizar: token e configurações são preservados.
set -euo pipefail

DOMINIO="${DOMINIO:-monitoramento.updown.com.br}"
PORTA_HTTPS="${PORTA_HTTPS:-8446}"
PORTA_APP="${PORTA_APP:-8445}"
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST=/opt/painel-pon
SITE=/etc/nginx/sites-available/painel-pon
CERT="/etc/letsencrypt/live/$DOMINIO"

ok()   { printf '\033[32m✔\033[0m %s\n' "$*"; }
info() { printf '\033[36m•\033[0m %s\n' "$*"; }
erro() { printf '\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || erro "Rode como root."
command -v python3 >/dev/null || erro "python3 não encontrado."
[ -f "$AQUI/painel-pon/server.py" ] || erro "Não achei painel-pon/server.py ao lado deste script. Rode de dentro do repositório nocup."

# Backup do que já existe ------------------------------------------------------
BK=/root/painel-pon/backup-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BK"
[ -d "$DEST" ] && cp -a "$DEST" "$BK/opt" || true
[ -f "$SITE" ] && cp -a "$SITE" "$BK/nginx.conf" || true
[ -f /etc/systemd/system/painel-pon.service ] && cp -a /etc/systemd/system/painel-pon.service "$BK/" || true
info "Backup em $BK"

desfazer() {
  printf '\033[31m✘ %s — desfazendo\033[0m\n' "$1" >&2
  systemctl stop painel-pon 2>/dev/null || true
  if [ -d "$BK/opt" ]; then rm -rf "$DEST"; cp -a "$BK/opt" "$DEST"; fi
  if [ -f "$BK/painel-pon.service" ]; then cp -a "$BK/painel-pon.service" /etc/systemd/system/; systemctl daemon-reload; systemctl restart painel-pon || true
  elif [ ! -d "$BK/opt" ]; then systemctl disable painel-pon 2>/dev/null || true; rm -f /etc/systemd/system/painel-pon.service; systemctl daemon-reload; fi
  if [ -f "$BK/nginx.conf" ]; then cp -a "$BK/nginx.conf" "$SITE"; else rm -f "$SITE" /etc/nginx/sites-enabled/painel-pon; fi
  command -v nginx >/dev/null && nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
  echo "Voltou como estava. Me mande as mensagens acima."; exit 1
}

# 1. Arquivos -----------------------------------------------------------------
install -d -m 755 "$DEST" "$DEST/static"
install -m 755 "$AQUI/painel-pon/server.py" "$DEST/server.py"
install -m 644 "$AQUI/painel-pon/static/index.html" "$DEST/static/index.html"
install -m 644 "$AQUI/painel-pon/config.env.example" "$DEST/config.env.example"
install -m 644 "$AQUI/painel-pon/cto_map.example.json" "$DEST/cto_map.example.json"
python3 -m py_compile "$DEST/server.py" || desfazer "server.py não compilou"
ok "Arquivos em $DEST"

# 2. Configuração / token -----------------------------------------------------
USA_NGINX=0
if command -v nginx >/dev/null && [ -f "$CERT/fullchain.pem" ]; then USA_NGINX=1; fi

if [ ! -f "$DEST/config.env" ]; then
  cp "$DEST/config.env.example" "$DEST/config.env"
  read -rsp "Token da API do Zabbix próprio (Usuários > Tokens de API; não aparece na tela): " TOKEN; echo
  [[ "$TOKEN" =~ ^[A-Za-z0-9]{16,}$ ]] || desfazer "Token inválido: esperava só letras e números"
  sed -i "s#^ZABBIX_TOKEN=.*#ZABBIX_TOKEN=$TOKEN#" "$DEST/config.env"
  read -rp "Usuário e senha para abrir a tela (ex.: noc:senha; Enter = sem login): " BA
  [ -n "$BA" ] && sed -i "s#^BASIC_AUTH=.*#BASIC_AUTH=$BA#" "$DEST/config.env"
  ok "config.env criado"
else
  ok "Mantido o config.env que já existia"
fi
sed -i "s#^PORT=.*#PORT=$PORTA_APP#" "$DEST/config.env"
if [ "$USA_NGINX" = 1 ]; then sed -i "s#^LISTEN=.*#LISTEN=127.0.0.1#" "$DEST/config.env"; fi
chown -R www-data: "$DEST"
chmod 600 "$DEST/config.env"

# Testa o token antes de ligar o serviço
URL="$(grep -oP '^ZABBIX_URL=\K.*' "$DEST/config.env")"
TK="$(grep -oP '^ZABBIX_TOKEN=\K.*' "$DEST/config.env")"
RESP="$(curl -s -m 15 -H 'Content-Type: application/json-rpc' -H "Authorization: Bearer $TK" \
  -d '{"jsonrpc":"2.0","method":"host.get","params":{"output":["hostid"],"filter":{"host":["IXC - CTO"]}},"id":1}' \
  "$URL/api_jsonrpc.php" || true)"
case "$RESP" in
  *'"hostid"'*) ok "Zabbix respondeu e o host 'IXC - CTO' foi encontrado" ;;
  *'"result":[]'*) info "Atenção: o Zabbix respondeu, mas não achei o host 'IXC - CTO' (confira CTO_HOST no config.env)" ;;
  *) desfazer "O Zabbix em $URL não aceitou o token (resposta: ${RESP:0:160})" ;;
esac

# 3. Serviço ------------------------------------------------------------------
cat > /etc/systemd/system/painel-pon.service <<EOF
[Unit]
Description=UpDown NOC - Painel de alertas PON/CTO (TV)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$DEST
ExecStart=/usr/bin/python3 $DEST/server.py
Restart=always
RestartSec=5
User=www-data

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable painel-pon >/dev/null 2>&1
systemctl restart painel-pon
for _ in $(seq 1 20); do curl -s -m 2 "http://127.0.0.1:$PORTA_APP/healthz" >/dev/null && break; sleep 1; done
curl -s -m 2 "http://127.0.0.1:$PORTA_APP/healthz" | grep -q ok || { journalctl -u painel-pon -n 30 --no-pager; desfazer "O serviço painel-pon não subiu"; }
ok "Serviço painel-pon rodando na porta $PORTA_APP"

# 4. nginx (HTTPS) -------------------------------------------------------------
if [ "$USA_NGINX" = 1 ]; then
  cat > "$SITE" <<EOF
# Tela de alertas PON/CTO — gerado por instalar-pon.sh
server {
    listen $PORTA_HTTPS ssl;
    server_name $DOMINIO;
    ssl_certificate     $CERT/fullchain.pem;
    ssl_certificate_key $CERT/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:$PORTA_APP;
        proxy_set_header Host \$host;
        proxy_set_header Authorization \$http_authorization;
        proxy_read_timeout 60s;
    }
}
EOF
  ln -sf "$SITE" /etc/nginx/sites-enabled/painel-pon
  nginx -t >/tmp/painel-pon-nginx.log 2>&1 || { cat /tmp/painel-pon-nginx.log; desfazer "O nginx recusou a configuração"; }
  systemctl reload nginx
  ok "nginx publicado em https://$DOMINIO:$PORTA_HTTPS"
  ENDERECO="https://$DOMINIO:$PORTA_HTTPS"
else
  info "Sem nginx/certificado de $DOMINIO: a tela fica direto na porta $PORTA_APP (HTTP)."
  ENDERECO="http://$(hostname -I | awk '{print $1}'):$PORTA_APP"
fi

# 5. Confere a primeira coleta -------------------------------------------------
sleep 4
journalctl -u painel-pon -n 5 --no-pager | grep -E "ok:|Falha|Error" || true

echo
ok "Pronto. Abra na TV: $ENDERECO"
echo "   Sem Zabbix (demonstração):  $ENDERECO/?demo"
echo "   Logs:        journalctl -u painel-pon -f"
echo "   Ajustes:     $DEST/config.env  (depois: systemctl restart painel-pon)"
echo "   Libere a porta $PORTA_HTTPS no firewall se a TV estiver fora da rede do servidor."
