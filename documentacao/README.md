# Documentação de equipamentos — UPDOWN NOC

Site editável com a documentação das interfaces dos roteadores, switches e DWDM da UPDOWN, separados por **site** e **rack** num rack 3D, com o status atual de cada interface lido do **Zabbix próprio**.

Endereço: **https://documentacao.noc.updown.com.br**

## O que tem no site

- **Racks por site em 3D**: cada porta física é um LED com a cor do status documentado (up, down, proto down, shutdown). Clique num equipamento ou porta para abrir a ficha e a linha na tabela. Com "Auto-giro" ligado a câmera passeia pelos sites.
- **Tabela editável** por equipamento: interface, destino, serviço, observação e status. Colunas do Zabbix ao lado (status atual, velocidade, Rx/Tx em dBm) e o filtro **Divergem do Zabbix**.
- **Ficha do equipamento**: modelo, site, rack, função, IP de gerência, host(s) no Zabbix e notas. O sysName, a sysLocation e a versão vêm do Zabbix.
- **Importar do Zabbix**: quando o Zabbix tem interfaces que ainda não estão na documentação, aparece o botão "Importar N interfaces do Zabbix".
- **Exportar XLSX/CSV** (uma aba por equipamento + inventário) e **Importar XLSX** no mesmo formato da planilha DOC_SW.

## Cofre de acessos (pessoal)

Cada usuário tem o **seu próprio cofre** ("Meu cofre", no topo ou no cofre do começo da cena 3D), com a **sua** senha mestra. O que o luis.felipe guarda, o gabriel e os outros usuários **não veem**, nem o administrador do portal.

- **Quem é o dono:** com `PORTAL=1` (ligado pelo `vincular-portal.sh`), o dono é o usuário do Portal NOC que o nginx repassa no cabeçalho `X-Portal-User`. O servidor só aceita esse cabeçalho vindo do nginx da própria máquina e nunca recebe o nome do usuário pelo navegador. Desativar ou derrubar a sessão de alguém no portal corta também o acesso ao cofre dele. Sem portal, o dono é a conta local (NOC).
- **Cifrado no navegador:** AES-256-GCM, chave derivada da senha mestra (PBKDF2-SHA256, 600 mil iterações). O servidor guarda só o conteúdo cifrado, um arquivo por usuário em `data/cofres/`, e não tem como abrir.
- **Senha mestra esquecida = cofre perdido.** Não existe recuperação, nem pelo administrador.
- Conteúdo: plataforma, link, usuário, senha, campos extras (token, código…) e notas. Acessos de aparelhos ficam **ligados aos equipamentos** e aparecem na ficha de cada um, só para o dono.
- Tranca sozinho depois de 10 minutos parado. Funciona só em HTTPS.
- **Importar arquivo** aceita o `cofre-importar.json` (formato `updown-cofre`). Depois de importar e salvar, apague o arquivo do computador.
- **Cofre compartilhado da versão anterior** (`data/cofre.json`): aparece um aviso no cofre de quem entrar. Quem souber a senha mestra antiga traz os acessos para o próprio cofre e retira o antigo do servidor (fica só uma cópia cifrada em `historico-cofre/`).
- Nenhuma senha vai para o Git: os cofres existem só no servidor (`data/` está no `.gitignore`).

## Onde ficam os dados

| Arquivo (em `/opt/documentacao-noc/data/`) | O que é |
|---|---|
| `equipamentos.json` | a documentação (o que a equipe edita). Criado na 1ª vez a partir de `dados-iniciais.json` |
| `historico/` | cópia de cada versão anterior, com data e versão (mantém as últimas 200) |
| `cofres/` | um cofre por usuário, **só cifrado** (versões anteriores em `historico-cofre/usuarios/`) |
| `zabbix.json` | cache do Zabbix, refeito a cada 5 min (`SYNC_MINUTES`) ou no botão "Ler Zabbix" |

O status do Zabbix **não é gravado** na documentação: o site mostra os dois lado a lado. Se duas pessoas editarem ao mesmo tempo, quem salvar depois recebe um aviso para recarregar (nada é sobrescrito sem querer).

Para voltar uma versão antiga: `sudo cp /opt/documentacao-noc/data/historico/ARQUIVO.json /opt/documentacao-noc/data/equipamentos.json && sudo systemctl restart documentacao-noc`.

## Instalação (servidor .13, o mesmo do Zabbix)

Antes, no DNS do `updown.com.br` (HostGator): registro **A** `documentacao.noc` → `190.111.110.13`. As portas **80** e **443** precisam chegar ao servidor (o certificado do Let's Encrypt é emitido pela porta 80).

```bash
git clone https://github.com/FelpLuis/nocup.git && cd nocup     # ou: cd nocup && git pull
sudo bash instalar-documentacao.sh
```

O instalador copia tudo para `/opt/documentacao-noc`, pede o token do Zabbix (ou reaproveita o do painel-pon), liga o serviço `documentacao-noc` na porta 8447 local, publica no nginx e pede o certificado com o certbot. Se algo falhar, desfaz e volta como estava (backup em `/root/documentacao-noc/`).

- Porta 443 ocupada ou não encaminhada? `sudo PORTA_HTTPS=8447 bash instalar-documentacao.sh` (precisa do certificado; a porta 80 continua sendo usada para emiti-lo).
- E-mail para avisos do Let's Encrypt: `sudo EMAIL_CERT=noc@... bash instalar-documentacao.sh`.
- Para atualizar depois: `git pull && sudo bash instalar-documentacao.sh`. O `config.env` e a documentação salva são mantidos.

**Token:** Zabbix → Usuários → Tokens de API, com um usuário que tenha **leitura** no grupo `Links UpDown`. Fica só em `/opt/documentacao-noc/config.env` (fora do Git, permissão 600).

## Login

**Com o Portal NOC (recomendado):** os usuários são os do portal (https://portal.updown.com.br); a documentação não tem cadastro próprio. Para ligar: `sudo bash vincular-portal.sh` (no repositório nocup). Depois, no portal, em **Usuários**, libere o sistema **Documentação** para quem deve acessar. Reinstalar com `instalar-documentacao.sh` mantém o vínculo. Se o nginx ficar sem o vínculo, o site manda para o login do portal e o log avisa (`journalctl -u documentacao-noc`).

**Sem portal:** conta local abaixo.


Usuário **NOC**. A senha não fica no repositório: o `config.env` guarda só o hash (PBKDF2). Depois de 5 senhas erradas em 15 min, o IP e o usuário ficam bloqueados por 15 min.

Para trocar a senha (derruba as sessões abertas):

```bash
sudo -u www-data python3 /opt/documentacao-noc/server.py senha    # gera a linha LOGIN_SENHA_HASH=...
sudo nano /opt/documentacao-noc/config.env                          # substitui a linha
sudo systemctl restart documentacao-noc
```

Opcional: `USERS_FILE=/etc/painel-olt/users.json` também aceita os usuários do Painel das OLTs; `EDITORES=noc` deixa os outros só consultando.

## Ligar um equipamento ao Zabbix

Na ficha do equipamento, campo **Host(s) no Zabbix**: o nome do host como aparece no Zabbix (um por linha). O F1A CENTRAL usa dois: `NE8000 F1A PPPOE BASE` e `NE8000 F1A VS BGP BASE` (o sistema virtual BGP do mesmo chassi; as portas dele aparecem com a marca VS). Salve e clique em "Ler Zabbix".

## Rodar na sua máquina (teste)

```bash
cd documentacao && cp config.env.example config.env   # ajuste ZABBIX_URL/ZABBIX_TOKEN, LOGIN=0 e DATA_DIR=./data
python3 server.py                                      # http://127.0.0.1:8447
```
