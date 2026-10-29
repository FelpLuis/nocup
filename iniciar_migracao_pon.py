#!/usr/bin/env python3
"""
Auditoria inicial, somente leitura, do Zabbix e teste opcional da Evolution API.
Não cria ações, mídias nem altera configurações no Zabbix.
"""
import getpass
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

try:
    import requests
except ImportError:
    print("Falta a biblioteca requests. Ative um ambiente virtual e instale com: pip install requests")
    sys.exit(1)

DEFAULT_ZABBIX = "http://190.111.110.13:19090/api_jsonrpc.php"
DEFAULT_EVOLUTION = "http://190.111.110.13:19080"
DEFAULT_INSTANCE = "6cb38193-cc66-4bc6-bc65-893d7b0a91f5"
DEFAULT_GROUP = "120363432090900917@g.us"
KEYWORDS = re.compile(r"\b(pon|gpon|olt|onu|optical|fiber|fibra)\b", re.I)

def ask(prompt, default=""):
    suffix = f" [{default}]" if default else ""
    value = input(f"{prompt}{suffix}: ").strip()
    return value or default

def zabbix_call(session, url, method, params, request_id):
    response = session.post(
        url,
        json={"jsonrpc": "2.0", "method": method, "params": params, "id": request_id},
        timeout=25,
    )
    response.raise_for_status()
    data = response.json()
    if data.get("error"):
        err = data["error"]
        raise RuntimeError(f"{method}: {err.get('message', 'API error')} — {err.get('data', '')}")
    return data.get("result")

def main():
    print("\n=== Auditoria inicial Zabbix → Evolution API ===")
    print("Este programa faz consultas de leitura. Não cria nem altera configurações.")
    print("Credenciais são solicitadas no terminal e não são gravadas no relatório.\n")

    zurl = ask("Endpoint JSON-RPC do Zabbix", DEFAULT_ZABBIX)
    ztoken = getpass.getpass("Token do Zabbix (entrada oculta): ").strip()
    if not ztoken:
        print("Token vazio. Encerrando sem conexão.")
        return 2

    zs = requests.Session()
    zs.headers.update({
        "Content-Type": "application/json-rpc",
        "Authorization": "Bearer " + ztoken,
    })

    report = {
        "generated_at": datetime.now().astimezone().isoformat(),
        "zabbix_endpoint": zurl,
        "zabbix_version": None,
        "matching_hosts": [],
        "matching_triggers": [],
        "recent_problems": [],
        "errors": [],
    }

    try:
        version = zabbix_call(zs, zurl, "apiinfo.version", {}, 1)
        report["zabbix_version"] = version
        print(f"\n[OK] API do Zabbix respondeu. Versão: {version}")

        hosts = zabbix_call(zs, zurl, "host.get", {
            "output": ["hostid", "host", "name", "status"],
            "selectHostGroups": ["name"],
            "filter": {"status": 0},
        }, 2) or []

        matching = []
        for host in hosts:
            groups = host.get("hostgroups", host.get("groups", [])) or []
            text = " ".join([
                host.get("host", ""),
                host.get("name", ""),
                " ".join(g.get("name", "") for g in groups),
            ])
            if KEYWORDS.search(text):
                matching.append(host)

        host_ids = [h["hostid"] for h in matching]
        print(f"[OK] Hosts habilitados encontrados: {len(hosts)}")
        print(f"[INFO] Hosts candidatos por nome/grupo PON/GPON/OLT/ONU/fibra: {len(matching)}")

        for h in matching:
            report["matching_hosts"].append({
                "hostid": h.get("hostid"),
                "host": h.get("host"),
                "name": h.get("name"),
                "status": h.get("status"),
                "groups": [g.get("name") for g in h.get("hostgroups", h.get("groups", [])) or []],
            })

        triggers = []
        for start in range(0, len(host_ids), 100):
            batch = host_ids[start:start + 100]
            if batch:
                triggers.extend(zabbix_call(zs, zurl, "trigger.get", {
                    "hostids": batch,
                    "output": ["triggerid", "description", "priority", "status", "value", "lastchange"],
                    "selectHosts": ["hostid", "host", "name"],
                    "selectTags": ["tag", "value"],
                    "monitored": True,
                }, 3 + start // 100) or [])

        for t in triggers:
            report["matching_triggers"].append({
                "triggerid": t.get("triggerid"),
                "description": t.get("description"),
                "priority": t.get("priority"),
                "status": t.get("status"),
                "value": t.get("value"),
                "lastchange": t.get("lastchange"),
                "hosts": [{"hostid": h.get("hostid"), "host": h.get("host"), "name": h.get("name")}
                          for h in t.get("hosts", [])],
                "tags": t.get("tags", []),
            })
        print(f"[INFO] Triggers monitoradas associadas aos hosts candidatos: {len(triggers)}")

        try:
            problems = zabbix_call(zs, zurl, "problem.get", {
                "output": ["eventid", "source", "object", "objectid", "clock", "name", "severity", "acknowledged"],
                "selectTags": "extend",
                "sortfield": ["eventid"],
                "sortorder": "DESC",
                "recent": True,
                "limit": 100,
            }, 90) or []
            report["recent_problems"] = problems
            print(f"[INFO] Problemas recentes retornados: {len(problems)}")
        except Exception as e:
            report["errors"].append(f"problem.get: {e}")
            print(f"[AVISO] Não foi possível consultar problem.get: {e}")

    except Exception as e:
        print(f"\n[ERRO] Falha na consulta ao Zabbix: {e}")
        report["errors"].append(f"zabbix: {e}")
        print("Confira endpoint, token, conectividade e permissões de leitura.")
        return_code = 1
    else:
        return_code = 0
    finally:
        zs.close()
        ztoken = None

    out = Path("auditoria_zabbix_pon.json")
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    try:
        out.chmod(0o600)
    except OSError:
        pass
    print(f"\nRelatório salvo em: {out.resolve()}")
    print("O relatório não contém tokens, mas pode conter nomes internos de hosts e alarmes; compartilhe somente com pessoas autorizadas.")

    if return_code != 0:
        return return_code

    print("\n=== Teste opcional da Evolution API ===")
    print("O teste envia uma mensagem REAL ao grupo de WhatsApp.")
    send = ask("Deseja enviar agora uma mensagem de teste ao grupo? Digite SIM para confirmar", "NÃO")
    if send != "SIM":
        print("Teste de envio ignorado. Nenhuma mensagem foi enviada.")
        return 0

    evo_url = ask("URL base da Evolution API", DEFAULT_EVOLUTION).rstrip("/")
    instance = ask("Nome/ID da instância Evolution", DEFAULT_INSTANCE)
    group = ask("JID do grupo WhatsApp", DEFAULT_GROUP)
    apikey = getpass.getpass("Nova chave API da Evolution (entrada oculta): ").strip()
    if not apikey:
        print("Chave vazia. Nenhuma mensagem foi enviada.")
        return 2

    text = "TESTE DE INTEGRACAO - ZABBIX PON\nMensagem de validação da integração."
    endpoint = f"{evo_url}/message/sendText/{quote(instance, safe='')}"
    try:
        r = requests.post(
            endpoint,
            headers={"Content-Type": "application/json", "apikey": apikey},
            json={"number": group, "text": text},
            timeout=25,
        )
        print(f"Evolution API retornou HTTP {r.status_code}.")
        if r.ok:
            print("A API aceitou a solicitação. Confirme o recebimento no grupo do WhatsApp.")
            try:
                payload = r.json()
                # Evita despejar dados sensíveis/IDs no terminal.
                print("Resposta JSON recebida:", "válida" if isinstance(payload, (dict, list)) else "formato inesperado")
            except ValueError:
                print("A resposta não foi JSON; verifique a documentação da sua versão.")
        else:
            print("Resposta de erro (conteúdo limitado):", r.text[:500])
            print("Não tente outros endpoints sem confirmar a versão/documentação instalada.")
    except requests.RequestException as e:
        print(f"Falha ao acessar Evolution API: {e}")
    finally:
        apikey = None

    print("\nPróxima etapa: revisar auditoria_zabbix_pon.json para identificar as triggers corretas.")
    print("Este script NÃO criou a mídia, a ação nem ativou alertas no Zabbix.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
