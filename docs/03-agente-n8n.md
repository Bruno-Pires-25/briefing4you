# O agente financeiro no n8n

## Como ele foi desenhado

O agente **não tem opinião própria sobre os seus números** — ele consulta o
banco antes de responder. Duas ferramentas:

| Ferramenta | Função no Postgres | Para quê |
|---|---|---|
| `raio_x_financeiro` | `fn_raio_x_financeiro()` | Foto completa: renda, dívidas com taxa, 6 meses de fluxo, gastos por categoria, comparação avalanche × bola de neve |
| `simular_quitacao` | `fn_simular_quitacao(estrategia, aporte)` | Cronograma mês a mês para um cenário específico |

São as **mesmas funções que o painel chama**. Se o agente disser "você fica
livre em 22 meses", é exatamente o número que a tela de Dívidas mostra.

### O detalhe que importa em segurança

O painel envia o **JWT do usuário logado** no header `Authorization` do
webhook. O n8n repassa esse mesmo header nas chamadas ao Supabase. Resultado:
as funções rodam sob a RLS daquele usuário e enxergam só os dados dele.

A alternativa comum — dar a `service_role` key ao n8n — faria o agente
enxergar os dados de todos os usuários, e um erro de prompt bastaria para
vazar dados de um cliente para outro.

## Instalação

### 1. Importar o workflow

No n8n: **Workflows → Import from File** e escolha
`n8n/agente-financeiro.json`.

### 2. Substituir os placeholders

Nos nós `raio_x_financeiro` e `simular_quitacao`, troque:

- `https://SEU_PROJECT_REF.supabase.co` pela URL do seu projeto
- `SUA_PUBLISHABLE_KEY` no header `apikey` pela sua publishable key

### 3. Credencial do Claude

No nó **Claude**, crie a credencial *Anthropic API* com sua chave. O modelo
está em `claude-sonnet-4-5`, `temperature` 0.3 — baixa de propósito: conselho
financeiro precisa ser reprodutível, não criativo.

### 4. Memória da conversa

O nó **Memória da conversa** usa Postgres. Crie a credencial apontando para o
banco do próprio Supabase (**Settings → Database → Connection string**, modo
*Session*).

A tabela `n8n_chat_memoria` é criada automaticamente na primeira execução.

> Essa tabela fica fora do RLS do aplicativo — quem escreve nela é o n8n, com
> credencial de banco. A chave de sessão é o `user_id`, então cada usuário só
> recupera a própria conversa. Se você for expor isso a mais gente, vale
> habilitar RLS nela também.

### 5. Ativar e pegar a URL

Ative o workflow e copie a **Production URL** do nó *Receber pergunta*. Ela vai
no `.env`:

```
VITE_AGENTE_WEBHOOK_URL=https://SEU_N8N/webhook/agente-financeiro
```

### 6. Ajustar o CORS

No nó **Responder**, o header `Access-Control-Allow-Origin` está em
`http://localhost:8080`. Troque pela URL publicada do painel quando for para o
ar, ou liste as duas.

Não use `*`: qualquer site aberto no navegador do usuário conseguiria ler as
respostas do agente.

## Testando

```bash
curl -X POST https://SEU_N8N/webhook/agente-financeiro \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer SEU_JWT_DE_USUARIO" \
  -d '{"sessionId":"teste-1","mensagem":"Faça um raio-X da minha situação."}'
```

O JWT você pega no console do navegador com a sessão aberta:

```js
(await window.supabase.auth.getSession()).data.session.access_token
```

Se não tiver o cliente exposto em `window`, pegue de
`localStorage` — a chave começa com `sb-` e termina em `-auth-token`.

## Editando o prompt

A fonte da verdade é `n8n/prompts/system-prompt.md`. O que está depois da
linha `---` é o que vai no campo **System Message** do nó *AI Agent*.

Ao alterar o prompt, atualize os dois — o markdown e o campo no n8n — ou o
arquivo vira documentação mentirosa.

O que o prompt define, em resumo:

- Chamar `raio_x_financeiro` antes de qualquer resposta substantiva; nunca
  inventar número
- Converter taxa mensal em anual equivalente ao mostrar o tamanho do problema
  (13,5% a.m. = 358% a.a. costuma ser o que faz a ficha cair)
- Apresentar avalanche e bola de neve com os números reais e recomendar pelo
  perfil, não pela matemática pura
- Quando a simulação vier `viavel: false`, dizer com todas as letras que não há
  cronograma possível e mudar o foco para renegociação
- Roteiro de negociação com canais oficiais, e alerta sobre "despachante que
  limpa nome"
- Direitos relevantes (Lei 14.181/2021, prescrição de 5 anos, CDC art. 42),
  sempre com a ressalva de que não é consultoria jurídica
- Só propor corte em categoria `nao_essencial`; nunca em mercado, moradia,
  saúde, transporte ou educação
- Não julgar e não moralizar

## Ideias de extensão

**Alerta de vencimento** — Schedule Trigger diário que consulta `dividas` com
`dia_vencimento` nos próximos 3 dias e manda WhatsApp ou e-mail.

**Revisão semanal** — Schedule Trigger que chama `fn_raio_x_financeiro` e pede
ao agente um resumo do que mudou na semana.

**Categorização automática** — ao final de uma importação, um workflow que lê
as transações sem categoria e aplica as `regras_categorizacao`, deixando para
o agente só o que não casou com nenhuma regra.
