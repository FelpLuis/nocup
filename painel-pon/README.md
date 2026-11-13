# Painel de alertas PON / CTO — UpDown NOC (TV)

Tela para o telão do NOC: mostra **só o que está fora do ar agora**. Quando uma PON ou CTO cai, o card aparece (com som opcional). Quando ela volta, o card sai da tela e passa alguns minutos na lista "Normalizadas recentemente".

## De onde vêm os dados (Zabbix próprio 190.111.110.13:19090)

| O que | Fonte no Zabbix | Regra |
|---|---|---|
| **CTO down** | host `IXC - CTO`: `clientesCTO[NNN]` e `sessoesCTO[NNN]` | clientes > 0 e **0 sessões online** |
| **Queda parcial** | problemas ativos no host `IXC - CTO` com tag `cto` | trigger "Queda parcial no número de sessões" ativo |
| **Causa** | `causaCTO[NNN]` | ex.: "Queda de energia: 9 ONUs" |
| **PON down** | grupo `GPON/ONUs` (`onu.olt`, `onu.porta`, `onu.estado`) | todas as ONUs monitoradas da PON fora (mín. 2) |
| | grupo `OLTs UpDown`, status operacional da interface `gpon-olt_x/y/z` | se o template coletar: status 2/7 = down |
| | CTO → PON (JSON do IXC ou `cto_map.json`) | todas as CTOs da PON sem cliente online |
| **Queda massiva** | contagem de CTOs down / `ixc.cto.quedas` | ≥ `MASSIVE_MIN` acende a faixa |
| **Desde quando** | horário do problema no Zabbix; se não houver, a 1ª coleta em que apareceu | |

Quando uma PON está down, as CTOs dela ficam **agrupadas dentro do card da PON**, sem repetir um card por CTO.

## Instalação (UPT-UBUNTU02)

No servidor, a partir do repositório:

```bash
git clone https://github.com/FelpLuis/nocup.git && cd nocup
sudo bash instalar-pon.sh
```

O instalador copia tudo para `/opt/painel-pon` e pede o token da API do Zabbix próprio (`127.0.0.1:19090`) na primeira vez. Ele testa o token antes de ligar o serviço `painel-pon` e, se houver certificado de `monitoramento.updown.com.br`, publica em **https://monitoramento.updown.com.br:8446**. Se algo falhar, desfaz e volta como estava (backup em `/root/painel-pon/`).

Para atualizar depois: `git pull && sudo bash instalar-pon.sh`. O `config.env` (token e ajustes) é mantido.

**Token:** crie em Zabbix → Usuários → Tokens de API, com um usuário que tenha **leitura** nos grupos `IXC`, `GPON/ONUs` e `OLTs UpDown`. O token fica só em `/opt/painel-pon/config.env` (fora do Git, permissão 600).

## Login

A tela usa **os mesmos usuários do Painel das OLTs** (`/etc/painel-olt/users.json`). Para criar um usuário ou trocar a senha:

```bash
sudo python3 /opt/painel-olt/painel-auth.py adduser NOME
```

- **Manter conectado nesta TV** vem marcado e vale por 90 dias (`SESSION_TV_DAYS`). Sem ele, a sessão dura 12 h (`SESSION_HOURS`).
- Depois de 5 senhas erradas em 15 min, o IP e o usuário ficam bloqueados por 15 min. A tela mostra a contagem regressiva.
- Trocar a senha ou remover o usuário derruba as sessões abertas dele, inclusive a da TV.
- Contas só desta tela: `BASIC_AUTH=usuario:senha` no `config.env`. Para desligar o login: `LOGIN=0`.

## Na TV

- Entre com o usuário do NOC, clique em **⛶** (tela cheia) e em **🔇 Som** para ligar o bipe (o navegador só libera som depois de um clique; a escolha fica salva).
- Para ver a tela sem Zabbix: `http://IP:8445/?demo`.
- Se o servidor ou o Zabbix pararem de responder, a pílula do topo fica amarela "SEM DADOS RECENTES" e aparece a faixa de erro, para a TV nunca mostrar "tudo OK" com dado velho.

## "PON não mapeada" nos cards de CTO

O painel tenta tirar a PON de cada CTO do JSON que o template do IXC já coleta (`ixc.cto.*`) e da `ixc.cto.quedas.lista`. Se os cards mostrarem "PON não mapeada", crie um `cto_map.json` (veja `cto_map.example.json`) ou me mande um exemplo do valor do item JSON mestre do host `IXC - CTO` que eu ajusto a leitura.

## Ajustes (config.env)

- `CONFIRM_POLLS=2` para exigir duas coletas seguidas antes de mostrar uma CTO (menos falso positivo).
- `SHOW_PARTIAL=0` para mostrar só quedas totais.
- `PON_MIN_ONUS` / `PON_MIN_CTOS` controlam quando uma PON é considerada down.
