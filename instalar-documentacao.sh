#!/usr/bin/env bash
# Documentação de equipamentos do NOC — https://documentacao.noc.updown.com.br
#
#   sudo bash instalar-documentacao.sh
#
# O que faz:
#   1. copia documentacao/ para /opt/documentacao-noc (NUNCA sobrescreve a documentação já salva em data/)
#   2. pede o token da API do Zabbix próprio (127.0.0.1:19090) na primeira vez
#      (ou reaproveita o do painel-pon, se existir)
#   3. instala e liga o serviço documentacao-noc (systemd, usuário www-data, porta 8447 local)
#   4. publica no nginx em https://documentacao.noc.updown.com.br (gera o certificado com certbot se faltar)
#   5. confere se o site respondeu; se algo falhar, desfaz e volta como estava
#
# Login: usuário NOC (senha guardada só como hash no config.env).
# Pode rodar de novo para atualizar (git pull && sudo bash instalar-documentacao.sh).
set -euo pipefail

DOMINIO="${DOMINIO:-documentacao.noc.updown.com.br}"
PORTA_HTTPS="${PORTA_HTTPS:-443}"
PORTA_APP="${PORTA_APP:-8447}"
EMAIL_CERT="${EMAIL_CERT:-}"
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST=/opt/documentacao-noc
SITE=/etc/nginx/sites-available/documentacao-noc
CERT="/etc/letsencrypt/live/$DOMINIO"
WEBROOT=/var/www/letsencrypt

ok()   { printf '\033[32m✔\033[0m %s\n' "$*"; }
info() { printf '\033[36m•\033[0m %s\n' "$*"; }
erro() { printf '\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || erro "Rode como root."
command -v python3 >/dev/null || erro "python3 não encontrado."
[ -f "$AQUI/documentacao/server.py" ] || erro "Não achei documentacao/server.py ao lado deste script. Rode de dentro do repositório nocup."

# Backup do que já existe ------------------------------------------------------
BK=/root/documentacao-noc/backup-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BK"
[ -d "$DEST" ] && cp -a "$DEST" "$BK/opt" || true
[ -f "$SITE" ] && cp -a "$SITE" "$BK/nginx.conf" || true
[ -f /etc/systemd/system/documentacao-noc.service ] && cp -a /etc/systemd/system/documentacao-noc.service "$BK/" || true
info "Backup em $BK"

desfazer() {
  printf '\033[31m✘ %s — desfazendo\033[0m\n' "$1" >&2
  systemctl stop documentacao-noc 2>/dev/null || true
  if [ -d "$BK/opt" ]; then rm -rf "$DEST"; cp -a "$BK/opt" "$DEST"; fi
  if [ -f "$BK/documentacao-noc.service" ]; then cp -a "$BK/documentacao-noc.service" /etc/systemd/system/; systemctl daemon-reload; systemctl restart documentacao-noc || true
  elif [ ! -d "$BK/opt" ]; then systemctl disable documentacao-noc 2>/dev/null || true; rm -f /etc/systemd/system/documentacao-noc.service; systemctl daemon-reload; fi
  if [ -f "$BK/nginx.conf" ]; then cp -a "$BK/nginx.conf" "$SITE"; else rm -f "$SITE" /etc/nginx/sites-enabled/documentacao-noc; fi
  command -v nginx >/dev/null && nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
  echo "Voltou como estava. Me mande as mensagens acima."; exit 1
}

# 1. Arquivos -----------------------------------------------------------------
install -d -m 755 "$DEST" "$DEST/static" "$DEST/static/vendor"
install -m 755 "$AQUI/documentacao/server.py" "$DEST/server.py"
for f in index.html login.html logo-updown.png monograma.svg; do
  install -m 644 "$AQUI/documentacao/static/$f" "$DEST/static/$f"
done
for f in three.min.js xlsx.full.min.js; do
  install -m 644 "$AQUI/documentacao/static/vendor/$f" "$DEST/static/vendor/$f"
done
install -m 644 "$AQUI/documentacao/config.env.example" "$DEST/config.env.example"
install -m 644 "$AQUI/documentacao/dados-iniciais.json" "$DEST/dados-iniciais.json"
python3 -m py_compile "$DEST/server.py" || desfazer "server.py não compilou"
if [ -f "$DEST/data/equipamentos.json" ]; then
  ok "Arquivos em $DEST (documentação salva mantida: $(python3 -c "import json;d=json.load(open('$DEST/data/equipamentos.json'));print(len(d.get('devices',[])),'equipamentos, versão',d.get('rev'))"))"
else
  ok "Arquivos em $DEST (a documentação começa com os dados iniciais da planilha DOC_SW + Zabbix)"
fi

# 2. Configuração / token -----------------------------------------------------
if [ ! -f "$DEST/config.env" ]; then
  cp "$DEST/config.env.example" "$DEST/config.env"
  TOKEN=""
  if [ -f /opt/painel-pon/config.env ] && grep -qP '^ZABBIX_TOKEN=[A-Za-z0-9]{16,}' /opt/painel-pon/config.env; then
    read -rp "Usar o mesmo token do Zabbix do painel-pon? [S/n] " R
    case "${R:-S}" in [Nn]*) ;; *) TOKEN="$(grep -oP '^ZABBIX_TOKEN=\K.*' /opt/painel-pon/config.env)";; esac
  fi
  if [ -z "$TOKEN" ]; then
    read -rsp "Token da API do Zabbix próprio (Usuários > Tokens de API; não aparece na tela): " TOKEN; echo
  fi
  [[ "$TOKEN" =~ ^[A-Za-z0-9]{16,}$ ]] || desfazer "Token inválido: esperava só letras e números"
  sed -i "s#^ZABBIX_TOKEN=.*#ZABBIX_TOKEN=$TOKEN#" "$DEST/config.env"
  # Senha inicial aleatória da conta NOC: só o hash vai para o config.env.
  SENHA_INICIAL="$(python3 -c 'import secrets;print(secrets.token_urlsafe(15))')"
  HASH_INICIAL="$(SENHA="$SENHA_INICIAL" python3 -c 'import os,hashlib,secrets,base64
e=lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
s=secrets.token_bytes(16); dk=hashlib.pbkdf2_hmac("sha256",os.environ["SENHA"].encode(),s,200000)
print("pbkdf2_sha256$200000$"+e(s)+"$"+e(dk))')"
  sed -i "s#^LOGIN_SENHA_HASH=.*#LOGIN_SENHA_HASH=$HASH_INICIAL#" "$DEST/config.env"
  ok "config.env criado"
else
  ok "Mantido o config.env que já existia"
  NOVAS=0
  while IFS= read -r linha; do
    case "$linha" in ''|'#'*) continue ;; esac
    chave="${linha%%=*}"
    if ! grep -q "^${chave}=" "$DEST/config.env"; then echo "$linha" >> "$DEST/config.env"; NOVAS=$((NOVAS+1)); fi
  done < "$DEST/config.env.example"
  [ "$NOVAS" -gt 0 ] && ok "$NOVAS opção(ões) nova(s) acrescentada(s) ao config.env"
fi
sed -i "s#^PORT=.*#PORT=$PORTA_APP#; s#^LISTEN=.*#LISTEN=127.0.0.1#; s#^DATA_DIR=.*#DATA_DIR=$DEST/data#" "$DEST/config.env"
install -d -m 750 "$DEST/data"
chown -R www-data: "$DEST"
chmod 600 "$DEST/config.env"

# Testa o token antes de ligar o serviço
URL="$(grep -oP '^ZABBIX_URL=\K.*' "$DEST/config.env")"
TK="$(grep -oP '^ZABBIX_TOKEN=\K.*' "$DEST/config.env")"
RESP="$(curl -s -m 15 -H 'Content-Type: application/json-rpc' -H "Authorization: Bearer $TK" \
  -d '{"jsonrpc":"2.0","method":"host.get","params":{"output":["hostid"],"filter":{"name":["SWITCH S6730 SANTOS"]}},"id":1}' \
  "$URL/api_jsonrpc.php" || true)"
case "$RESP" in
  *'"hostid"'*) ok "Zabbix respondeu e achou o host 'SWITCH S6730 SANTOS'" ;;
  *'"result":[]'*) info "Atenção: o Zabbix respondeu, mas o token não vê o host 'SWITCH S6730 SANTOS' (dê leitura no grupo 'Links UpDown')" ;;
  *) desfazer "O Zabbix em $URL não aceitou o token (resposta: ${RESP:0:160})" ;;
esac

# 3. Serviço ------------------------------------------------------------------
cat > /etc/systemd/system/documentacao-noc.service <<EOF
[Unit]
Description=UpDown NOC - Documentação de equipamentos
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
systemctl enable documentacao-noc >/dev/null 2>&1
systemctl restart documentacao-noc
for _ in $(seq 1 20); do curl -s -m 2 "http://127.0.0.1:$PORTA_APP/healthz" >/dev/null && break; sleep 1; done
curl -s -m 2 "http://127.0.0.1:$PORTA_APP/healthz" | grep -q ok || { journalctl -u documentacao-noc -n 30 --no-pager; desfazer "O serviço documentacao-noc não subiu"; }
ok "Serviço documentacao-noc rodando na porta $PORTA_APP (só local)"

# 4. nginx + certificado --------------------------------------------------------
if ! command -v nginx >/dev/null; then
  info "nginx não está instalado: o site fica só em http://127.0.0.1:$PORTA_APP."
  info "Instale com 'apt install nginx certbot' e rode este script de novo para publicar em $DOMINIO."
  exit 0
fi
IP_DNS="$(getent ahostsv4 "$DOMINIO" | awk 'NR==1{print $1}' || true)"
[ -n "$IP_DNS" ] && info "DNS: $DOMINIO aponta para $IP_DNS" || info "Atenção: $DOMINIO ainda não resolve no DNS (crie o registro A)"

PROXY_BLOCO="    client_max_body_size 10m;
    location / {
        proxy_pass http://127.0.0.1:$PORTA_APP;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }"

if [ ! -f "$CERT/fullchain.pem" ]; then
  # HTTP primeiro (para o desafio do Let's Encrypt)
  install -d -m 755 "$WEBROOT"
  cat > "$SITE" <<EOF
# Documentação NOC — gerado por instalar-documentacao.sh (etapa HTTP)
server {
    listen 80;
    server_name $DOMINIO;
    location /.well-known/acme-challenge/ { root $WEBROOT; }
$PROXY_BLOCO
}
EOF
  ln -sf "$SITE" /etc/nginx/sites-enabled/documentacao-noc
  nginx -t >/tmp/doc-noc-nginx.log 2>&1 || { cat /tmp/doc-noc-nginx.log; desfazer "O nginx recusou a configuração"; }
  systemctl reload nginx
  ok "nginx respondendo em http://$DOMINIO"
  if command -v certbot >/dev/null; then
    info "Pedindo certificado do Let's Encrypt para $DOMINIO…"
    if [ -n "$EMAIL_CERT" ]; then EM=(--email "$EMAIL_CERT"); else EM=(--register-unsafely-without-email); fi
    if certbot certonly --webroot -w "$WEBROOT" -d "$DOMINIO" --non-interactive --agree-tos "${EM[@]}" >/tmp/doc-noc-certbot.log 2>&1; then
      ok "Certificado emitido"
    else
      tail -n 15 /tmp/doc-noc-certbot.log
      info "Não consegui o certificado. Confira: registro A de $DOMINIO -> IP público deste servidor e porta 80 liberada/encaminhada."
      info "O site fica em HTTP por enquanto. Depois de ajustar, rode o instalador de novo."
    fi
  else
    info "certbot não instalado (apt install certbot). O site fica em HTTP por enquanto."
  fi
fi

if [ -f "$CERT/fullchain.pem" ]; then
  REDIR=""
  [ "$PORTA_HTTPS" = "443" ] && REDIR="server {
    listen 80;
    server_name $DOMINIO;
    location /.well-known/acme-challenge/ { root $WEBROOT; }
    location / { return 301 https://\$host\$request_uri; }
}"
  cat > "$SITE" <<EOF
# Documentação NOC — gerado por instalar-documentacao.sh
$REDIR
server {
    listen $PORTA_HTTPS ssl http2;
    server_name $DOMINIO;
    ssl_certificate     $CERT/fullchain.pem;
    ssl_certificate_key $CERT/privkey.pem;
    add_header Strict-Transport-Security "max-age=31536000" always;
$PROXY_BLOCO
}
EOF
  install -d -m 755 "$WEBROOT"
  ln -sf "$SITE" /etc/nginx/sites-enabled/documentacao-noc
  # Login único do Portal NOC: se a documentação já está ligada ao portal (PORTAL=1, feito pelo
  # vincular-portal.sh), refaz a ligação no site novo. Sem isso, reinstalar apagava o vínculo e o
  # site caía no login próprio, sem os usuários do portal.
  if grep -q '^PORTAL=1' "$DEST/config.env"; then
    if [ -f /etc/nginx/snippets/portal-sso.conf ] && [ -f "$AQUI/vincular-portal.py" ]; then
      python3 "$AQUI/vincular-portal.py" "$SITE" documentacao --tipo proxy > "$SITE.portal" 2>/tmp/doc-noc-vinc.log \
        || { cat /tmp/doc-noc-vinc.log; desfazer "Não consegui religar a documentação ao portal"; }
      cat "$SITE.portal" > "$SITE"; rm -f "$SITE.portal"
      ok "Login pelo Portal NOC mantido (usuários e permissões vêm do portal)"
    else
      info "Atenção: PORTAL=1, mas falta o snippet do portal no nginx. Rode: sudo bash vincular-portal.sh"
    fi
  fi
  nginx -t >/tmp/doc-noc-nginx.log 2>&1 || { cat /tmp/doc-noc-nginx.log; desfazer "O nginx recusou a configuração HTTPS"; }
  systemctl reload nginx
  if [ "$PORTA_HTTPS" = "443" ]; then ENDERECO="https://$DOMINIO"; else ENDERECO="https://$DOMINIO:$PORTA_HTTPS"; fi
  ok "Publicado em $ENDERECO"
else
  ENDERECO="http://$DOMINIO"
fi

# Login ------------------------------------------------------------------------
# Hash que esteve publicado no config.env.example (repositório público): trocar.
HASH_PUBLICO='pbkdf2_sha256$200000$nmDjoaNls528h0gwOuiBlQ$gbVqHsZwHo0bopcV_31fDs1h28aheaLq3Uwe0OZhZKQ'
if [ -n "${SENHA_INICIAL:-}" ]; then
  ok "Login: usuário NOC, senha inicial: $SENHA_INICIAL  (anote agora; não aparece de novo)"
fi
if grep -qF "LOGIN_SENHA_HASH=$HASH_PUBLICO" "$DEST/config.env"; then
  info "ATENÇÃO: o config.env usa o hash de senha que estava publicado no GitHub. Troque já:"
  info "  sudo -u www-data python3 $DEST/server.py senha   (cole a linha em $DEST/config.env e reinicie)"
fi
if grep -q '^PORTAL=1' "$DEST/config.env"; then
  ok "Login: Portal NOC (https://portal.updown.com.br). Libere o sistema \"Documentação\" para cada usuário em Usuários."
elif grep -qP '^LOGIN_SENHA_HASH=pbkdf2_sha256\$' "$DEST/config.env"; then
  ok "Login: usuário $(grep -oP '^LOGIN_USUARIO=\K.*' "$DEST/config.env" || echo NOC) (trocar a senha: sudo -u www-data python3 $DEST/server.py senha)"
else
  info "Atenção: LOGIN_SENHA_HASH vazio no config.env — sem PORTAL=1 o site responde 503 até configurar a senha"
fi

sleep 3
journalctl -u documentacao-noc -n 6 --no-pager | grep -E "zabbix:|login:" || true

echo
ok "Pronto. Abra: $ENDERECO"
echo "   Logs:        journalctl -u documentacao-noc -f"
echo "   Ajustes:     $DEST/config.env  (depois: systemctl restart documentacao-noc)"
echo "   Documentação salva: $DEST/data/equipamentos.json  (versões anteriores em $DEST/data/historico/)"
