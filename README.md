# FinBR

Painel financeiro pessoal com importação de extratos bancários e um agente de
IA especializado em sair de dívidas — construído para o contexto brasileiro
(rotativo, cheque especial, consignado, Serasa, superendividamento).

```
Navegador (React)                n8n                     Supabase
┌───────────────┐   webhook   ┌──────────┐   RPC c/ JWT  ┌──────────────┐
│ Painel        │────────────▶│ AI Agent │──────────────▶│ Postgres     │
│ Importar OFX  │             │ + Claude │               │ + RLS        │
│ Chat          │◀────────────│ + memória│◀──────────────│ + fn_*()     │
└───────┬───────┘             └──────────┘               └──────▲───────┘
        │                                                       │
        └───────────────── supabase-js (JWT do usuário) ────────┘
```

O ponto de arquitetura que sustenta tudo: **a lógica financeira vive no banco**,
em `fn_simular_quitacao` e `fn_raio_x_financeiro`. Painel e agente chamam as
mesmas funções, então é impossível a tela mostrar um plano e o agente descrever
outro.

## Estado atual

| Peça | Situação |
|---|---|
| Schema, RLS, simulador (SQL) | Pronto e testado num Postgres 16 real |
| Parsers de OFX e CSV | Prontos, 29 testes passando |
| Painel React (5 telas) | Pronto, build limpo |
| Workflow do n8n + system prompt | Pronto para importar |
| Projeto Supabase | `hxclrrcuqsduymgmbhph`, **schema ainda não aplicado** |
| Projeto Lovable | Não criado — você conecta via GitHub |

### Aplicar o schema

Cole [`supabase/schema-completo.sql`](supabase/schema-completo.sql) no SQL
Editor do Supabase e execute uma vez. É o arquivo gerado a partir das 4
migrations, na ordem certa, envolvido numa transação — se algo falhar, nada
é aplicado pela metade.

O passo a passo, com as consultas para conferir se deu certo, está em
[`docs/02-supabase.md`](docs/02-supabase.md).

Esse bundle foi testado num PostgreSQL limpo: aplica de uma vez sem erro e
produz exatamente o mesmo resultado de aplicar as migrations uma a uma —
12 tabelas com RLS, 46 policies, 31 categorias, 3 views e as 2 funções do
agente respondendo.

## Rodando local

```bash
npm install
cp .env.example .env    # preencha com os dados do seu projeto Supabase
npm run dev             # http://localhost:8080
```

Outros comandos:

```bash
npm test        # testes dos parsers de extrato
npm run build   # build de produção
npm run lint
```

## Como o dinheiro entra no sistema

Hoje: **upload de OFX ou CSV** na tela *Importar*. O arquivo é lido no
navegador — só os lançamentos vão para o banco.

O OFX é o formato preferido porque traz o `FITID`, um identificador único por
transação definido pelo banco. O par `(conta_id, fitid)` tem índice único no
banco, então reimportar o mesmo extrato é seguro: o que já existe é ignorado em
vez de duplicar.

CSV não tem esse identificador. O parser calcula uma impressão digital
(`hash_dedupe`) e a tela avisa que reimportar pode duplicar, mas não bloqueia —
duas compras iguais no mesmo dia são legítimas e não podem ser descartadas
automaticamente.

Quando quiser puxar extrato por API (Pluggy/Open Finance), o caminho está
descrito em [`docs/04-extratos.md`](docs/04-extratos.md). Nada do que existe
hoje precisa ser refeito: basta gravar em `transacoes` com `origem = 'api'`.

## Documentação

- [`docs/01-lovable-github.md`](docs/01-lovable-github.md) — conectar Lovable ao
  repositório e trabalhar local sem os dois brigarem
- [`docs/02-supabase.md`](docs/02-supabase.md) — criar o projeto e aplicar as
  migrations
- [`docs/03-agente-n8n.md`](docs/03-agente-n8n.md) — importar e configurar o
  agente
- [`docs/04-extratos.md`](docs/04-extratos.md) — formatos, dedupe e o caminho
  para a automação via API

## Estrutura

```
src/
  lib/parsers/     Leitura de OFX e CSV, normalização e dedupe (com testes)
  hooks/           Autenticação e queries (React Query)
  pages/           Painel, Dívidas, Transações, Importar, Agente
  types/db.ts      Tipos espelhando as migrations
supabase/
  migrations/      Schema, RLS, categorias padrão, views e simulador
n8n/
  agente-financeiro.json   Workflow para importar no n8n
  prompts/system-prompt.md Fonte da verdade do system prompt
```

## Segurança

- Toda tabela tem RLS por dono (`auth.uid() = user_id`), validada com testes de
  isolamento entre dois usuários: leitura filtrada, `INSERT` no nome de outro
  bloqueado, `UPDATE` em linha alheia afeta zero linhas.
- A chave `publishable` do Supabase vai no bundle do navegador — isso é normal.
  Quem impede um usuário de ler os dados de outro é a RLS, nunca o sigilo dessa
  chave.
- O agente do n8n recebe o **JWT do usuário** e o repassa ao Supabase. Ele
  nunca usa a `service_role` key, que enxergaria todos os usuários.
