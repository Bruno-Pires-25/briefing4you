# Assistente pessoal no WhatsApp

Um assistente só, no seu número: dia a dia (tarefas, objetivos, memórias) e
finanças (o especialista em dívidas de sempre). Áudio e texto.

> **Ele substitui o fluxo só-financeiro no número.** A Evolution entrega o
> webhook de uma instância para UMA url — dois fluxos não podem escutar o
> mesmo número. Este contém as ferramentas financeiras, então nada se perde;
> o `agente-whatsapp.json` fica no repo como referência.

## "Treinar" o assistente: como funciona de verdade

Não há fine-tuning de modelo. O treinamento é o banco:

```
você conta algo ──▶ memoria() grava em assistente_memorias
                                      │
próxima conversa ──▶ contexto() devolve tudo ──▶ o assistente "lembra"
```

Cada fato durável que você mandar — "acordo às 5h", "recebo dia 5", "minha
esposa se chama X" — vira uma linha em `assistente_memorias` e volta como
contexto em **toda** conversa futura. Quanto mais você conta, mais ele acerta.
É acumulativo, permanente e seu: dá para ver e apagar tudo pelo banco (e por
uma tela do painel, quando você quiser que eu a construa).

A memória de conversa do n8n (janela de 6 trocas) continua existindo — ela dá
o fio da conversa atual; as memórias dão a biografia.

## As 8 ferramentas do agente

| Ferramenta | Função no banco | Quando o modelo usa |
|---|---|---|
| `contexto` | `fn_assistente_contexto_por_canal` | Uma vez por conversa: data de hoje, tarefas, objetivos, memórias, resumo de dívidas |
| `criar_tarefa` | `fn_tarefa_criar_por_canal` | "me lembra de…", "preciso fazer…" |
| `concluir_tarefa` | `fn_tarefa_concluir_por_canal` | "já fiz", "pode marcar" — busca por trecho do título; ambiguidade devolve candidatas em vez de chutar |
| `memoria` | `fn_memoria_salvar_por_canal` | Fato durável sobre você (com dedupe do texto idêntico) |
| `esquecer_memoria` | `fn_memoria_esquecer_por_canal` | "esquece isso" — desativa a memória (a remoção definitiva fica no painel) |
| `objetivo` | `fn_objetivo_registrar_por_canal` | Meta nova ou progresso; 100% marca como alcançado |
| `raio_x` | `fn_raio_x_por_canal` | Conversa de dinheiro de verdade |
| `simular` | `fn_simular_por_canal` | "e se eu pagar X a mais por mês" |

Todas seguem o modelo de segurança do canal (docs/05): resolvem o dono pelo
**número**, via a mesma lista `canais_autorizados`, e só a `service_role`
tem `EXECUTE`. Número fora da lista recebe erro, não dado.

Detalhe deliberado no `concluir_tarefa`: com duas tarefas parecidas
("Ligar para o banco", "Ligar para o dentista"), buscar "ligar" **não conclui
nenhuma** — devolve as duas para o assistente perguntar. Concluir a errada é
pior que perguntar.

## Datas relativas

O `contexto` traz `agora` (data, hora e dia da semana em
`America/Sao_Paulo`), e o prompt manda resolver "amanhã"/"sexta" a partir
dele. Sem isso o modelo chutaria o dia — o servidor do banco vive em UTC.

## Instalar

### 1. Banco

Seu projeto (`hxclrrcuqsduymgmbhph`) tem só as 4 migrations iniciais. Cole
**`supabase/aplicar-assistente.sql`** no SQL Editor e execute uma vez — é o
delta com as migrations 5 e 6 (canais + assistente), transacional, testado
contra um banco exatamente nesse estado.

Depois cadastre seu número (uma vez):

```sql
insert into public.canais_autorizados (user_id, canal, identificador, apelido)
values (
  (select id from auth.users where email = 'seu@email'),
  'whatsapp',
  '5583999998888',   -- só dígitos, com DDI
  'Meu celular'
);
```

### 2. n8n

```bash
cp .env.n8n.example .env.n8n    # preencha
npm run n8n:deploy n8n/agente-assistente-pessoal.json
```

(ou `-- --sem-credenciais` para subir e completar na interface; ou importar o
JSON manualmente). Depois, na interface: credencial Anthropic no nó *Claude
Haiku*, credencial Postgres no nó *Memória da conversa*, ativar.

### 3. Evolution

Aponte o webhook da instância para a Production URL do nó *Evolution
Webhook* — o path deste fluxo é **`assistente-pessoal`**:

```bash
curl -X POST "https://SUA_EVOLUTION/webhook/set/SUA_INSTANCIA" \
  -H "apikey: SUA_APIKEY" -H "Content-Type: application/json" \
  -d '{"webhook":{"enabled":true,"url":"https://SEU_N8N/webhook/assistente-pessoal","byEvents":false,"events":["MESSAGES_UPSERT"]}}'
```

### 4. Teste guiado

1. **"oi"** → ele chama `contexto` e se apresenta sabendo seu nome.
2. **"me lembra de pagar a fatura dia 25"** → cria tarefa com prazo.
3. **"anota que eu acordo às 5h"** → grava memória e confirma curto.
4. **"o que eu tenho pra fazer?"** → lista as pendentes.
5. **"já liguei pro dentista"** → conclui por busca.
6. **"quanto eu devo?"** → aí sim chama `raio_x`.
7. **"esquece aquilo do café"** → desativa a memória.
8. Mande um **áudio** com qualquer um dos acima.

## Custo

Mesma disciplina do fluxo financeiro: Haiku 4.5, resposta ≤1024 tokens,
memória de 6 trocas, `contexto` uma vez por conversa. O `contexto` é
propositalmente compacto (tarefas limitadas a 20, memórias a 40, finanças em
uma linha) — o raio-X completo só entra quando o assunto é dinheiro.

Quando as memórias acumularem centenas, o limite de 40 mais recentes segura o
custo; se um dia precisar de busca semântica nelas (pgvector), o caminho está
aberto — é outra coluna na mesma tabela, nada a refazer.

## O painel vê tudo

As tabelas novas (`tarefas`, `objetivos`, `assistente_memorias`) têm RLS por
dono e grants para `authenticated` — o painel pode ler e editar direto via
supabase-js, sem função intermediária. Telas de tarefas/objetivos/memórias no
painel são o próximo passo natural; peça quando quiser.
