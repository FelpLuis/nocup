# Painel de alertas PON / CTO — UpDown NOC (TV)

Tela para o telão do NOC: mostra **só o que está fora do ar agora**. Quando uma PON ou CTO cai, o card aparece (com som opcional). Quando ela volta, o card sai da tela e passa alguns minutos na lista "Normalizadas recentemente".

## Critério dos alertas (o mesmo do WhatsApp "Wpp PON")

A tela não tem regra própria para CTO: ela lê no Zabbix **as ações que enviam para a mídia `Wpp PON`** e aplica as mesmas condições (host, grupo, nome do trigger, severidade, tags…) aos problemas ativos. O que iria para o WhatsApp aparece na TV. Quando o problema é resolvido no Zabbix, o card sai.

| O que | Regra |
|---|---|
| **CTO down** | problema ativo que passa nas condições das ações da `Wpp PON` e cita a CTO (tag `cto` ou "CTO 012" no nome) |
| **Queda massiva** | o trigger "Queda massiva" ativo acende a faixa; as CTOs da `ixc.cto.quedas.lista` entram como cards, com a PON de cada uma |
| **Queda parcial** | só aparece se as ações da `Wpp PON` também enviam esse trigger |
| **PON down** | a PON **tem cliente** e **todos os clientes monitorados estão desconectados** (`onu.motivo_desconexao` preenchido, igual ao trigger "Cliente desconectado"), ou todas as CTOs com cliente dela estão fora |
| **PON sem cliente** | nunca é alerta, mesmo com a porta down na OLT; aparece apagada na grade |

O rodapé da tela mostra qual critério está valendo. Se o token não puder ler as ações (`action.get`), a tela avisa e usa os problemas ativos do host `IXC - CTO`. Para usar exatamente as ações, dê ao usuário do token o papel **Admin** (leitura).

**Conferir o critério:** com login, abra `/api/debug`. Mostra as ações encontradas, as condições, os problemas que passaram no filtro e o texto da lista de queda massiva.

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

- `SHOW_PARTIAL=0` para mostrar só quedas totais.
- `PON_MIN_ONUS` / `PON_MIN_CTOS` controlam quando uma PON é considerada down.
