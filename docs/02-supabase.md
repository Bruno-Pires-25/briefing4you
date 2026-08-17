# Supabase — aplicar o schema

## 0. O projeto

| | |
|---|---|
| Ref | `hxclrrcuqsduymgmbhph` |
| URL | `https://hxclrrcuqsduymgmbhph.supabase.co` |
| Região pretendida | `sa-east-1` (São Paulo) |

Confirme a região em **Settings → General** antes de carregar dados: ela não
pode ser alterada depois, e trocar exige criar outro projeto e migrar. Com o
banco ainda vazio isso custa cinco minutos; com meses de extrato importado,
bem mais.

## 1. Aplicar o schema

O jeito mais direto: cole **`supabase/schema-completo.sql`** inteiro no
**SQL Editor** e execute uma vez.

Esse arquivo é gerado a partir das migrations (`npm run db:bundle`), já na
ordem correta e envolvido em `begin/commit` — se qualquer statement falhar,
nada é aplicado pela metade e você não fica com um schema quebrado.

Rodar duas vezes falha no primeiro `create table`, o que é o comportamento
desejado: avisa que o schema já existe em vez de duplicar dado em silêncio.

### Alternativa: migration por migration

As migrations vivem em `supabase/migrations/` e aplicam **na ordem alfabética
do nome do arquivo**:

| Arquivo | O que faz |
|---|---|
| `20260808000100_schema_financeiro.sql` | Tabelas, tipos, índices e triggers |
| `20260808000200_rls.sql` | Row Level Security e grants |
| `20260808000300_categorias_padrao.sql` | 31 categorias de sistema |
| `20260808000400_views_e_simulador.sql` | Views, `fn_simular_quitacao`, `fn_raio_x_financeiro` |

### Alternativa: CLI (melhor se for versionar mudanças futuras)

```bash
npx supabase link --project-ref hxclrrcuqsduymgmbhph
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

Cole isto no SQL Editor. Os números esperados são os que o schema produziu
num PostgreSQL limpo — se algum divergir, a aplicação foi parcial.

```sql
-- 12 tabelas, todas com rowsecurity = true.
select count(*) filter (where rowsecurity) as com_rls, count(*) as total
from pg_tables where schemaname = 'public';

-- 46 policies (10 tabelas x 4, mais 2 de perfis e 4 de categorias).
select count(*) from pg_policies where schemaname = 'public';

-- 31 categorias de sistema.
select count(*) from public.categorias where user_id is null;

-- 3 views, todas com security_invoker ligado. Se vier 'f' em alguma, ela
-- estaria vazando dados de todos os usuários — pare e reaplique.
select c.relname, c.reloptions::text like '%security_invoker=true%' as invoker
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'v' order by c.relname;

-- As 2 funções do agente.
select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and proname in ('fn_simular_quitacao', 'fn_raio_x_financeiro');
```

O simulador só devolve resultado para um usuário autenticado, então teste
pela aplicação depois de criar sua conta e cadastrar uma dívida — o SQL
Editor roda como superusuário e `auth.uid()` volta nulo ali.

## 6. Gerar os tipos TypeScript

Os tipos em `src/types/db.ts` foram escritos à mão para o projeto compilar
antes de o banco existir. Com o projeto criado, gere os oficiais:

```bash
npx supabase gen types typescript --project-id hxclrrcuqsduymgmbhph > src/types/supabase.ts
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
