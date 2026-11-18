#!/usr/bin/env bash
# Vincula os painéis do NOC ao login único do Portal NOC (https://portal.updown.com.br).
#
#   sudo bash vincular-portal.sh             # vincula tudo o que achar neste servidor
#   sudo bash vincular-portal.sh --desfazer  # volta como estava antes da última execução
#
# Depois disto, o usuário criado no portal (com os sistemas liberados para ele) entra em:
#   Painel das OLTs (:8443) · Painel de Links (:9443) · TV · Links (/tv) · TV · ISP (/tv-isp)
#   Alertas PON / CTO (:8446) · Documentação (documentacao.noc.updown.com.br)
# O nginx pergunta ao portal, a cada acesso (cache de 30 s), se a sessão vale e se o
# usuário tem aquele sistema. Sem sessão -> tela de login do portal (e volta depois).
# Sem permissão -> portal avisa "sem acesso". Desativar o usuário, trocar a senha ou
# "derrubar sessões" no portal corta o acesso em todos os painéis.
#
# O que faz:
#   1. instala o cache e o snippet do portal no nginx (conf.d/ e snippets/)
#   2. troca o login próprio (painel-auth / login das telas) pelo do portal nos sites
#      painel-olt, painel-links, painel-pon e documentacao-noc que existirem aqui
#   3. atualiza o server.py do painel-pon e da documentação e liga PORTAL=1 no config.env
#   4. (se o portal roda nesta máquina) traz para o portal os usuários do painel-auth,
#      com a mesma senha
# Faz backup de tudo, confere com nginx -t e desfaz sozinho se algo der errado.
# Pode rodar de novo: o que já está vinculado fica como está.
set -euo pipefail

PORTAL="${PORTAL_URL:-https://portal.updown.com.br}"
PORTAL_LOCAL="${PORTAL_LOCAL:-http://127.0.0.1:8790}"
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REWRITER="$AQUI/vincular-portal.py"
BASE_BK=/root/vincular-portal
SITES=/etc/nginx/sites-available
SNIPPET=/etc/nginx/snippets/portal-sso.conf
CACHE_CONF=/etc/nginx/conf.d/portal-sso-cache.conf
# site do nginx : sistema no portal : tipo (painel = arquivos + painel-auth; proxy = app Python)
ALVOS=(painel-olt:olts:painel painel-links:links:painel painel-pon:pon:proxy documentacao-noc:documentacao:proxy)
# app : pasta : serviço
APPS=(painel-pon:/opt/painel-pon:painel-pon documentacao:/opt/documentacao-noc:documentacao-noc)

ok()   { printf '\033[32m✔\033[0m %s\n' "$*"; }
info() { printf '\033[36m•\033[0m %s\n' "$*"; }
erro() { printf '\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || erro "Rode como root (sudo bash vincular-portal.sh)."

# ---------------------------------------------------------------- desfazer
restaurar() {
  local bk="$1"
  [ -d "$bk" ] || erro "Backup $bk não encontrado."
  for f in "$bk"/nginx/*; do [ -e "$f" ] && cp -a "$f" "$SITES/$(basename "$f")"; done
  [ -f "$bk/snippet.conf" ] && cp -a "$bk/snippet.conf" "$SNIPPET" || { [ -f "$bk/snippet.novo" ] && rm -f "$SNIPPET"; }
  for a in "${APPS[@]}"; do
    IFS=: read -r nome pasta servico <<<"$a"
    [ -d "$bk/$nome" ] || continue
    [ -f "$bk/$nome/server.py" ] && cp -a "$bk/$nome/server.py" "$pasta/server.py"
    [ -f "$bk/$nome/config.env" ] && cp -a "$bk/$nome/config.env" "$pasta/config.env"
    [ -d "$bk/$nome/static" ] && { rm -rf "$pasta/static"; cp -a "$bk/$nome/static" "$pasta/static"; }
    systemctl restart "$servico" 2>/dev/null || true
  done
  nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
}

if [ "${1:-}" = "--desfazer" ]; then
  # o backup mais recente feito ANTES de vincular (rodar de novo gera backups já vinculados)
  ULT=""
  for b in $(ls -1d "$BASE_BK"/backup-* 2>/dev/null | sort -r); do
    if ! grep -qs "_portal_auth" "$b"/nginx/*; then ULT="$b"; break; fi
  done
  [ -n "$ULT" ] || erro "Nenhum backup de antes do vínculo em $BASE_BK."
  restaurar "$ULT"
  ok "Voltou como estava antes de $(basename "$ULT")."
  exit 0
fi

# ---------------------------------------------------------------- conferências
command -v nginx >/dev/null || erro "nginx não está instalado."
command -v python3 >/dev/null || erro "python3 não encontrado."
[ -f "$REWRITER" ] || erro "Falta $REWRITER (rode de dentro do repositório nocup)."
NGV="$(nginx -V 2>&1)"
[[ "$NGV" == *http_auth_request_module* ]] || erro "Este nginx não tem o módulo auth_request (instale nginx-full ou nginx-extras)."

ACHADOS=()
for a in "${ALVOS[@]}"; do IFS=: read -r site _ _ <<<"$a"; [ -f "$SITES/$site" ] && ACHADOS+=("$a"); done
[ "${#ACHADOS[@]}" -gt 0 ] || erro "Nenhum painel do NOC encontrado em $SITES (painel-olt, painel-links, painel-pon, documentacao-noc)."

# Portal: nesta máquina (127.0.0.1:8790) ou pela internet?
if curl -s -m 3 --noproxy '*' "$PORTAL_LOCAL/healthz" 2>/dev/null | grep -q ok; then
  MODO=local; ALVO_AUTH="$PORTAL_LOCAL"
  ok "Portal rodando nesta máquina ($PORTAL_LOCAL)."
else
  MODO=https; ALVO_AUTH="$PORTAL"
  code="$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$PORTAL/sso/verificar?sistema=olts" || true)"
  [ "$code" = "401" ] || erro "O portal não respondeu como esperado em $PORTAL/sso/verificar (HTTP $code; esperado 401). Confira DNS/firewall antes de vincular."
  ok "Portal respondendo em $PORTAL."
fi

BK="$BASE_BK/backup-$(date +%Y%m%d-%H%M%S)"
install -d -m 700 "$BK/nginx"
info "Backup em $BK"
falhou() { echo; printf '\033[31m✘ %s — desfazendo\033[0m\n' "$1" >&2; restaurar "$BK"; echo "Voltou como estava. Me mande as mensagens acima."; exit 1; }

# ---------------------------------------------------------------- 1. nginx: cache + snippet
if [ ! -f "$CACHE_CONF" ]; then
  cat > "$CACHE_CONF" <<'EOF'
# Login único do Portal NOC — gerado por vincular-portal.sh (nocup)
# Guarda por 30 s a resposta do portal para cada sessão + sistema.
proxy_cache_path /var/cache/nginx/portal-sso levels=1:2 keys_zone=portal_sso:2m max_size=20m inactive=5m use_temp_path=off;
EOF
  echo "$CACHE_CONF" > "$BK/cache.novo"
fi
install -d -m 755 /var/cache/nginx/portal-sso
chown www-data: /var/cache/nginx/portal-sso 2>/dev/null || true

install -d -m 755 /etc/nginx/snippets
if [ -f "$SNIPPET" ]; then cp -a "$SNIPPET" "$BK/snippet.conf"; else touch "$BK/snippet.novo"; fi
if [ "$MODO" = local ]; then
  DESTINO="proxy_pass $ALVO_AUTH/sso/verificar?sistema=\$portal_sistema;
    proxy_set_header Host portal.updown.com.br;
    proxy_set_header X-Forwarded-Proto https;"
else
  DESTINO="proxy_pass $ALVO_AUTH/sso/verificar?sistema=\$portal_sistema;
    proxy_ssl_server_name on;
    proxy_set_header Host ${PORTAL#https://};"
fi
cat > "$SNIPPET" <<EOF
# Login único do Portal NOC ($PORTAL) — gerado por vincular-portal.sh (nocup)
# Cada location protegida faz:  set \$portal_sistema <id>;  auth_request /_portal_auth;
location = /_portal_auth {
    internal;
    $DESTINO
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header Cookie \$http_cookie;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_connect_timeout 3s;
    proxy_read_timeout 5s;
    proxy_cache portal_sso;
    proxy_cache_key "\$portal_sistema|\$cookie_updown_sso";
    proxy_cache_valid 204 403 30s;
    proxy_ignore_headers Cache-Control Expires Set-Cookie;
}
# Sem sessão: login do portal e volta para cá depois.
location @portal_login {
    return 302 $PORTAL/login?sistema=\$portal_sistema&volta=\$scheme://\$http_host\$uri;
}
# Com sessão, mas sem permissão para este sistema.
location @portal_negado {
    return 302 $PORTAL/?negado=\$portal_sistema;
}
EOF
ok "Snippet do portal em $SNIPPET (consulta $([ "$MODO" = local ] && echo "local" || echo "por HTTPS"))."

# ---------------------------------------------------------------- 2. sites
for a in "${ACHADOS[@]}"; do
  IFS=: read -r site sistema tipo <<<"$a"
  f="$SITES/$site"
  cp -a "$f" "$BK/nginx/$site"
  python3 "$REWRITER" "$f" "$sistema" --tipo "$tipo" > "$BK/novo-$site" 2>"$BK/log-$site" || { cat "$BK/log-$site"; falhou "Não consegui reescrever $f"; }
  cat "$BK/novo-$site" > "$f"
  ok "$site -> sistema \"$sistema\" ($(cat "$BK/log-$site" | cut -d: -f1))"
done
if ! nginx -t >"$BK/nginx-t.log" 2>&1; then cat "$BK/nginx-t.log"; falhou "O nginx recusou a configuração nova"; fi
systemctl reload nginx
sleep 2   # o reload troca os workers em segundo plano
ok "nginx recarregado."

# ---------------------------------------------------------------- 3. apps Python (PON e documentação)
for a in "${APPS[@]}"; do
  IFS=: read -r nome pasta servico <<<"$a"
  [ -d "$pasta" ] && [ -f "$AQUI/$nome/server.py" ] || continue
  install -d -m 700 "$BK/$nome"
  [ -f "$pasta/server.py" ] && cp -a "$pasta/server.py" "$BK/$nome/"
  [ -f "$pasta/config.env" ] && cp -a "$pasta/config.env" "$BK/$nome/"
  install -m 755 "$AQUI/$nome/server.py" "$pasta/server.py"
  python3 -m py_compile "$pasta/server.py" || falhou "$pasta/server.py não compilou"
  # a página (static/) tem que acompanhar o server.py: página antiga com servidor novo
  # mostrava "só consulta" para todo mundo
  if [ -d "$AQUI/$nome/static" ] && [ -d "$pasta/static" ]; then
    cp -a "$pasta/static" "$BK/$nome/static"
    cp -a "$AQUI/$nome/static/." "$pasta/static/"
    chown -R www-data: "$pasta/static" 2>/dev/null || true
  fi
  if [ -f "$pasta/config.env" ]; then
    if grep -q '^PORTAL=' "$pasta/config.env"; then sed -i 's/^PORTAL=.*/PORTAL=1/' "$pasta/config.env"
    else printf '\n# Login único pelo Portal NOC (vincular-portal.sh)\nPORTAL=1\n' >> "$pasta/config.env"; fi
  fi
  systemctl restart "$servico" || falhou "O serviço $servico não reiniciou"
  ok "$servico: login pelo portal (PORTAL=1)."
done

# ---------------------------------------------------------------- 4. usuários antigos do painel-auth
if [ "$MODO" = local ] && [ -f /etc/painel-olt/users.json ] && [ -f /opt/portal-noc/server.mjs ]; then
  echo
  info "Usuários do login antigo (painel-auth): $(python3 -c 'import json;print(", ".join(sorted(json.load(open("/etc/painel-olt/users.json")))))' 2>/dev/null || echo '?')"
  read -rp "Trazer esses usuários para o portal, com a mesma senha (perfil analista, todos os sistemas)? [S/n] " R
  case "${R:-S}" in
    [Nn]*) info "Usuários antigos não importados." ;;
    *)
      DATA_DIR="$(grep -oP '^DATA_DIR=\K.*' /etc/portal-noc.env 2>/dev/null || echo /var/lib/portal-noc)"
      cp -a "$DATA_DIR/users.json" "$BK/portal-users.json" 2>/dev/null || true
      # com o portal parado, para ele não sobrescrever a lista ao salvar
      systemctl stop portal-noc
      if runuser -u portal-noc -- env DATA_DIR="$DATA_DIR" node /opt/portal-noc/server.mjs importar-painel-auth /etc/painel-olt/users.json \
         || env DATA_DIR="$DATA_DIR" node /opt/portal-noc/server.mjs importar-painel-auth /etc/painel-olt/users.json; then
        chown -R portal-noc: "$DATA_DIR" 2>/dev/null || true
        ok "Usuários importados. Ajuste perfil e sistemas de cada um em $PORTAL (Usuários)."
      else
        info "Não consegui importar (o resto ficou vinculado)."
      fi
      systemctl start portal-noc
      ;;
  esac
elif [ -f /etc/painel-olt/users.json ]; then
  info "Usuários do login antigo estão em /etc/painel-olt/users.json. Para trazê-los ao portal (com a mesma senha),"
  info "copie o arquivo para o servidor do portal e rode lá:"
  info "  sudo systemctl stop portal-noc && sudo -u portal-noc DATA_DIR=/var/lib/portal-noc node /opt/portal-noc/server.mjs importar-painel-auth users.json && sudo systemctl start portal-noc"
fi

# ---------------------------------------------------------------- 5. conferência
echo
for a in "${ACHADOS[@]}"; do
  IFS=: read -r site sistema _ <<<"$a"
  srv="$(grep -m1 -oP '^\s*server_name\s+\K[^ ;]+' "$SITES/$site" | head -n1)"
  porta="$(grep -oP '^\s*listen\s+\K\d+(?=[^;]*\bssl\b)' "$SITES/$site" | head -n1)"
  [ -n "$srv" ] && [ -n "$porta" ] || continue
  r="$(curl -sk --noproxy '*' -o /dev/null -w '%{http_code} %{redirect_url}' --resolve "$srv:$porta:127.0.0.1" "https://$srv:$porta/" || true)"
  case "$r" in
    "302 $PORTAL/login"*) ok "$sistema (https://$srv:$porta) sem sessão vai para o login do portal." ;;
    *) info "$sistema (https://$srv:$porta) respondeu \"$r\" sem sessão (esperado 302 para $PORTAL/login)." ;;
  esac
done

echo
ok "Pronto. Crie e libere os usuários em $PORTAL (Usuários -> sistemas)."
echo "   Quem entra no portal abre os painéis liberados sem digitar a senha de novo."
echo "   Desfazer:  sudo bash $AQUI/vincular-portal.sh --desfazer"
echo "   Se rodar de novo um instalar-*.sh (que reescreve o nginx), rode este script depois."
