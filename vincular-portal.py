#!/usr/bin/env python3
"""
Liga um site do nginx ao login único do Portal NOC (portal.updown.com.br).

    python3 vincular-portal.py ARQUIVO SISTEMA [--tipo painel|proxy]

Reescreve o bloco server { } com "listen ... ssl" do ARQUIVO para que o nginx
pergunte ao portal (auth_request /_portal_auth) se a sessão é válida e se o
usuário tem permissão para SISTEMA. O login próprio do painel (painel-auth, /entrar,
/login, /logout) passa a ser do portal. Imprime o arquivo novo na saída padrão;
quem grava, testa (nginx -t) e desfaz é o vincular-portal.sh.

Já vinculado (tem /_portal_auth)? Devolve o arquivo sem mudar nada.
Só usa a biblioteca padrão do Python 3.
"""
import re
import sys

PORTAL = "https://portal.updown.com.br"
SNIPPET = "/etc/nginx/snippets/portal-sso.conf"
LOGIN_PATHS = {"/login", "/entrar", "/logout", "/sessao", "/login.html"}


def blocos(texto, inicio_re):
    """[(ini, fim, cabeçalho)] dos blocos { } cujo cabeçalho casa com inicio_re (fim = após a '}')."""
    out = []
    for m in re.finditer(inicio_re, texto, re.M):
        i = texto.index("{", m.start())
        nivel, j = 0, i
        while j < len(texto):
            c = texto[j]
            if c == "#":                       # comentário até o fim da linha
                j = texto.find("\n", j)
                if j < 0:
                    break
                continue
            if c in "'\"":                     # string: pula até fechar
                k = j + 1
                while k < len(texto) and texto[k] != c:
                    k += 2 if texto[k] == "\\" else 1
                j = k + 1
                continue
            if c == "{":
                nivel += 1
            elif c == "}":
                nivel -= 1
                if nivel == 0:
                    out.append((m.start(), j + 1, texto[m.start():i].strip()))
                    break
            j += 1
    return out


def padrao(cab):
    """'location ~ ^/(login|logout)$' -> ('~', '^/(login|logout)$')"""
    partes = cab.split()[1:]
    if len(partes) == 1:
        return "", partes[0]
    return partes[0], partes[1]


def eh_login(mod, pat):
    if pat.startswith("@"):
        return pat in ("@login", "@entrar")
    if mod in ("=", "") and pat in LOGIN_PATHS:
        return True
    if mod.startswith("~"):
        return any(re.search(r"\b%s\b" % p.strip("/"), pat) for p in ("login", "logout", "sessao", "entrar"))
    return False


def sistema_da_location(pat, sistema):
    if sistema != "links":
        return None
    if "tv-isp" in pat:
        return "tv-isp"
    if pat.startswith("/tv") or pat.startswith("^/tv"):
        return "tv-links"
    if pat.startswith("/api"):
        return "links,tv-links,tv-isp"       # a API alimenta o painel e as TVs
    return None


def linhas_auth(indent, pagina, proxy):
    out = [
        f"{indent}auth_request /_portal_auth;",
        f"{indent}auth_request_set $portal_user $upstream_http_x_portal_user;",
        f"{indent}auth_request_set $portal_role $upstream_http_x_portal_role;",
    ]
    if pagina:
        out += [f"{indent}error_page 401 = @portal_login;", f"{indent}error_page 403 = @portal_negado;"]
    if proxy:
        out.append(f"{indent}proxy_set_header X-Portal-User $portal_user;")
        out.append(f"{indent}proxy_set_header X-Portal-Role $portal_role;")
    return "\n".join(out)


def com_perfil(bloco):
    """Location já vinculada numa rodada antiga: passa a repassar também o perfil do portal
    (X-Portal-Role), para o app saber quem é administrador."""
    if "proxy_pass" not in bloco or "X-Portal-Role" in bloco:
        return bloco
    m = re.search(r"^([ \t]*)auth_request_set\s+\$portal_user\s+\$upstream_http_x_portal_user\s*;[^\n]*\n", bloco, re.M)
    if not m:
        return bloco
    ind = m.group(1)
    bloco = bloco[:m.end()] + f"{ind}auth_request_set $portal_role $upstream_http_x_portal_role;\n" + bloco[m.end():]
    m = re.search(r"^([ \t]*)proxy_set_header\s+X-Portal-User\s+\$portal_user\s*;[^\n]*\n", bloco, re.M)
    if m:
        bloco = bloco[:m.end()] + f"{m.group(1)}proxy_set_header X-Portal-Role $portal_role;\n" + bloco[m.end():]
    return bloco


def vincular_location(bloco, cab, sistema, tipo):
    mod, pat = padrao(cab)
    ind = re.search(r"\n([ \t]+)\S", bloco)
    indent = ind.group(1) if ind else "        "
    if "_portal_auth" in bloco:
        return com_perfil(bloco)
    tem_auth = re.search(r"\bauth_request\s+/_auth\w*\s*;", bloco)
    proxy = "proxy_pass" in bloco
    sis = sistema_da_location(pat, sistema)
    if not tem_auth and not (tipo == "proxy" and pat == "/" and mod == ""):
        return bloco
    pagina = bool(re.search(r"error_page\s+401", bloco)) or (pat == "/" and mod == "")
    # tira o login antigo
    corpo = re.sub(r"[ \t]*\bauth_request\s+/_auth\w*\s*;[ \t]*\n?", "", bloco)
    corpo = re.sub(r"[ \t]*\berror_page\s+40[13]\s*=\s*@\w+\s*;[ \t]*\n?", "", corpo)
    # trava antiga "só o usuário X" (ex.: TVs só para o noc): agora quem decide é a
    # permissão do sistema no portal
    corpo = re.sub(r"[ \t]*\bif\s*\(\s*\$\w*user\s*!=?\s*[^)]*\)\s*\{\s*return\s+403\s*;\s*\}[ \t]*\n?", "", corpo)
    corpo = corpo.replace("$upstream_http_x_painel_user", "$upstream_http_x_portal_user")
    abre = corpo.index("{") + 1
    # o "set" fica na location (no nível do server o nginx o refaz dentro da
    # subrequisição do auth_request e perderia o sistema específico, ex.: tv-isp)
    novo = f"{indent}set $portal_sistema {sis or sistema};\n" + linhas_auth(indent, pagina, proxy)
    return corpo[:abre] + "\n" + novo + corpo[abre:]


def vincular_server(srv, sistema, tipo):
    ja = "/_portal_auth" in srv          # rodada anterior: só converte o que sobrou do login antigo
    # 1. locations: remove as do login antigo, protege as demais
    locs = blocos(srv, r"^[ \t]*location\b[^{]*\{")
    partes, pos = [], 0
    for ini, fim, cab in locs:
        if ini < pos:          # location aninhada: já tratada pelo bloco de fora
            continue
        mod, pat = padrao(cab)
        partes.append(srv[pos:ini])
        bloco = srv[ini:fim]
        if "portal" not in bloco and (pat.startswith("/_auth") or eh_login(mod, pat)):
            # apaga a linha inteira (e o \n seguinte)
            if fim < len(srv) and srv[fim] == "\n":
                fim += 1
            partes[-1] = partes[-1].rstrip(" \t")
        else:
            partes.append(vincular_location(bloco, cab, sistema, tipo))
        pos = fim
    partes.append(srv[pos:])
    srv = "".join(partes)

    if ja:
        return srv
    # 2. include do portal + rotas de entrada/saída, logo depois do server_name
    m = re.search(r"^([ \t]*)server_name[^;]*;[^\n]*\n", srv, re.M)
    if not m:
        m = re.search(r"^([ \t]*)listen[^;]*;[^\n]*\n", srv, re.M)
    ind = m.group(1) or "    "
    volta = "$scheme://$http_host/"
    entrar = f"return 302 {PORTAL}/login?sistema={sistema}&volta={volta};"
    extra = f"""
{ind}# Login único: Portal NOC ({PORTAL}) — gerado por vincular-portal.sh
{ind}include {SNIPPET};
{ind}location = /login  {{ {entrar} }}
{ind}location = /entrar {{ {entrar} }}
{ind}location = /logout {{ return 302 {PORTAL}/sso/sair; }}
{ind}location = /sessao {{
{ind}    set $portal_sistema {sistema};
{ind}    auth_request /_portal_auth;
{ind}    auth_request_set $portal_user $upstream_http_x_portal_user;
{ind}    error_page 401 403 = @portal_sem_sessao;
{ind}    try_files /.portal-sessao-inexistente @portal_sessao;
{ind}}}
{ind}location @portal_sessao {{ default_type application/json; return 200 '{{"authenticated":true,"user":"$portal_user","portal":"{PORTAL}"}}'; }}
{ind}location @portal_sem_sessao {{ default_type application/json; return 200 '{{"authenticated":false}}'; }}
"""
    return srv[:m.end()] + extra + srv[m.end():]


def vincular(texto, sistema, tipo):
    servers = [b for b in blocos(texto, r"^[ \t]*server\s*\{") if re.search(r"listen[^;]*\bssl\b", texto[b[0]:b[1]])]
    if not servers:
        raise SystemExit("nenhum bloco server { listen ... ssl } no arquivo")
    out, pos = [], 0
    for ini, fim, _ in servers:
        out.append(texto[pos:ini])
        out.append(vincular_server(texto[ini:fim], sistema, tipo))
        pos = fim
    out.append(texto[pos:])
    novo = "".join(out)
    return novo, novo != texto


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__)
    arquivo, sistema = argv[1], argv[2]
    tipo = "painel"
    if "--tipo" in argv:
        tipo = argv[argv.index("--tipo") + 1]
    texto = open(arquivo, encoding="utf-8").read()
    novo, mudou = vincular(texto, sistema, tipo)
    sys.stdout.write(novo)
    sys.stderr.write(("vinculado: " if mudou else "já estava vinculado: ") + arquivo + "\n")


if __name__ == "__main__":
    main(sys.argv)
