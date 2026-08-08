-- FinBR — Row Level Security.
-- Regra geral: cada usuário enxerga e escreve apenas as próprias linhas.
-- Exceção: categorias de sistema (user_id is null) são legíveis por todos,
-- mas ninguém as altera pelo cliente.

alter table public.perfis               enable row level security;
alter table public.contas               enable row level security;
alter table public.categorias           enable row level security;
alter table public.importacoes          enable row level security;
alter table public.transacoes           enable row level security;
alter table public.regras_categorizacao enable row level security;
alter table public.dividas              enable row level security;
alter table public.divida_eventos       enable row level security;
alter table public.planos_quitacao      enable row level security;
alter table public.orcamentos           enable row level security;
alter table public.agente_conversas     enable row level security;
alter table public.agente_mensagens     enable row level security;

-- ---------------------------------------------------------------------------
-- Perfis (a linha É o usuário, então a chave é o id)
-- ---------------------------------------------------------------------------

create policy "perfis_select_proprio" on public.perfis
  for select to authenticated using ((select auth.uid()) = id);

create policy "perfis_update_proprio" on public.perfis
  for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- INSERT fica por conta do trigger on_auth_user_created (security definer).

-- ---------------------------------------------------------------------------
-- Tabelas com user_id: política uniforme
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array[
    'contas',
    'importacoes',
    'transacoes',
    'regras_categorizacao',
    'dividas',
    'divida_eventos',
    'planos_quitacao',
    'orcamentos',
    'agente_conversas',
    'agente_mensagens'
  ]
  loop
    -- `(select auth.uid())` em vez de `auth.uid()` puro: o planner avalia uma
    -- única vez por query em vez de uma vez por linha. Faz diferença real em
    -- extratos com milhares de transações.
    execute format($f$
      create policy %1$I on public.%2$I
        for select to authenticated
        using ((select auth.uid()) = user_id);
    $f$, t || '_select_proprio', t);

    execute format($f$
      create policy %1$I on public.%2$I
        for insert to authenticated
        with check ((select auth.uid()) = user_id);
    $f$, t || '_insert_proprio', t);

    execute format($f$
      create policy %1$I on public.%2$I
        for update to authenticated
        using ((select auth.uid()) = user_id)
        with check ((select auth.uid()) = user_id);
    $f$, t || '_update_proprio', t);

    execute format($f$
      create policy %1$I on public.%2$I
        for delete to authenticated
        using ((select auth.uid()) = user_id);
    $f$, t || '_delete_proprio', t);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Categorias (sistema + próprias)
-- ---------------------------------------------------------------------------

create policy "categorias_select_sistema_ou_proprias" on public.categorias
  for select to authenticated
  using (user_id is null or (select auth.uid()) = user_id);

create policy "categorias_insert_proprias" on public.categorias
  for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy "categorias_update_proprias" on public.categorias
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "categorias_delete_proprias" on public.categorias
  for delete to authenticated
  using ((select auth.uid()) = user_id);

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
-- O Supabase já concede isso por default privileges, mas declarar explícito
-- mantém o schema reproduzível em qualquer Postgres (CI, cópia local).
-- Sem RLS habilitada acima, estes grants seriam acesso irrestrito — as duas
-- coisas andam juntas.

grant usage on schema public to authenticated;

grant select, insert, update, delete on
  public.contas,
  public.importacoes,
  public.transacoes,
  public.regras_categorizacao,
  public.dividas,
  public.divida_eventos,
  public.planos_quitacao,
  public.orcamentos,
  public.agente_conversas,
  public.agente_mensagens,
  public.categorias
to authenticated;

grant select, update on public.perfis to authenticated;
