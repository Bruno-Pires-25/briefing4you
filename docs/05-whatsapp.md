# Assistente no WhatsApp (áudio + texto)

Manda áudio ou texto pelo WhatsApp, ele responde com base nos seus dados.

```
WhatsApp ──▶ Evolution API ──▶ n8n
                                │
                    ┌───────────┴───────────┐
                 áudio                    texto
                    │                       │
          baixa base64 da Evolution         │
                    │                       │
            Whisper (Groq) ─── transcreve ──┤
                                            ▼
                                   AI Agent (Claude Haiku 4.5)
                                            │
                              ┌─────────────┴─────────────┐
                        raio_x_por_canal        simular_por_canal
                                     │                │
                                     └──── Supabase ───┘
                                            │
                              Evolution API ──▶ WhatsApp
```

## Antes de tudo: por que existe uma lista de números

O painel autentica você e a RLS cuida do resto — cada consulta roda sob o seu
JWT. **O WhatsApp não tem nada disso.** Chega uma mensagem de um número, e só.

Se o fluxo consultasse o banco direto com a `service_role` key, qualquer pessoa
que descobrisse o número do bot receberia seu raio-X financeiro completo
mandando "quanto eu devo?".

Por isso a migration `20260817000500_canais_autorizados.sql` cria:

- **`canais_autorizados`** — a lista de números liberados, cada um amarrado a
  um `user_id`;
- **`fn_raio_x_por_canal`** e **`fn_simular_por_canal`** — as únicas funções
  que o n8n alcança. Elas **não aceitam `user_id` de quem chama**: resolvem o
  dono a partir do número, contra essa lista. Número fora da lista recebe erro
  `Número não autorizado`, não dado.

O motor interno (`fn_simular_para`, `fn_raio_x_para`), que aceita um `user_id`
qualquer, tem o `EXECUTE` revogado de `anon` e `authenticated`. Só os
invólucros chegam nele.

Testado com dois usuários num PostgreSQL real:

| Cenário | Resultado |
|---|---|
| `service_role` + número autorizado | devolve os dados do dono ✅ |
| `service_role` + número desconhecido | `Número não autorizado` ✅ |
| usuário logado chamando o motor com o uuid de outro | `permission denied` ✅ |
| usuário logado chamando o invólucro do WhatsApp | `permission denied` ✅ |
| número marcado como inativo | `Número não autorizado` ✅ |

### Cadastrar seu número

```sql
insert into public.canais_autorizados (user_id, canal, identificador, apelido)
values (
  'SEU_USER_ID',      -- select id from auth.users where email = 'seu@email';
  'whatsapp',
  '5511999998888',    -- E.164 SEM o '+', só dígitos
  'Meu celular'
);
```

Para revogar depois, `update ... set ativo = false` — o histórico fica.

## Áudio: por que tem um passo a mais

**Modelos Claude não recebem áudio.** Nenhum deles. O áudio precisa virar texto
antes de chegar no agente, e isso é um serviço separado.

O fluxo usa **Whisper large v3 turbo via Groq**, que é a opção mais barata e
rápida hoje. O `language` está fixo em `pt`: sem isso o Whisper às vezes
"traduz" áudio curto para inglês sozinho.

Para trocar por OpenAI, mude no nó *Transcrever (Whisper)*:
- URL → `https://api.openai.com/v1/audio/transcriptions`
- `model` → `gpt-4o-mini-transcribe` ou `whisper-1`
- header `Authorization` → sua chave OpenAI

## Instalar

### 1. Aplicar a migration

Se o banco já está de pé, rode só a migration nova
(`supabase/migrations/20260817000500_canais_autorizados.sql`) no SQL Editor.
Se está começando do zero, `supabase/schema-completo.sql` já a inclui.

### 2. Importar o fluxo

**Workflows → Import from File** → `n8n/agente-whatsapp.json`.

### 3. Substituir os placeholders

| Onde | Trocar |
|---|---|
| `raio_x` e `simular` | `SUA_SERVICE_ROLE_KEY` |
| `Baixar áudio`, `Responder no WhatsApp` | `https://SEU_EVOLUTION`, `SUA_INSTANCIA`, `SUA_APIKEY_EVOLUTION` |
| `Transcrever (Whisper)` | `SUA_GROQ_API_KEY` |

Sobre a `service_role` key aqui: ela é necessária porque não existe JWT de
usuário numa mensagem de WhatsApp. O risco é real — ela ignora RLS — e o que
o contém é a lista de números: mesmo com a chave, as funções que o n8n usa só
devolvem dados de número cadastrado. Ainda assim, trate o acesso ao seu n8n
como trate o acesso ao banco.

### 4. Credenciais

- **Claude Haiku** → credencial *Anthropic API*
- **Memória por número** → credencial *Postgres* apontando para o banco do
  Supabase (*Settings → Database → Connection string*, modo Session). A tabela
  `n8n_memoria_whatsapp` é criada sozinha.

### 5. Apontar a Evolution para o n8n

Ative o workflow, copie a **Production URL** do nó *Evolution Webhook*, e
cadastre na Evolution:

```bash
curl -X POST "https://SEU_EVOLUTION/webhook/set/SUA_INSTANCIA" \
  -H "apikey: SUA_APIKEY_EVOLUTION" \
  -H "Content-Type: application/json" \
  -d '{
    "webhook": {
      "enabled": true,
      "url": "https://SEU_N8N/webhook/whatsapp-financeiro",
      "byEvents": false,
      "events": ["MESSAGES_UPSERT"]
    }
  }'
```

Só `MESSAGES_UPSERT`. Assinar todos os eventos faz o n8n executar à toa em
atualização de presença, status de entrega e recibo de leitura.

## O que o fluxo ignora, e por quê

O nó *Normalizar* descarta antes de gastar qualquer token:

- **`fromMe: true`** — o eco da própria resposta do bot. Sem isso ele responde
  a si mesmo, em loop, para sempre. É o erro mais comum nesse tipo de fluxo.
- **`@g.us`** — grupos. Dado financeiro pessoal não vai para grupo.
- **`@broadcast`** — status.
- **imagem, documento, figurinha** — caem como `tipo: outro` e o filtro corta.

Validado contra nove formatos de payload da Evolution, incluindo número com
`+`, espaço e traço, e payload com e sem o envelope `data`.

## Economia de token

Você pediu para consumir pouco, então:

- **Claude Haiku 4.5** (`claude-haiku-4-5-20251001`) — o mais barato da
  família. Para ler um JSON e responder em cinco linhas, a diferença para o
  Sonnet não aparece na resposta, mas aparece na fatura.
- **`maxTokensToSample: 1024`** — resposta de WhatsApp não precisa de mais.
- **Memória de 6 trocas**, não 20 — o histórico é reenviado a cada mensagem,
  então é ele que infla a conta numa conversa longa.
- **O prompt manda chamar `raio_x` uma vez só** por conversa e reaproveitar. É
  a chamada mais cara do fluxo, porque o JSON de resposta é grande.
- **O system prompt é uma versão enxuta** do prompt do painel
  (`system-prompt-whatsapp.md`, ~2,6 mil caracteres contra ~6,4 mil). Ele é
  reenviado em toda mensagem — cada palavra ali é cobrada sempre.

## Se algo não funcionar

**Não responde nada** — veja se a execução aparece em *Executions* no n8n. Se
não aparece, o webhook da Evolution não está configurado ou o workflow está
inativo.

**`Número não autorizado`** — o número não está em `canais_autorizados`, ou
está com `ativo = false`, ou foi cadastrado com formato diferente. Confira:
`select identificador, ativo from public.canais_autorizados;` — tem que ser só
dígitos, com DDI.

**Áudio vira resposta sem sentido** — olhe a saída do nó *Transcrever*. Se a
transcrição em si veio errada, o problema é o Whisper, não o agente.

**Responde a si mesmo em loop** — o filtro de `fromMe` foi removido ou a
Evolution está mandando um payload diferente. Pare o workflow antes de
investigar.
