# nocup

Scripts e painéis do NOC da UpDown Internet.

| Arquivo | O que é |
|---|---|
| `painel-olt.html`, `instalar-login.sh` | Painel das OLTs (porta 8443) e login |
| `instalar-links.sh`, `instalar-tv.sh` | Painel de links (porta 9443) e telas de TV |
| `provisionar-zabbix.py`, `iniciar_migracao_pon.py` | Provisionamento do Zabbix próprio |
| `painel-pon/`, `instalar-pon.sh` | Tela de TV de alertas PON down / CTO down (porta 8446) — veja [painel-pon/README.md](painel-pon/README.md) |
| `documentacao/`, `instalar-documentacao.sh` | Documentação de equipamentos (racks 3D por site, interfaces editáveis + Zabbix) em https://documentacao.noc.updown.com.br — veja [documentacao/README.md](documentacao/README.md) |
| `vincular-portal.sh`, `vincular-portal.py` | Liga todos os painéis acima ao login único do [Portal NOC](https://portal.updown.com.br) |

## Login único (Portal NOC)

O usuário criado em **https://portal.updown.com.br** (Usuários → sistemas liberados) é o mesmo em todos os painéis.
Em cada servidor que tem painéis:

```bash
cd nocup && git pull
sudo bash vincular-portal.sh
```

O script troca, no nginx, o login próprio de cada painel (painel-auth, `/entrar`, `/login`) pela consulta ao portal
(`auth_request` → `/sso/verificar?sistema=<id>`), liga `PORTAL=1` no painel-pon e na documentação e, se o portal roda
na mesma máquina, oferece trazer os usuários antigos do painel-auth com a mesma senha. Faz backup, testa com `nginx -t`
e desfaz sozinho se algo falhar. `sudo bash vincular-portal.sh --desfazer` volta ao login antigo.

| Painel | Sistema no portal |
|---|---|
| Painel das OLTs (:8443) | `olts` |
| Painel de Links (:9443) | `links` |
| TV · Links (`/tv`) / TV · ISP (`/tv-isp`) | `tv-links` / `tv-isp` (a API de dados aceita quem tiver links ou uma das TVs) |
| Alertas PON / CTO (:8446) | `pon` |
| Documentação | `documentacao` (quem edita continua sendo o `EDITORES` do config.env; vazio = todos) |

Rodou de novo algum `instalar-*.sh` (eles reescrevem o nginx)? Rode o `vincular-portal.sh` depois.
