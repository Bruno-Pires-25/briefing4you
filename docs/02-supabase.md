# Supabase — aplicar o schema

## 0. O projeto

| | |
|---|---|
| Nome | Pessoal |
| Ref | `yvtnvccpewyyllpsfwto` |
| URL | `https://yvtnvccpewyyllpsfwto.supabase.co` |
| Organização | BRP Solutions |
| Região | `us-west-2` (Oregon) |
| Postgres | 17.6 |
| Estado | `ACTIVE_HEALTHY`, schema `public` vazio |

### Antes de aplicar: a região

O projeto está em **Oregon**, não em São Paulo. Para quem acessa do Brasil,
isso adiciona cerca de 150–180 ms a cada ida e volta ao banco. Num painel
pessoal dá para conviver, mas telas que disparam várias queries seguidas
ficam visivelmente mais lentas do que ficariam em `sa-east-1`.

A região de um projeto Supabase **não pode ser alterada**. Trocar significa
criar um projeto novo em `sa-east-1` e migrar. Com o banco vazio, isso é
recriar e rodar as migrations de novo — cinco minutos. Depois de meses de
extrato importado, é um projeto de migração.

Se for trocar, é agora. Se ficar em Oregon, siga em frente — nada no schema
depende da região.

## 2. Aplicar as migrations

As migrations estão em `supabase/migrations/` e aplicam **na ordem alfabética
do nome do arquivo**:

| Arquivo | O que faz |
|---|---|
| `20260808000100_schema_financeiro.sql` | Tabelas, tipos, índices e triggers |
| `20260808000200_rls.sql` | Row Level Security e grants |
| `20260808000300_categorias_padrao.sql` | 31 categorias de sistema |
| `20260808000400_views_e_simulador.sql` | Views, `fn_simular_quitacao`, `fn_raio_x_financeiro` |

### Pelo SQL Editor (mais simples)

Abra o **SQL Editor** no painel do Supabase e cole o conteúdo de cada arquivo,
nessa ordem, executando um por vez.

### Pela CLI (recomendado se for versionar mudanças futuras)

```bash
npx supabase link --project-ref yvtnvccpewyyllpsfwto
npx supabase db push
```

## 3. Pegar as chaves

**Settings → API**:

- `Project URL` → `VITE_SUPABASE_URL`
- `Publishable key` (`sb_publishable_...`) → `VITE_SUPABASE_PUBLISHABLE_KEY`

A `service_role` key **não** entra no frontend nem no n8n. Ela ignora RLS e
enxergaria os dados de todos os usuários.

## 4. Configurar autenticação

Em **Authentication → Providers**, o provedor *Email* já vem ligado.

Para desenvolvimento, desligue *Confirm email* (**Authentication → Sign In /
Providers**) para não precisar validar e-mail a cada teste. Religue antes de
colocar no ar.

Em **Authentication → URL Configuration**, adicione as URLs de redirect:
`http://localhost:8080` e, depois, o domínio publicado pelo Lovable.

## 5. Conferir se ficou de pé

No SQL Editor:

```sql
-- Deve listar 12 tabelas, todas com rowsecurity = true.
select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
order by tablename;

-- Deve devolver 31.
select count(*) from public.categorias where user_id is null;

-- As duas funções do agente.
select proname from pg_proc
where proname in ('fn_simular_quitacao', 'fn_raio_x_financeiro');
```

Depois de criar sua conta pelo painel e cadastrar uma dívida, teste o
simulador logado (o SQL Editor roda como superusuário e ignora RLS, então
prefira testar pela aplicação):

```sql
select jsonb_pretty(public.fn_simular_quitacao('avalanche', 500));
```

## 6. Gerar os tipos TypeScript

Os tipos em `src/types/db.ts` foram escritos à mão para o projeto compilar
antes de o banco existir. Com o projeto criado, gere os oficiais:

```bash
npx supabase gen types typescript --project-id SEU_PROJECT_REF > src/types/supabase.ts
```

## Notas sobre o schema

**Dinheiro é `numeric(14,2)`**, nunca `float`. Ponto flutuante acumula erro de
arredondamento a cada operação, e num simulador que itera 360 meses isso vira
diferença visível em reais.

**Taxa de juros é mensal e decimal**: `0.135` = 13,5% a.m. É a convenção do
mercado brasileiro (fatura de cartão anuncia a taxa mensal) e evita
ambiguidade nas contas.

**O sinal do valor da transação é a fonte da verdade**: positivo entra,
negativo sai. A coluna `tipo` é gerada (`generated always as ... stored`) a
partir do sinal, então nunca diverge.

**As views usam `security_invoker = true`**. Sem isso elas rodariam com os
privilégios do dono e vazariam os dados de todos os usuários, mesmo com RLS
ligada nas tabelas.
