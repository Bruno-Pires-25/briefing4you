-- FinBR — schema completo.
--
-- ARQUIVO GERADO. Não edite aqui: mexa em supabase/migrations/ e rode
--   npm run db:bundle
--
-- Origem: 6 migrations, nesta ordem:
--   20260808000100_schema_financeiro.sql
--   20260808000200_rls.sql
--   20260808000300_categorias_padrao.sql
--   20260808000400_views_e_simulador.sql
--   20260817000500_canais_autorizados.sql
--   20260817000600_assistente_pessoal.sql
--
-- Como usar: cole tudo no SQL Editor do Supabase e execute uma vez, num
-- projeto com o schema public vazio. Rodar duas vezes falha no segundo
-- CREATE TABLE — o que é o comportamento desejado, porque avisa que o
-- schema já existe em vez de duplicar dado silenciosamente.

begin;
-- ==========================================================================
-- 20260808000100_schema_financeiro.sql
-- ==========================================================================

-- FinBR — schema financeiro base.
-- Convenções:
--   * dinheiro em numeric(14,2), sempre em BRL;
--   * taxas de juros em numeric(9,6) e ao MÊS (0.135 = 13,5% a.m.);
--   * toda tabela de domínio carrega user_id para RLS por dono.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Perfil
-- ---------------------------------------------------------------------------

create table public.perfis (
  id                    uuid primary key references auth.users (id) on delete cascade,
  nome                  text,
  renda_mensal          numeric(14, 2) not null default 0,
  -- Quanto o usuário consegue destinar por mês, além das parcelas mínimas,
  -- para acelerar a quitação. Alimenta o simulador.
  aporte_extra_mensal   numeric(14, 2) not null default 0,
  reserva_meta_meses    smallint not null default 3,
  criado_em             timestamptz not null default now(),
  atualizado_em         timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Contas
-- ---------------------------------------------------------------------------

create type public.tipo_conta as enum (
  'corrente',
  'poupanca',
  'cartao_credito',
  'investimento',
  'carteira'
);

create table public.contas (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  apelido       text not null,
  instituicao   text,
  tipo          public.tipo_conta not null default 'corrente',
  -- Código do banco na Febraban (001, 237, 260...), quando conhecido.
  banco_codigo  text,
  saldo_atual   numeric(14, 2) not null default 0,
  ativa         boolean not null default true,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create index contas_user_idx on public.contas (user_id) where ativa;

-- ---------------------------------------------------------------------------
-- Categorias
-- ---------------------------------------------------------------------------

-- 'essencial' vs 'nao_essencial' é o corte que o agente usa para propor cortes
-- de gasto sem sugerir que o usuário pare de comer ou pagar aluguel.
create type public.grupo_categoria as enum (
  'receita',
  'essencial',
  'nao_essencial',
  'divida',
  'investimento',
  'transferencia'
);

create table public.categorias (
  id         uuid primary key default gen_random_uuid(),
  -- NULL = categoria de sistema, visível para todos os usuários.
  user_id    uuid references auth.users (id) on delete cascade,
  nome       text not null,
  grupo      public.grupo_categoria not null,
  cor        text,
  icone      text,
  criado_em  timestamptz not null default now()
);

create unique index categorias_sistema_nome_idx
  on public.categorias (nome)
  where user_id is null;

create unique index categorias_user_nome_idx
  on public.categorias (user_id, nome)
  where user_id is not null;

-- ---------------------------------------------------------------------------
-- Importações de extrato
-- ---------------------------------------------------------------------------

create type public.formato_importacao as enum ('ofx', 'csv', 'manual', 'api');

create type public.status_importacao as enum (
  'processando',
  'concluida',
  'concluida_com_avisos',
  'erro'
);

create table public.importacoes (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users (id) on delete cascade,
  conta_id            uuid references public.contas (id) on delete set null,
  arquivo_nome        text,
  formato             public.formato_importacao not null,
  status              public.status_importacao not null default 'processando',
  periodo_inicio      date,
  periodo_fim         date,
  linhas_lidas        integer not null default 0,
  linhas_importadas   integer not null default 0,
  linhas_duplicadas   integer not null default 0,
  linhas_com_erro     integer not null default 0,
  erro_mensagem       text,
  criado_em           timestamptz not null default now()
);

create index importacoes_user_idx on public.importacoes (user_id, criado_em desc);

-- ---------------------------------------------------------------------------
-- Transações
-- ---------------------------------------------------------------------------

-- Sinal do valor é a fonte da verdade: positivo entra, negativo sai.
-- 'tipo' é derivado e existe só para indexar/filtrar barato.
create type public.tipo_transacao as enum ('credito', 'debito');

create table public.transacoes (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users (id) on delete cascade,
  conta_id              uuid not null references public.contas (id) on delete cascade,
  categoria_id          uuid references public.categorias (id) on delete set null,
  importacao_id         uuid references public.importacoes (id) on delete set null,
  -- Quando a transação é o pagamento de uma dívida cadastrada.
  divida_id             uuid,

  data                  date not null,
  descricao             text not null,
  -- Descrição sem acento, caixa baixa e sem ruído (NSU, docs, datas).
  -- É contra ela que as regras de categorização casam.
  descricao_normalizada text not null default '',
  valor                 numeric(14, 2) not null,
  tipo                  public.tipo_transacao not null
                          generated always as (
                            case when valor >= 0 then 'credito'::public.tipo_transacao
                                 else 'debito'::public.tipo_transacao end
                          ) stored,

  origem                public.formato_importacao not null default 'manual',
  -- FITID do OFX: identificador único da transação dentro da conta, definido
  -- pelo banco. É o que permite reimportar o mesmo extrato sem duplicar.
  fitid                 text,
  -- Impressão digital para arquivos sem FITID (CSV). Não é única de propósito:
  -- duas compras iguais no mesmo dia são legítimas. Serve para SINALIZAR
  -- possível duplicata na tela de revisão, não para bloquear.
  hash_dedupe           text,
  conciliada            boolean not null default false,
  observacao            text,
  metadata              jsonb not null default '{}'::jsonb,

  criado_em             timestamptz not null default now(),
  atualizado_em         timestamptz not null default now(),

  constraint transacoes_valor_nao_zero check (valor <> 0)
);

-- Dedupe forte: o par (conta, FITID) é único por definição do padrão OFX.
create unique index transacoes_conta_fitid_idx
  on public.transacoes (conta_id, fitid)
  where fitid is not null;

create index transacoes_user_data_idx on public.transacoes (user_id, data desc);
create index transacoes_conta_data_idx on public.transacoes (conta_id, data desc);
create index transacoes_categoria_idx on public.transacoes (categoria_id);
create index transacoes_hash_idx on public.transacoes (conta_id, hash_dedupe)
  where hash_dedupe is not null;

-- ---------------------------------------------------------------------------
-- Regras de categorização automática
-- ---------------------------------------------------------------------------

create table public.regras_categorizacao (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  categoria_id  uuid not null references public.categorias (id) on delete cascade,
  -- Substring casada contra descricao_normalizada (já normalizada também).
  padrao        text not null,
  -- Maior prioridade vence quando mais de uma regra casa.
  prioridade    smallint not null default 0,
  ativa         boolean not null default true,
  criado_em     timestamptz not null default now()
);

create index regras_user_idx
  on public.regras_categorizacao (user_id, prioridade desc)
  where ativa;

-- ---------------------------------------------------------------------------
-- Dívidas
-- ---------------------------------------------------------------------------

create type public.tipo_divida as enum (
  'cartao_credito',
  'cheque_especial',
  'emprestimo_pessoal',
  'consignado',
  'financiamento_veiculo',
  'financiamento_imovel',
  'credito_rotativo',
  'parcelamento_fatura',
  'conta_atrasada',
  'agiota_informal',
  'outro'
);

create type public.status_divida as enum (
  'ativa',
  'em_atraso',
  'em_negociacao',
  'acordo_firmado',
  'quitada',
  'judicial'
);

create table public.dividas (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users (id) on delete cascade,

  credor                text not null,
  tipo                  public.tipo_divida not null,
  status                public.status_divida not null default 'ativa',

  -- Saldo devedor ATUAL (o que quitaria hoje), não o valor original.
  saldo_devedor         numeric(14, 2) not null,
  valor_original        numeric(14, 2),
  -- Juros ao mês em decimal: 0.135 = 13,5% a.m. É a variável que decide a
  -- ordem na estratégia avalanche.
  taxa_juros_mensal     numeric(9, 6) not null default 0,
  -- Pagamento mínimo mensal exigido pelo credor.
  parcela_minima        numeric(14, 2) not null default 0,
  parcelas_total        smallint,
  parcelas_pagas        smallint not null default 0,
  dia_vencimento        smallint check (dia_vencimento between 1 and 31),
  dias_em_atraso        integer not null default 0,
  -- Dívida de cartão/rotativo costuma aceitar acordo com desconto pesado.
  -- O agente prioriza abrir negociação nessas.
  aceita_negociacao     boolean not null default true,
  em_orgao_protecao     boolean not null default false,
  -- Ordem manual de ataque, usada só pela estratégia 'personalizada'.
  -- Menor número = quitar primeiro.
  ordem_prioridade      smallint,
  observacoes           text,

  criado_em             timestamptz not null default now(),
  atualizado_em         timestamptz not null default now(),

  constraint dividas_saldo_nao_negativo check (saldo_devedor >= 0),
  constraint dividas_parcelas_coerentes
    check (parcelas_total is null or parcelas_pagas <= parcelas_total)
);

create index dividas_user_idx on public.dividas (user_id, status);

alter table public.transacoes
  add constraint transacoes_divida_fk
  foreign key (divida_id) references public.dividas (id) on delete set null;

create index transacoes_divida_idx on public.transacoes (divida_id)
  where divida_id is not null;

-- ---------------------------------------------------------------------------
-- Eventos de dívida (linha do tempo auditável)
-- ---------------------------------------------------------------------------

create type public.tipo_evento_divida as enum (
  'pagamento',
  'juros_aplicado',
  'multa',
  'proposta_recebida',
  'proposta_enviada',
  'acordo_firmado',
  'acordo_quebrado',
  'quitacao',
  'ajuste_saldo',
  'nota'
);

create table public.divida_eventos (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  divida_id    uuid not null references public.dividas (id) on delete cascade,
  tipo         public.tipo_evento_divida not null,
  data         date not null default current_date,
  valor        numeric(14, 2),
  -- Para propostas: saldo_devedor no momento vs valor proposto = desconto.
  saldo_apos   numeric(14, 2),
  descricao    text,
  metadata     jsonb not null default '{}'::jsonb,
  criado_em    timestamptz not null default now()
);

create index divida_eventos_divida_idx
  on public.divida_eventos (divida_id, data desc);

-- ---------------------------------------------------------------------------
-- Planos de quitação (simulações congeladas)
-- ---------------------------------------------------------------------------

create type public.estrategia_quitacao as enum (
  -- Maior taxa de juros primeiro. Ótimo matematicamente: paga menos juros.
  'avalanche',
  -- Menor saldo primeiro. Ótimo psicologicamente: entrega vitórias rápidas.
  'bola_de_neve',
  -- Ordem definida à mão pelo usuário.
  'personalizada'
);

create table public.planos_quitacao (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users (id) on delete cascade,
  nome                text not null,
  estrategia          public.estrategia_quitacao not null,
  aporte_extra_mensal numeric(14, 2) not null default 0,
  ativo               boolean not null default false,
  -- Snapshot completo da simulação no momento em que o plano foi salvo:
  -- cronograma mês a mês, juros totais, data de liberdade. Congelado de
  -- propósito, para comparar o planejado com o realizado depois.
  resultado           jsonb not null default '{}'::jsonb,
  criado_em           timestamptz not null default now()
);

create unique index planos_um_ativo_por_user_idx
  on public.planos_quitacao (user_id)
  where ativo;

-- ---------------------------------------------------------------------------
-- Orçamento por categoria
-- ---------------------------------------------------------------------------

create table public.orcamentos (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  categoria_id uuid not null references public.categorias (id) on delete cascade,
  -- Sempre o dia 1 do mês de referência.
  mes          date not null,
  limite       numeric(14, 2) not null,
  criado_em    timestamptz not null default now(),

  constraint orcamentos_mes_dia_um check (extract(day from mes) = 1)
);

create unique index orcamentos_unico_idx
  on public.orcamentos (user_id, categoria_id, mes);

-- ---------------------------------------------------------------------------
-- Conversas com o agente
-- ---------------------------------------------------------------------------

create table public.agente_conversas (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  titulo        text,
  -- Chave de memória usada pelo n8n (Postgres Chat Memory).
  session_id    text not null,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create unique index agente_conversas_session_idx
  on public.agente_conversas (session_id);

create type public.papel_mensagem as enum ('user', 'assistant', 'system', 'tool');

create table public.agente_mensagens (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  conversa_id uuid not null references public.agente_conversas (id) on delete cascade,
  papel       public.papel_mensagem not null,
  conteudo    text not null,
  metadata    jsonb not null default '{}'::jsonb,
  criado_em   timestamptz not null default now()
);

create index agente_mensagens_conversa_idx
  on public.agente_mensagens (conversa_id, criado_em);

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

create or replace function public.tg_set_atualizado_em()
returns trigger
language plpgsql
as $$
begin
  new.atualizado_em := now();
  return new;
end;
$$;

create trigger perfis_atualizado_em
  before update on public.perfis
  for each row execute function public.tg_set_atualizado_em();

create trigger contas_atualizado_em
  before update on public.contas
  for each row execute function public.tg_set_atualizado_em();

create trigger transacoes_atualizado_em
  before update on public.transacoes
  for each row execute function public.tg_set_atualizado_em();

create trigger dividas_atualizado_em
  before update on public.dividas
  for each row execute function public.tg_set_atualizado_em();

create trigger agente_conversas_atualizado_em
  before update on public.agente_conversas
  for each row execute function public.tg_set_atualizado_em();

-- Cria o perfil automaticamente quando um usuário se cadastra.
create or replace function public.tg_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.perfis (id, nome)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'nome', new.email))
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.tg_handle_new_user();

-- Marca a dívida como quitada assim que o saldo zera, e registra o evento.
create or replace function public.tg_divida_quitada()
returns trigger
language plpgsql
as $$
begin
  if new.saldo_devedor = 0 and old.saldo_devedor > 0 then
    new.status := 'quitada';

    insert into public.divida_eventos (user_id, divida_id, tipo, valor, saldo_apos, descricao)
    values (new.user_id, new.id, 'quitacao', old.saldo_devedor, 0, 'Saldo devedor zerado');
  end if;

  return new;
end;
$$;

create trigger dividas_quitacao
  before update of saldo_devedor on public.dividas
  for each row execute function public.tg_divida_quitada();

-- ==========================================================================
-- 20260808000200_rls.sql
-- ==========================================================================

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

-- ==========================================================================
-- 20260808000300_categorias_padrao.sql
-- ==========================================================================

-- FinBR — categorias de sistema (user_id null, visíveis a todos).
-- O grupo importa mais que o nome: é ele que separa o que o agente pode
-- sugerir cortar ('nao_essencial') do que ele não deve tocar ('essencial').

insert into public.categorias (user_id, nome, grupo, cor, icone) values
  (null, 'Salário',                'receita',       '#16a34a', 'wallet'),
  (null, 'Renda extra',            'receita',       '#22c55e', 'plus-circle'),
  (null, 'Rendimentos',            'receita',       '#4ade80', 'trending-up'),
  (null, 'Reembolso',              'receita',       '#86efac', 'undo-2'),

  (null, 'Moradia',                'essencial',     '#0ea5e9', 'home'),
  (null, 'Energia',                'essencial',     '#0284c7', 'zap'),
  (null, 'Água',                   'essencial',     '#38bdf8', 'droplet'),
  (null, 'Internet e telefone',    'essencial',     '#0369a1', 'wifi'),
  (null, 'Mercado',                'essencial',     '#14b8a6', 'shopping-cart'),
  (null, 'Transporte',             'essencial',     '#06b6d4', 'bus'),
  (null, 'Combustível',            'essencial',     '#0891b2', 'fuel'),
  (null, 'Saúde',                  'essencial',     '#ef4444', 'heart-pulse'),
  (null, 'Farmácia',               'essencial',     '#f87171', 'pill'),
  (null, 'Educação',               'essencial',     '#6366f1', 'graduation-cap'),
  (null, 'Impostos e taxas',       'essencial',     '#64748b', 'landmark'),
  (null, 'Seguros',                'essencial',     '#475569', 'shield'),

  (null, 'Restaurantes',           'nao_essencial', '#f59e0b', 'utensils'),
  (null, 'Delivery',               'nao_essencial', '#fb923c', 'bike'),
  (null, 'Compras',                'nao_essencial', '#ec4899', 'shopping-bag'),
  (null, 'Lazer',                  'nao_essencial', '#a855f7', 'party-popper'),
  (null, 'Assinaturas',            'nao_essencial', '#8b5cf6', 'repeat'),
  (null, 'Viagem',                 'nao_essencial', '#d946ef', 'plane'),
  (null, 'Beleza',                 'nao_essencial', '#f472b6', 'scissors'),
  (null, 'Jogos e apostas',        'nao_essencial', '#dc2626', 'dice-5'),

  (null, 'Pagamento de dívida',    'divida',        '#b91c1c', 'banknote'),
  (null, 'Juros e encargos',       'divida',        '#991b1b', 'trending-down'),
  (null, 'Fatura de cartão',       'divida',        '#7f1d1d', 'credit-card'),

  (null, 'Investimento',           'investimento',  '#059669', 'piggy-bank'),
  (null, 'Reserva de emergência',  'investimento',  '#047857', 'shield-check'),

  (null, 'Transferência interna',  'transferencia', '#94a3b8', 'arrow-left-right'),
  (null, 'Não categorizado',       'nao_essencial', '#cbd5e1', 'circle-help')
on conflict do nothing;

-- ==========================================================================
-- 20260808000400_views_e_simulador.sql
-- ==========================================================================

-- FinBR — views de leitura e o motor de simulação de quitação.
--
-- O simulador vive aqui, em plpgsql, e não no frontend, de propósito: o painel
-- e o agente do n8n chamam a MESMA função. Se a lógica morasse em TypeScript,
-- o agente precisaria de uma segunda implementação e as duas divergiriam.

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

-- security_invoker: a view respeita a RLS de quem consulta, em vez de rodar
-- com os privilégios do dono. Sem isso, qualquer usuário leria tudo.
create view public.v_resumo_mensal
with (security_invoker = true)
as
select
  t.user_id,
  date_trunc('month', t.data)::date                             as mes,
  sum(t.valor) filter (where t.valor > 0)                       as receitas,
  -abs(sum(t.valor) filter (where t.valor < 0))                 as despesas,
  -abs(sum(t.valor) filter (where t.valor < 0 and c.grupo = 'essencial'))     as despesas_essenciais,
  -abs(sum(t.valor) filter (where t.valor < 0 and c.grupo = 'nao_essencial')) as despesas_nao_essenciais,
  -abs(sum(t.valor) filter (where t.valor < 0 and c.grupo = 'divida'))        as pagamento_dividas,
  sum(t.valor)                                                  as resultado,
  count(*)                                                      as qtd_transacoes
from public.transacoes t
left join public.categorias c on c.id = t.categoria_id
-- Transferências entre contas próprias não são receita nem despesa.
where c.grupo is distinct from 'transferencia'
group by t.user_id, date_trunc('month', t.data);

comment on view public.v_resumo_mensal is
  'Receitas, despesas e resultado por mês. Ignora transferências internas.';

create view public.v_gastos_por_categoria
with (security_invoker = true)
as
select
  t.user_id,
  date_trunc('month', t.data)::date          as mes,
  coalesce(c.id::text, 'sem_categoria')      as categoria_id,
  coalesce(c.nome, 'Não categorizado')       as categoria,
  coalesce(c.grupo::text, 'nao_essencial')   as grupo,
  abs(sum(t.valor))                          as total,
  count(*)                                   as qtd
from public.transacoes t
left join public.categorias c on c.id = t.categoria_id
where t.valor < 0
  and c.grupo is distinct from 'transferencia'
group by t.user_id, date_trunc('month', t.data), c.id, c.nome, c.grupo;

create view public.v_dividas_resumo
with (security_invoker = true)
as
select
  d.user_id,
  count(*)                                            as qtd_dividas,
  sum(d.saldo_devedor)                                as saldo_total,
  sum(d.parcela_minima)                               as parcela_minima_total,
  -- Quanto o usuário queima por mês só em juros, sem amortizar nada.
  sum(d.saldo_devedor * d.taxa_juros_mensal)          as juros_mensais,
  max(d.taxa_juros_mensal)                            as maior_taxa,
  count(*) filter (where d.status = 'em_atraso')      as qtd_em_atraso,
  count(*) filter (where d.em_orgao_protecao)         as qtd_negativado,
  count(*) filter (where d.aceita_negociacao
                     and d.taxa_juros_mensal >= 0.05) as qtd_negociaveis
from public.dividas d
where d.status not in ('quitada')
group by d.user_id;

comment on view public.v_dividas_resumo is
  'Agregado das dívidas ativas. juros_mensais é o custo mensal de não fazer nada.';

-- ---------------------------------------------------------------------------
-- Simulador de quitação
-- ---------------------------------------------------------------------------

create or replace function public.fn_simular_quitacao(
  p_estrategia    public.estrategia_quitacao default 'avalanche',
  -- NULL = usa o aporte_extra_mensal cadastrado no perfil.
  p_aporte_extra  numeric default null,
  p_meses_max     integer default 360
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user        uuid := (select auth.uid());
  v_aporte      numeric(14, 2);

  -- Arrays paralelos indexados por posição da dívida. plpgsql não deixa
  -- atribuir a um campo de elemento de array composto, então cada atributo
  -- vira seu próprio array.
  v_id          uuid[]    := '{}';
  v_credor      text[]    := '{}';
  v_tipo        text[]    := '{}';
  v_saldo       numeric[] := '{}';
  v_saldo_ini   numeric[] := '{}';
  v_taxa        numeric[] := '{}';
  v_min         numeric[] := '{}';
  v_juros_pg    numeric[] := '{}';
  v_total_pg    numeric[] := '{}';
  v_mes_quit    integer[] := '{}';
  -- Ordem de ataque: lista de índices, do primeiro alvo ao último.
  v_prio        integer[] := '{}';

  v_n           integer;
  v_i           integer;
  v_alvo        integer;
  v_orcamento   numeric(14, 2);
  v_disponivel  numeric(14, 2);
  v_juros       numeric(14, 2);
  v_pag         numeric(14, 2);
  v_mes         integer := 0;
  v_juros_total numeric(14, 2) := 0;
  v_pago_total  numeric(14, 2) := 0;
  v_juros_mes   numeric(14, 2);
  v_pago_mes    numeric(14, 2);
  v_saldo_total numeric(14, 2);
  v_juros_ini   numeric(14, 2);
  v_quitadas    jsonb;
  v_cronograma  jsonb := '[]'::jsonb;
begin
  if v_user is null then
    raise exception 'fn_simular_quitacao requer um usuário autenticado';
  end if;

  select coalesce(p_aporte_extra, pf.aporte_extra_mensal, 0)
    into v_aporte
    from public.perfis pf
   where pf.id = v_user;

  v_aporte := coalesce(v_aporte, coalesce(p_aporte_extra, 0));

  -- Carrega as dívidas JÁ na ordem de ataque da estratégia. A ordem é fixada
  -- aqui e não recalculada mês a mês — é assim que avalanche e bola de neve
  -- são definidas na literatura, e mantém o plano estável para o usuário.
  -- Como os arrays saem ordenados, a posição no array já É a prioridade.
  select
    array_agg(d.id                order by d.ord),
    array_agg(d.credor            order by d.ord),
    array_agg(d.tipo             order by d.ord),
    array_agg(d.saldo_devedor     order by d.ord),
    array_agg(d.taxa_juros_mensal order by d.ord),
    array_agg(d.parcela_minima    order by d.ord)
  into v_id, v_credor, v_tipo, v_saldo, v_taxa, v_min
  from (
    select
      d.id,
      d.credor,
      d.tipo::text as tipo,
      d.saldo_devedor,
      d.taxa_juros_mensal,
      d.parcela_minima,
      row_number() over (
        order by
          case when p_estrategia = 'avalanche'     then d.taxa_juros_mensal end desc nulls last,
          case when p_estrategia = 'bola_de_neve'  then d.saldo_devedor     end asc  nulls last,
          case when p_estrategia = 'personalizada' then d.ordem_prioridade  end asc  nulls last,
          d.saldo_devedor asc
      ) as ord
    from public.dividas d
    where d.user_id = v_user
      and d.status <> 'quitada'
      and d.saldo_devedor > 0
  ) d;

  v_n := coalesce(array_length(v_saldo, 1), 0);

  for v_i in 1 .. v_n loop
    v_prio := array_append(v_prio, v_i);
  end loop;

  if v_n = 0 then
    return jsonb_build_object(
      'viavel',        true,
      'sem_dividas',   true,
      'estrategia',    p_estrategia,
      'aporte_extra',  v_aporte,
      'meses',         0,
      'juros_total',   0,
      'pago_total',    0,
      'dividas',       '[]'::jsonb,
      'cronograma',    '[]'::jsonb
    );
  end if;

  -- Arrays acumuladores começam zerados, um slot por dívida.
  v_saldo_ini := v_saldo;
  for v_i in 1 .. v_n loop
    v_juros_pg := array_append(v_juros_pg, 0::numeric);
    v_total_pg := array_append(v_total_pg, 0::numeric);
    v_mes_quit := array_append(v_mes_quit, null::integer);
  end loop;

  -- Orçamento mensal fixo: soma das mínimas de HOJE + aporte extra. Conforme
  -- dívidas são quitadas, a mínima liberada não some — rola para a próxima.
  -- É exatamente esse rolamento que caracteriza o método bola de neve.
  v_orcamento := 0;
  v_saldo_total := 0;
  v_juros_ini := 0;
  for v_i in 1 .. v_n loop
    v_orcamento   := v_orcamento + v_min[v_i];
    v_saldo_total := v_saldo_total + v_saldo[v_i];
    v_juros_ini   := v_juros_ini + v_saldo[v_i] * v_taxa[v_i];
  end loop;
  v_orcamento := v_orcamento + v_aporte;

  -- Diagnóstico honesto antes de simular: se o orçamento não cobre nem os
  -- juros do primeiro mês, a dívida cresce para sempre e nenhum cronograma
  -- existe. O usuário precisa ouvir isso, não ver um gráfico bonito.
  if v_orcamento <= v_juros_ini then
    return jsonb_build_object(
      'viavel',            false,
      'motivo',            'orcamento_menor_que_juros',
      'estrategia',        p_estrategia,
      'aporte_extra',      v_aporte,
      'orcamento_mensal',  v_orcamento,
      'juros_primeiro_mes', round(v_juros_ini, 2),
      -- Quanto falta por mês só para estancar o crescimento da dívida.
      'deficit_mensal',    round(v_juros_ini - v_orcamento, 2),
      'saldo_total',       round(v_saldo_total, 2),
      'cronograma',        '[]'::jsonb
    );
  end if;

  -- Loop mensal.
  while v_mes < p_meses_max loop
    v_saldo_total := 0;
    for v_i in 1 .. v_n loop
      v_saldo_total := v_saldo_total + v_saldo[v_i];
    end loop;
    exit when v_saldo_total <= 0.005;

    v_mes := v_mes + 1;
    v_juros_mes := 0;
    v_pago_mes := 0;
    v_quitadas := '[]'::jsonb;

    -- 1) Juros do mês incidem sobre o saldo em aberto.
    for v_i in 1 .. v_n loop
      if v_saldo[v_i] > 0 then
        v_juros := round(v_saldo[v_i] * v_taxa[v_i], 2);
        v_saldo[v_i] := v_saldo[v_i] + v_juros;
        v_juros_pg[v_i] := v_juros_pg[v_i] + v_juros;
        v_juros_mes := v_juros_mes + v_juros;
      end if;
    end loop;

    v_disponivel := v_orcamento;

    -- 2) Paga a mínima de cada dívida, para não gerar atraso em nenhuma.
    for v_i in 1 .. v_n loop
      if v_saldo[v_i] > 0 and v_disponivel > 0 then
        v_pag := least(v_min[v_i], v_saldo[v_i], v_disponivel);
        v_saldo[v_i]    := v_saldo[v_i] - v_pag;
        v_total_pg[v_i] := v_total_pg[v_i] + v_pag;
        v_disponivel    := v_disponivel - v_pag;
        v_pago_mes      := v_pago_mes + v_pag;
      end if;
    end loop;

    -- 3) Todo o resto vai para o alvo da vez, na ordem da estratégia.
    for v_i in 1 .. v_n loop
      exit when v_disponivel <= 0.005;
      v_alvo := v_prio[v_i];
      if v_saldo[v_alvo] > 0 then
        v_pag := least(v_saldo[v_alvo], v_disponivel);
        v_saldo[v_alvo]    := v_saldo[v_alvo] - v_pag;
        v_total_pg[v_alvo] := v_total_pg[v_alvo] + v_pag;
        v_disponivel       := v_disponivel - v_pag;
        v_pago_mes         := v_pago_mes + v_pag;
      end if;
    end loop;

    -- 4) Registra quem virou pó neste mês.
    for v_i in 1 .. v_n loop
      if v_saldo[v_i] <= 0.005 and v_mes_quit[v_i] is null then
        v_saldo[v_i] := 0;
        v_mes_quit[v_i] := v_mes;
        v_quitadas := v_quitadas || jsonb_build_object(
          'divida_id', v_id[v_i],
          'credor',    v_credor[v_i]
        );
      end if;
    end loop;

    v_juros_total := v_juros_total + v_juros_mes;
    v_pago_total  := v_pago_total + v_pago_mes;

    v_saldo_total := 0;
    for v_i in 1 .. v_n loop
      v_saldo_total := v_saldo_total + v_saldo[v_i];
    end loop;

    v_cronograma := v_cronograma || jsonb_build_object(
      'mes',           v_mes,
      'competencia',   to_char((current_date + make_interval(months => v_mes))::date, 'YYYY-MM'),
      'juros',         round(v_juros_mes, 2),
      'pago',          round(v_pago_mes, 2),
      'saldo_restante', round(v_saldo_total, 2),
      'quitadas',      v_quitadas
    );
  end loop;

  return jsonb_build_object(
    'viavel',           v_saldo_total <= 0.005,
    'estrategia',       p_estrategia,
    'aporte_extra',     v_aporte,
    'orcamento_mensal', round(v_orcamento, 2),
    'meses',            v_mes,
    'data_liberdade',   to_char((current_date + make_interval(months => v_mes))::date, 'YYYY-MM-DD'),
    'juros_total',      round(v_juros_total, 2),
    'pago_total',       round(v_pago_total, 2),
    'saldo_inicial',    round((select sum(x) from unnest(v_saldo_ini) x), 2),
    'dividas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'divida_id',     v_id[i],
               'credor',        v_credor[i],
               'tipo',          v_tipo[i],
               'saldo_inicial', round(v_saldo_ini[i], 2),
               'taxa_mensal',   v_taxa[i],
               'parcela_minima', round(v_min[i], 2),
               'juros_pagos',   round(v_juros_pg[i], 2),
               'total_pago',    round(v_total_pg[i], 2),
               'mes_quitacao',  v_mes_quit[i],
               'ordem_ataque',  array_position(v_prio, i)
             ) order by array_position(v_prio, i)), '[]'::jsonb)
      from generate_series(1, v_n) i
    ),
    'cronograma', v_cronograma
  );
end;
$$;

comment on function public.fn_simular_quitacao is
  'Simula a quitação mês a mês. Juros -> mínimas -> sobra para o alvo da estratégia. Retorna viavel=false quando o orçamento não cobre os juros.';

-- ---------------------------------------------------------------------------
-- Raio-X: a foto completa que o agente lê antes de opinar
-- ---------------------------------------------------------------------------

create or replace function public.fn_raio_x_financeiro()
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user       uuid := (select auth.uid());
  v_perfil     record;
  v_dividas    jsonb;
  v_resumo     jsonb;
  v_categorias jsonb;
  v_resumo_div record;
  v_avalanche  jsonb;
  v_neve       jsonb;
begin
  if v_user is null then
    raise exception 'fn_raio_x_financeiro requer um usuário autenticado';
  end if;

  select * into v_perfil from public.perfis where id = v_user;

  -- v_dividas_resumo é agregada: devolve zero linhas quando não há dívida
  -- ativa, e aí o record fica todo NULL. Os coalesce abaixo contam com isso.
  select * into v_resumo_div
    from public.v_dividas_resumo r where r.user_id = v_user;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.taxa_juros_mensal desc), '[]'::jsonb)
    into v_dividas
    from (
      select
        d.id, d.credor, d.tipo, d.status, d.saldo_devedor, d.taxa_juros_mensal,
        d.parcela_minima, d.parcelas_total, d.parcelas_pagas, d.dia_vencimento,
        d.dias_em_atraso, d.aceita_negociacao, d.em_orgao_protecao,
        -- Custo mensal de manter essa dívida viva.
        round(d.saldo_devedor * d.taxa_juros_mensal, 2) as juros_mes
      from public.dividas d
      where d.user_id = v_user and d.status <> 'quitada'
    ) x;

  -- Últimos 6 meses fechados + o corrente.
  select coalesce(jsonb_agg(to_jsonb(m) order by m.mes desc), '[]'::jsonb)
    into v_resumo
    from (
      select * from public.v_resumo_mensal
      where user_id = v_user
        and mes >= date_trunc('month', current_date - interval '6 months')::date
    ) m;

  -- Onde o dinheiro está indo nos últimos 3 meses, do maior para o menor.
  select coalesce(jsonb_agg(to_jsonb(c) order by c.total desc), '[]'::jsonb)
    into v_categorias
    from (
      select categoria, grupo, round(sum(total), 2) as total, sum(qtd) as qtd
      from public.v_gastos_por_categoria
      where user_id = v_user
        and mes >= date_trunc('month', current_date - interval '3 months')::date
      group by categoria, grupo
      order by sum(total) desc
      limit 15
    ) c;

  v_avalanche := public.fn_simular_quitacao('avalanche', null, 360);
  v_neve      := public.fn_simular_quitacao('bola_de_neve', null, 360);

  return jsonb_build_object(
    'gerado_em', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'),
    'perfil', jsonb_build_object(
      'nome',                coalesce(v_perfil.nome, ''),
      'renda_mensal',        coalesce(v_perfil.renda_mensal, 0),
      'aporte_extra_mensal', coalesce(v_perfil.aporte_extra_mensal, 0),
      'reserva_meta_meses',  coalesce(v_perfil.reserva_meta_meses, 3)
    ),
    'dividas_resumo', coalesce(to_jsonb(v_resumo_div), '{}'::jsonb),
    'indicadores', jsonb_build_object(
      -- Acima de ~30% a situação já é considerada crítica pelo Serasa/BCB.
      'comprometimento_renda',
        case when coalesce(v_perfil.renda_mensal, 0) > 0
             then round(coalesce(v_resumo_div.parcela_minima_total, 0)
                        / v_perfil.renda_mensal * 100, 1)
             else null end,
      'juros_mensais_perc_renda',
        case when coalesce(v_perfil.renda_mensal, 0) > 0
             then round(coalesce(v_resumo_div.juros_mensais, 0)
                        / v_perfil.renda_mensal * 100, 1)
             else null end
    ),
    'dividas',            v_dividas,
    'resumo_mensal',      v_resumo,
    'gastos_categoria_3m', v_categorias,
    -- Os dois cenários lado a lado, sem cronograma, para o agente comparar
    -- "menos juros" contra "primeira vitória mais rápida".
    'cenarios', jsonb_build_object(
      'avalanche',    v_avalanche - 'cronograma',
      'bola_de_neve', v_neve - 'cronograma'
    )
  );
end;
$$;

comment on function public.fn_raio_x_financeiro is
  'Snapshot financeiro completo em um único JSON. É a primeira ferramenta que o agente de IA chama.';

grant execute on function public.fn_simular_quitacao  to authenticated;
grant execute on function public.fn_raio_x_financeiro to authenticated;

-- ==========================================================================
-- 20260817000500_canais_autorizados.sql
-- ==========================================================================

-- FinBR — acesso pelo WhatsApp, com autorização por número.
--
-- O PROBLEMA: o painel autentica o usuário e a RLS resolve o resto — cada
-- query roda sob o JWT de quem pediu. O WhatsApp não tem nada disso. Chega uma
-- mensagem de um número e só.
--
-- Se o fluxo do n8n simplesmente consultasse o banco com a service_role key,
-- qualquer pessoa que soubesse o número do bot receberia o raio-X financeiro
-- completo respondendo "quanto eu devo?".
--
-- A SOLUÇÃO: as funções abaixo NÃO aceitam user_id de quem chama. Elas
-- resolvem o dono a partir do número, contra uma lista de números que você
-- cadastrou. Número fora da lista não devolve dado nenhum — devolve um erro.
-- Mesmo com a service_role key vazada, essas funções só entregam o que o
-- número autorizado poderia ver.

-- ---------------------------------------------------------------------------
-- Lista de números autorizados
-- ---------------------------------------------------------------------------

create table public.canais_autorizados (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  canal         text not null default 'whatsapp',
  -- Telefone em E.164 SEM o '+': 5511999998888. É o formato que a Evolution
  -- API entrega no campo `remoteJid` (antes do sufixo @s.whatsapp.net), então
  -- guardar assim evita normalizar dos dois lados.
  identificador text not null,
  apelido       text,
  ativo         boolean not null default true,
  ultimo_acesso timestamptz,
  criado_em     timestamptz not null default now(),

  constraint canais_identificador_so_digitos check (identificador ~ '^[0-9]{10,15}$')
);

-- Um número só pode pertencer a um usuário por vez.
create unique index canais_ativos_idx
  on public.canais_autorizados (canal, identificador)
  where ativo;

alter table public.canais_autorizados enable row level security;

create policy "canais_select_proprio" on public.canais_autorizados
  for select to authenticated using ((select auth.uid()) = user_id);

create policy "canais_insert_proprio" on public.canais_autorizados
  for insert to authenticated with check ((select auth.uid()) = user_id);

create policy "canais_update_proprio" on public.canais_autorizados
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "canais_delete_proprio" on public.canais_autorizados
  for delete to authenticated using ((select auth.uid()) = user_id);

grant select, insert, update, delete on public.canais_autorizados to authenticated;

-- ---------------------------------------------------------------------------
-- Motor interno, parametrizado por usuário
-- ---------------------------------------------------------------------------
-- Até agora o simulador lia auth.uid() direto. Para servir também o WhatsApp,
-- o miolo passa a receber o usuário como parâmetro, e ganha dois invólucros:
-- um que pega o usuário do JWT (painel) e outro que pega do número (WhatsApp).
--
-- A função abaixo é PERIGOSA se exposta: ela aceita qualquer user_id. Por isso
-- o EXECUTE dela é revogado de todo mundo no fim do arquivo — só os invólucros
-- a alcançam, e eles rodam como definer.

create or replace function public.fn_simular_para(
  p_user          uuid,
  p_estrategia    public.estrategia_quitacao default 'avalanche',
  p_aporte_extra  numeric default null,
  p_meses_max     integer default 360
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_aporte      numeric(14, 2);
  v_id          uuid[]    := '{}';
  v_credor      text[]    := '{}';
  v_tipo        text[]    := '{}';
  v_saldo       numeric[] := '{}';
  v_saldo_ini   numeric[] := '{}';
  v_taxa        numeric[] := '{}';
  v_min         numeric[] := '{}';
  v_juros_pg    numeric[] := '{}';
  v_total_pg    numeric[] := '{}';
  v_mes_quit    integer[] := '{}';
  v_prio        integer[] := '{}';
  v_n           integer;
  v_i           integer;
  v_alvo        integer;
  v_orcamento   numeric(14, 2);
  v_disponivel  numeric(14, 2);
  v_juros       numeric(14, 2);
  v_pag         numeric(14, 2);
  v_mes         integer := 0;
  v_juros_total numeric(14, 2) := 0;
  v_pago_total  numeric(14, 2) := 0;
  v_juros_mes   numeric(14, 2);
  v_pago_mes    numeric(14, 2);
  v_saldo_total numeric(14, 2);
  v_juros_ini   numeric(14, 2);
  v_quitadas    jsonb;
  v_cronograma  jsonb := '[]'::jsonb;
begin
  if p_user is null then
    raise exception 'fn_simular_para exige um usuário';
  end if;

  select coalesce(p_aporte_extra, pf.aporte_extra_mensal, 0)
    into v_aporte from public.perfis pf where pf.id = p_user;
  v_aporte := coalesce(v_aporte, coalesce(p_aporte_extra, 0));

  select
    array_agg(d.id                order by d.ord),
    array_agg(d.credor            order by d.ord),
    array_agg(d.tipo              order by d.ord),
    array_agg(d.saldo_devedor     order by d.ord),
    array_agg(d.taxa_juros_mensal order by d.ord),
    array_agg(d.parcela_minima    order by d.ord)
  into v_id, v_credor, v_tipo, v_saldo, v_taxa, v_min
  from (
    select d.id, d.credor, d.tipo::text as tipo, d.saldo_devedor,
           d.taxa_juros_mensal, d.parcela_minima,
      row_number() over (
        order by
          case when p_estrategia = 'avalanche'     then d.taxa_juros_mensal end desc nulls last,
          case when p_estrategia = 'bola_de_neve'  then d.saldo_devedor     end asc  nulls last,
          case when p_estrategia = 'personalizada' then d.ordem_prioridade  end asc  nulls last,
          d.saldo_devedor asc
      ) as ord
    from public.dividas d
    where d.user_id = p_user
      and d.status <> 'quitada'
      and d.saldo_devedor > 0
  ) d;

  v_n := coalesce(array_length(v_saldo, 1), 0);
  for v_i in 1 .. v_n loop v_prio := array_append(v_prio, v_i); end loop;

  if v_n = 0 then
    return jsonb_build_object(
      'viavel', true, 'sem_dividas', true, 'estrategia', p_estrategia,
      'aporte_extra', v_aporte, 'meses', 0, 'juros_total', 0, 'pago_total', 0,
      'dividas', '[]'::jsonb, 'cronograma', '[]'::jsonb
    );
  end if;

  v_saldo_ini := v_saldo;
  for v_i in 1 .. v_n loop
    v_juros_pg := array_append(v_juros_pg, 0::numeric);
    v_total_pg := array_append(v_total_pg, 0::numeric);
    v_mes_quit := array_append(v_mes_quit, null::integer);
  end loop;

  v_orcamento := 0; v_saldo_total := 0; v_juros_ini := 0;
  for v_i in 1 .. v_n loop
    v_orcamento   := v_orcamento + v_min[v_i];
    v_saldo_total := v_saldo_total + v_saldo[v_i];
    v_juros_ini   := v_juros_ini + v_saldo[v_i] * v_taxa[v_i];
  end loop;
  v_orcamento := v_orcamento + v_aporte;

  if v_orcamento <= v_juros_ini then
    return jsonb_build_object(
      'viavel', false, 'motivo', 'orcamento_menor_que_juros',
      'estrategia', p_estrategia, 'aporte_extra', v_aporte,
      'orcamento_mensal', v_orcamento,
      'juros_primeiro_mes', round(v_juros_ini, 2),
      'deficit_mensal', round(v_juros_ini - v_orcamento, 2),
      'saldo_total', round(v_saldo_total, 2), 'cronograma', '[]'::jsonb
    );
  end if;

  while v_mes < p_meses_max loop
    v_saldo_total := 0;
    for v_i in 1 .. v_n loop v_saldo_total := v_saldo_total + v_saldo[v_i]; end loop;
    exit when v_saldo_total <= 0.005;

    v_mes := v_mes + 1;
    v_juros_mes := 0; v_pago_mes := 0; v_quitadas := '[]'::jsonb;

    for v_i in 1 .. v_n loop
      if v_saldo[v_i] > 0 then
        v_juros := round(v_saldo[v_i] * v_taxa[v_i], 2);
        v_saldo[v_i] := v_saldo[v_i] + v_juros;
        v_juros_pg[v_i] := v_juros_pg[v_i] + v_juros;
        v_juros_mes := v_juros_mes + v_juros;
      end if;
    end loop;

    v_disponivel := v_orcamento;

    for v_i in 1 .. v_n loop
      if v_saldo[v_i] > 0 and v_disponivel > 0 then
        v_pag := least(v_min[v_i], v_saldo[v_i], v_disponivel);
        v_saldo[v_i] := v_saldo[v_i] - v_pag;
        v_total_pg[v_i] := v_total_pg[v_i] + v_pag;
        v_disponivel := v_disponivel - v_pag;
        v_pago_mes := v_pago_mes + v_pag;
      end if;
    end loop;

    for v_i in 1 .. v_n loop
      exit when v_disponivel <= 0.005;
      v_alvo := v_prio[v_i];
      if v_saldo[v_alvo] > 0 then
        v_pag := least(v_saldo[v_alvo], v_disponivel);
        v_saldo[v_alvo] := v_saldo[v_alvo] - v_pag;
        v_total_pg[v_alvo] := v_total_pg[v_alvo] + v_pag;
        v_disponivel := v_disponivel - v_pag;
        v_pago_mes := v_pago_mes + v_pag;
      end if;
    end loop;

    for v_i in 1 .. v_n loop
      if v_saldo[v_i] <= 0.005 and v_mes_quit[v_i] is null then
        v_saldo[v_i] := 0;
        v_mes_quit[v_i] := v_mes;
        v_quitadas := v_quitadas || jsonb_build_object(
          'divida_id', v_id[v_i], 'credor', v_credor[v_i]);
      end if;
    end loop;

    v_juros_total := v_juros_total + v_juros_mes;
    v_pago_total  := v_pago_total + v_pago_mes;

    v_saldo_total := 0;
    for v_i in 1 .. v_n loop v_saldo_total := v_saldo_total + v_saldo[v_i]; end loop;

    v_cronograma := v_cronograma || jsonb_build_object(
      'mes', v_mes,
      'competencia', to_char((current_date + make_interval(months => v_mes))::date, 'YYYY-MM'),
      'juros', round(v_juros_mes, 2),
      'pago', round(v_pago_mes, 2),
      'saldo_restante', round(v_saldo_total, 2),
      'quitadas', v_quitadas
    );
  end loop;

  return jsonb_build_object(
    'viavel', v_saldo_total <= 0.005,
    'estrategia', p_estrategia,
    'aporte_extra', v_aporte,
    'orcamento_mensal', round(v_orcamento, 2),
    'meses', v_mes,
    'data_liberdade', to_char((current_date + make_interval(months => v_mes))::date, 'YYYY-MM-DD'),
    'juros_total', round(v_juros_total, 2),
    'pago_total', round(v_pago_total, 2),
    'saldo_inicial', round((select sum(x) from unnest(v_saldo_ini) x), 2),
    'dividas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'divida_id', v_id[i], 'credor', v_credor[i], 'tipo', v_tipo[i],
               'saldo_inicial', round(v_saldo_ini[i], 2),
               'taxa_mensal', v_taxa[i],
               'parcela_minima', round(v_min[i], 2),
               'juros_pagos', round(v_juros_pg[i], 2),
               'total_pago', round(v_total_pg[i], 2),
               'mes_quitacao', v_mes_quit[i],
               'ordem_ataque', array_position(v_prio, i)
             ) order by array_position(v_prio, i)), '[]'::jsonb)
      from generate_series(1, v_n) i
    ),
    'cronograma', v_cronograma
  );
end;
$$;

create or replace function public.fn_raio_x_para(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_perfil     record;
  v_dividas    jsonb;
  v_resumo     jsonb;
  v_categorias jsonb;
  v_resumo_div record;
begin
  if p_user is null then
    raise exception 'fn_raio_x_para exige um usuário';
  end if;

  select * into v_perfil from public.perfis where id = p_user;

  select
    count(*)                                       as qtd_dividas,
    sum(d.saldo_devedor)                           as saldo_total,
    sum(d.parcela_minima)                          as parcela_minima_total,
    sum(d.saldo_devedor * d.taxa_juros_mensal)     as juros_mensais,
    max(d.taxa_juros_mensal)                       as maior_taxa,
    count(*) filter (where d.status = 'em_atraso') as qtd_em_atraso,
    count(*) filter (where d.em_orgao_protecao)    as qtd_negativado
  into v_resumo_div
  from public.dividas d
  where d.user_id = p_user and d.status <> 'quitada';

  select coalesce(jsonb_agg(to_jsonb(x) order by x.taxa_juros_mensal desc), '[]'::jsonb)
    into v_dividas
    from (
      select d.id, d.credor, d.tipo, d.status, d.saldo_devedor, d.taxa_juros_mensal,
             d.parcela_minima, d.parcelas_total, d.parcelas_pagas, d.dia_vencimento,
             d.dias_em_atraso, d.aceita_negociacao, d.em_orgao_protecao,
             round(d.saldo_devedor * d.taxa_juros_mensal, 2) as juros_mes,
             -- Anual composta já calculada, em %: (1+t)^12 - 1. O modelo cita
             -- este campo em vez de fazer a conta — LLM errando potência em
             -- conselho financeiro não é um risco que valha correr.
             round((power(1 + d.taxa_juros_mensal, 12) - 1) * 100, 0) as taxa_anual_pct
      from public.dividas d
      where d.user_id = p_user and d.status <> 'quitada'
    ) x;

  select coalesce(jsonb_agg(to_jsonb(m) order by m.mes desc), '[]'::jsonb)
    into v_resumo
    from (
      select date_trunc('month', t.data)::date as mes,
             sum(t.valor) filter (where t.valor > 0) as receitas,
             sum(t.valor) filter (where t.valor < 0) as despesas,
             sum(t.valor) as resultado
      from public.transacoes t
      left join public.categorias c on c.id = t.categoria_id
      where t.user_id = p_user
        and c.grupo is distinct from 'transferencia'
        and t.data >= date_trunc('month', current_date - interval '6 months')::date
      group by date_trunc('month', t.data)
    ) m;

  select coalesce(jsonb_agg(to_jsonb(c) order by c.total desc), '[]'::jsonb)
    into v_categorias
    from (
      select coalesce(c.nome, 'Não categorizado')     as categoria,
             coalesce(c.grupo::text, 'nao_essencial') as grupo,
             round(abs(sum(t.valor)), 2)              as total
      from public.transacoes t
      left join public.categorias c on c.id = t.categoria_id
      where t.user_id = p_user
        and t.valor < 0
        and c.grupo is distinct from 'transferencia'
        and t.data >= date_trunc('month', current_date - interval '3 months')::date
      group by c.nome, c.grupo
      order by abs(sum(t.valor)) desc
      limit 15
    ) c;

  return jsonb_build_object(
    'gerado_em', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'),
    'perfil', jsonb_build_object(
      'nome', coalesce(v_perfil.nome, ''),
      'renda_mensal', coalesce(v_perfil.renda_mensal, 0),
      'aporte_extra_mensal', coalesce(v_perfil.aporte_extra_mensal, 0)
    ),
    'dividas_resumo', coalesce(to_jsonb(v_resumo_div), '{}'::jsonb),
    'indicadores', jsonb_build_object(
      'comprometimento_renda',
        case when coalesce(v_perfil.renda_mensal, 0) > 0
             then round(coalesce(v_resumo_div.parcela_minima_total, 0)
                        / v_perfil.renda_mensal * 100, 1) else null end,
      'juros_mensais_perc_renda',
        case when coalesce(v_perfil.renda_mensal, 0) > 0
             then round(coalesce(v_resumo_div.juros_mensais, 0)
                        / v_perfil.renda_mensal * 100, 1) else null end
    ),
    'dividas', v_dividas,
    'resumo_mensal', v_resumo,
    'gastos_categoria_3m', v_categorias,
    'cenarios', jsonb_build_object(
      'avalanche',    public.fn_simular_para(p_user, 'avalanche', null, 360) - 'cronograma',
      'bola_de_neve', public.fn_simular_para(p_user, 'bola_de_neve', null, 360) - 'cronograma'
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Invólucro do painel: usuário vem do JWT
-- ---------------------------------------------------------------------------
-- Precisam ser SECURITY DEFINER, não invoker: o EXECUTE do motor interno é
-- revogado de `authenticated`, então um invólucro invoker bateria em
-- "permission denied for function fn_simular_para" ao repassar a chamada.
--
-- É seguro porque o usuário sai de auth.uid() — que continua lendo o JWT da
-- requisição mesmo sob definer — e não de um parâmetro. Não existe entrada
-- do cliente capaz de mudar de quem são os dados devolvidos.

create or replace function public.fn_simular_quitacao(
  p_estrategia    public.estrategia_quitacao default 'avalanche',
  p_aporte_extra  numeric default null,
  p_meses_max     integer default 360
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'fn_simular_quitacao requer um usuário autenticado';
  end if;
  return public.fn_simular_para((select auth.uid()), p_estrategia, p_aporte_extra, p_meses_max);
end;
$$;

create or replace function public.fn_raio_x_financeiro()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'fn_raio_x_financeiro requer um usuário autenticado';
  end if;
  return public.fn_raio_x_para((select auth.uid()));
end;
$$;

-- ---------------------------------------------------------------------------
-- Invólucro do WhatsApp: usuário vem do NÚMERO, nunca de quem chama
-- ---------------------------------------------------------------------------

create or replace function public.fn_usuario_do_canal(
  p_identificador text,
  p_canal         text default 'whatsapp'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
  -- A Evolution manda "5511999998888@s.whatsapp.net". Aceitamos com ou sem o
  -- sufixo, e limpamos '+', espaço e traço, para o cadastro não depender de o
  -- número ter sido digitado num formato exato.
  v_limpo text := regexp_replace(split_part(p_identificador, '@', 1), '[^0-9]', '', 'g');
begin
  select c.user_id into v_user
    from public.canais_autorizados c
   where c.canal = p_canal and c.identificador = v_limpo and c.ativo;

  if v_user is null then
    raise exception 'Número não autorizado' using errcode = '28000';
  end if;

  update public.canais_autorizados
     set ultimo_acesso = now()
   where canal = p_canal and identificador = v_limpo and ativo;

  return v_user;
end;
$$;

create or replace function public.fn_raio_x_por_canal(
  p_identificador text,
  p_canal         text default 'whatsapp'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.fn_raio_x_para(public.fn_usuario_do_canal(p_identificador, p_canal));
end;
$$;

create or replace function public.fn_simular_por_canal(
  p_identificador text,
  p_estrategia    public.estrategia_quitacao default 'avalanche',
  p_aporte_extra  numeric default null,
  p_canal         text default 'whatsapp'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.fn_simular_para(
    public.fn_usuario_do_canal(p_identificador, p_canal),
    p_estrategia, p_aporte_extra, 360);
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------------
-- No Postgres, função nasce com EXECUTE para PUBLIC. Sem revogar, um usuário
-- logado poderia chamar fn_simular_para com o uuid de outra pessoa e ler tudo.
-- Este bloco é o que impede isso — não remova.

revoke all on function public.fn_simular_para(uuid, public.estrategia_quitacao, numeric, integer) from public, anon, authenticated;
revoke all on function public.fn_raio_x_para(uuid)                                                from public, anon, authenticated;
revoke all on function public.fn_usuario_do_canal(text, text)                                     from public, anon, authenticated;

-- Os invólucros do WhatsApp: só a service_role (usada pelo n8n) alcança.
revoke all on function public.fn_raio_x_por_canal(text, text)                                              from public, anon, authenticated;
revoke all on function public.fn_simular_por_canal(text, public.estrategia_quitacao, numeric, text)        from public, anon, authenticated;
grant execute on function public.fn_raio_x_por_canal(text, text)                                       to service_role;
grant execute on function public.fn_simular_por_canal(text, public.estrategia_quitacao, numeric, text) to service_role;

-- Os do painel continuam abertos para usuário logado.
grant execute on function public.fn_simular_quitacao(public.estrategia_quitacao, numeric, integer) to authenticated;
grant execute on function public.fn_raio_x_financeiro()                                            to authenticated;

comment on table public.canais_autorizados is
  'Números liberados a consultar dados pelo WhatsApp. Número fora daqui recebe erro, não dado.';
comment on function public.fn_raio_x_por_canal is
  'Raio-X para o bot do WhatsApp. Resolve o dono pelo número; nunca aceita user_id de quem chama.';

-- ==========================================================================
-- 20260817000600_assistente_pessoal.sql
-- ==========================================================================

-- FinBR — assistente pessoal: tarefas, objetivos e memórias.
--
-- É aqui que o "treinar o assistente" vira coisa concreta: cada fato,
-- preferência ou rotina que você contar no WhatsApp é gravado em
-- assistente_memorias e volta como contexto em toda conversa futura. Não há
-- fine-tuning de modelo envolvido — o treinamento É o banco.
--
-- Segue o mesmo modelo de segurança do financeiro (migration 000500):
--   * as funções *_por_canal resolvem o dono pelo NÚMERO do WhatsApp, via
--     fn_usuario_do_canal, e nunca aceitam user_id de quem chama;
--   * só a service_role (o n8n) tem EXECUTE nelas;
--   * as tabelas têm RLS por dono, então o painel acessa direto via
--     supabase-js sem precisar de função nenhuma.

-- ---------------------------------------------------------------------------
-- Tarefas
-- ---------------------------------------------------------------------------

create type public.status_tarefa as enum ('pendente', 'concluida', 'cancelada');
create type public.prioridade_tarefa as enum ('baixa', 'media', 'alta');

create table public.tarefas (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  titulo        text not null,
  descricao     text,
  status        public.status_tarefa not null default 'pendente',
  prioridade    public.prioridade_tarefa not null default 'media',
  prazo         date,
  concluida_em  timestamptz,
  -- De onde a tarefa veio: 'whatsapp' quando o assistente criou, 'painel'
  -- quando vier da interface. Ajuda a depurar "quem cadastrou isso?".
  origem        text not null default 'painel',
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),

  constraint tarefas_titulo_tamanho check (char_length(titulo) between 1 and 300)
);

create index tarefas_pendentes_idx
  on public.tarefas (user_id, prazo asc nulls last, prioridade desc)
  where status = 'pendente';

-- ---------------------------------------------------------------------------
-- Objetivos
-- ---------------------------------------------------------------------------

create type public.status_objetivo as enum ('ativo', 'alcancado', 'pausado', 'abandonado');

create table public.objetivos (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  titulo        text not null,
  descricao     text,
  -- Área livre de propósito: financeiro, saúde, carreira, família... O
  -- assistente preenche com o que fizer sentido; enum aqui só atrapalharia.
  area          text,
  progresso     smallint not null default 0,
  alvo_data     date,
  status        public.status_objetivo not null default 'ativo',
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),

  constraint objetivos_progresso_faixa check (progresso between 0 and 100),
  constraint objetivos_titulo_tamanho check (char_length(titulo) between 1 and 300),
  constraint objetivos_area_tamanho check (area is null or char_length(area) between 1 and 100)
);

create index objetivos_ativos_idx
  on public.objetivos (user_id)
  where status = 'ativo';

-- ---------------------------------------------------------------------------
-- Memórias do assistente
-- ---------------------------------------------------------------------------
-- A diferença para a memória de conversa do n8n: aquela é uma janela curta e
-- por sessão; esta é permanente e volta em TODA conversa, como contexto.

create table public.assistente_memorias (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  -- 'preferencia', 'fato', 'pessoa', 'rotina', 'contexto'... Texto livre com
  -- default para o assistente não travar quando não souber classificar.
  categoria  text not null default 'fato',
  conteudo   text not null,
  ativo      boolean not null default true,
  fonte      text not null default 'whatsapp',
  criado_em  timestamptz not null default now(),

  constraint memorias_conteudo_tamanho check (char_length(conteudo) between 1 and 2000),
  constraint memorias_categoria_tamanho check (char_length(categoria) between 1 and 100)
);

create index memorias_ativas_idx
  on public.assistente_memorias (user_id, criado_em desc)
  where ativo;

-- Dedupe com garantia do banco, não só da função: sob webhook reentregue pela
-- Evolution, duas execuções concorrentes passariam ambas pelo SELECT de
-- verificação e inseririam duas vezes. O índice único é o que fecha a corrida
-- (md5 porque conteudo chega a 2000 chars). Parcial em `ativo`: memória
-- esquecida pode ser reensinada depois.
create unique index memorias_dedupe_idx
  on public.assistente_memorias (user_id, md5(conteudo))
  where ativo;

-- ---------------------------------------------------------------------------
-- RLS e grants (acesso do painel)
-- ---------------------------------------------------------------------------

alter table public.tarefas             enable row level security;
alter table public.objetivos           enable row level security;
alter table public.assistente_memorias enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['tarefas', 'objetivos', 'assistente_memorias'] loop
    execute format($f$
      create policy %1$I on public.%2$I
        for select to authenticated using ((select auth.uid()) = user_id);
    $f$, t || '_select_proprio', t);

    execute format($f$
      create policy %1$I on public.%2$I
        for insert to authenticated with check ((select auth.uid()) = user_id);
    $f$, t || '_insert_proprio', t);

    execute format($f$
      create policy %1$I on public.%2$I
        for update to authenticated
        using ((select auth.uid()) = user_id)
        with check ((select auth.uid()) = user_id);
    $f$, t || '_update_proprio', t);

    execute format($f$
      create policy %1$I on public.%2$I
        for delete to authenticated using ((select auth.uid()) = user_id);
    $f$, t || '_delete_proprio', t);
  end loop;
end;
$$;

grant select, insert, update, delete on
  public.tarefas,
  public.objetivos,
  public.assistente_memorias
to authenticated;

create trigger tarefas_atualizado_em
  before update on public.tarefas
  for each row execute function public.tg_set_atualizado_em();

create trigger objetivos_atualizado_em
  before update on public.objetivos
  for each row execute function public.tg_set_atualizado_em();

-- ---------------------------------------------------------------------------
-- Funções do assistente (canal WhatsApp)
-- ---------------------------------------------------------------------------

-- Escapa os metacaracteres do ILIKE. Sem isto, uma busca "%" — vinda de um
-- título legítimo ou de injeção de prompt na mensagem — casaria QUALQUER
-- linha, e com exatamente uma tarefa pendente o guard de ambiguidade não
-- protege: ela seria concluída sem relação com o pedido.
create or replace function public.fn_ilike_escapar(p text)
returns text
language sql
immutable
as $$
  select replace(replace(replace(coalesce(p, ''), '\', '\\'), '%', '\%'), '_', '\_');
$$;

-- O contexto que abre toda conversa: quem é a pessoa, que dia é hoje, o que
-- está pendente, aonde ela quer chegar e o que o assistente já sabe dela.
-- Deliberadamente COMPACTO — é reenviado com frequência; o raio-X financeiro
-- completo continua sendo uma ferramenta separada, chamada só quando o
-- assunto é dinheiro.
create or replace function public.fn_assistente_contexto_por_canal(
  p_identificador text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user     uuid := public.fn_usuario_do_canal(p_identificador);
  v_perfil   record;
  v_tarefas  jsonb;
  v_objetivos jsonb;
  v_memorias jsonb;
  v_financas record;
begin
  select * into v_perfil from public.perfis where id = v_user;

  select coalesce(jsonb_agg(to_jsonb(t) order by t.prazo asc nulls last, t.prioridade desc), '[]'::jsonb)
    into v_tarefas
    from (
      select id, titulo, prioridade, prazo,
             (prazo is not null and prazo < (now() at time zone 'America/Sao_Paulo')::date) as atrasada
      from public.tarefas
      where user_id = v_user and status = 'pendente'
      order by prazo asc nulls last, prioridade desc
      limit 20
    ) t;

  select coalesce(jsonb_agg(to_jsonb(o) order by o.criado_em), '[]'::jsonb)
    into v_objetivos
    from (
      select id, titulo, area, progresso, alvo_data, criado_em
      from public.objetivos
      where user_id = v_user and status = 'ativo'
      -- Sem este ORDER BY, o LIMIT cortaria 15 linhas ao acaso do plano de
      -- execução, e o agg externo só ordenaria o que sobrou.
      order by criado_em
      limit 15
    ) o;

  -- criado_em precisa estar no SELECT da subquery para o ORDER BY externo
  -- enxergá-lo; sai do JSON no fim porque não interessa ao modelo.
  select coalesce(jsonb_agg((to_jsonb(m) - 'criado_em') order by m.criado_em desc), '[]'::jsonb)
    into v_memorias
    from (
      select categoria, conteudo, criado_em
      from public.assistente_memorias
      where user_id = v_user and ativo
      order by criado_em desc
      limit 40
    ) m;

  -- Uma linha sobre dinheiro, não o raio-X inteiro.
  select
    count(*)                                   as qtd_dividas,
    coalesce(sum(saldo_devedor), 0)            as divida_total,
    coalesce(sum(parcela_minima), 0)           as minimas_mes
  into v_financas
  from public.dividas
  where user_id = v_user and status <> 'quitada';

  return jsonb_build_object(
    'agora', jsonb_build_object(
      'data',       to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD'),
      'hora',       to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI'),
      'dia_semana', trim(to_char(now() at time zone 'America/Sao_Paulo', 'day'))
    ),
    'perfil', jsonb_build_object(
      'nome',         coalesce(v_perfil.nome, ''),
      'renda_mensal', coalesce(v_perfil.renda_mensal, 0)
    ),
    'tarefas_pendentes', v_tarefas,
    'objetivos_ativos',  v_objetivos,
    'memorias',          v_memorias,
    'financas_resumo', jsonb_build_object(
      'qtd_dividas',  v_financas.qtd_dividas,
      'divida_total', v_financas.divida_total,
      'minimas_mes',  v_financas.minimas_mes
    )
  );
end;
$$;

create or replace function public.fn_tarefa_criar_por_canal(
  p_identificador text,
  p_titulo        text,
  p_prazo         date default null,
  p_prioridade    public.prioridade_tarefa default 'media',
  p_descricao     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user   uuid := public.fn_usuario_do_canal(p_identificador);
  v_titulo text := trim(coalesce(p_titulo, ''));
  v_nova   record;
begin
  -- Título vazio ou gigante viraria violação de CHECK crua no n8n; o modelo
  -- lida muito melhor com um {ok:false, motivo} do que com um erro 23514.
  if v_titulo = '' or char_length(v_titulo) > 300 then
    return jsonb_build_object('ok', false, 'motivo', 'titulo_invalido');
  end if;

  insert into public.tarefas (user_id, titulo, descricao, prazo, prioridade, origem)
  values (v_user, v_titulo, p_descricao, p_prazo, p_prioridade, 'whatsapp')
  returning id, titulo, prazo, prioridade into v_nova;

  return jsonb_build_object('ok', true, 'tarefa', to_jsonb(v_nova));
end;
$$;

-- Conclui por busca de texto (ou id direto, se o modelo tiver o uuid do
-- contexto). Ambiguidade NÃO conclui nada: devolve as candidatas para o
-- assistente perguntar qual é — concluir a tarefa errada é pior que perguntar.
create or replace function public.fn_tarefa_concluir_por_canal(
  p_identificador text,
  p_busca         text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user       uuid := public.fn_usuario_do_canal(p_identificador);
  v_id         uuid;
  v_padrao     text;
  v_candidatas jsonb;
  v_qtd        integer;
  v_feita      record;
begin
  -- O modelo pode passar o uuid que veio no contexto.
  begin
    v_id := p_busca::uuid;
  exception when others then
    v_id := null;
  end;

  if v_id is null then
    -- Busca vazia viraria o padrão '%%', que casa tudo.
    if trim(coalesce(p_busca, '')) = '' then
      return jsonb_build_object('ok', false, 'motivo', 'nao_encontrada');
    end if;

    v_padrao := '%' || public.fn_ilike_escapar(trim(p_busca)) || '%';

    select count(*), coalesce(jsonb_agg(jsonb_build_object('id', id, 'titulo', titulo)), '[]'::jsonb)
      into v_qtd, v_candidatas
      from public.tarefas
     where user_id = v_user and status = 'pendente'
       and titulo ilike v_padrao;

    if v_qtd = 0 then
      return jsonb_build_object('ok', false, 'motivo', 'nao_encontrada');
    elsif v_qtd > 1 then
      return jsonb_build_object('ok', false, 'motivo', 'ambigua', 'candidatas', v_candidatas);
    end if;

    select id into v_id
      from public.tarefas
     where user_id = v_user and status = 'pendente'
       and titulo ilike v_padrao;
  end if;

  update public.tarefas
     set status = 'concluida', concluida_em = now()
   where id = v_id and user_id = v_user and status = 'pendente'
  returning id, titulo into v_feita;

  if v_feita.id is null then
    return jsonb_build_object('ok', false, 'motivo', 'nao_encontrada');
  end if;

  return jsonb_build_object('ok', true, 'tarefa', to_jsonb(v_feita));
end;
$$;

create or replace function public.fn_memoria_salvar_por_canal(
  p_identificador text,
  p_conteudo      text,
  p_categoria     text default 'fato'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user     uuid := public.fn_usuario_do_canal(p_identificador);
  v_conteudo text := trim(coalesce(p_conteudo, ''));
  v_id       uuid;
begin
  if v_conteudo = '' or char_length(v_conteudo) > 2000 then
    return jsonb_build_object('ok', false, 'motivo', 'conteudo_invalido');
  end if;

  -- ON CONFLICT contra o índice único: mesmo com o webhook reentregue e duas
  -- execuções em paralelo, o mesmo fato entra uma vez só. O SELECT-antes-de-
  -- INSERT que havia aqui tinha exatamente essa corrida.
  insert into public.assistente_memorias (user_id, categoria, conteudo)
  values (v_user, left(coalesce(nullif(trim(p_categoria), ''), 'fato'), 100), v_conteudo)
  on conflict (user_id, md5(conteudo)) where ativo do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id
      from public.assistente_memorias
     where user_id = v_user and ativo and conteudo = v_conteudo;
    return jsonb_build_object('ok', true, 'ja_existia', true, 'id', v_id);
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- O prompt promete "se pedir para esquecer, o assistente esquece" — isto é o
-- que cumpre a promessa. Desativa (não apaga: a remoção definitiva fica no
-- painel, onde dá para ver o que está sendo removido).
create or replace function public.fn_memoria_esquecer_por_canal(
  p_identificador text,
  p_busca         text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user       uuid := public.fn_usuario_do_canal(p_identificador);
  v_padrao     text;
  v_qtd        integer;
  v_id         uuid;
  v_candidatas jsonb;
begin
  if trim(coalesce(p_busca, '')) = '' then
    return jsonb_build_object('ok', false, 'motivo', 'nao_encontrada');
  end if;

  v_padrao := '%' || public.fn_ilike_escapar(trim(p_busca)) || '%';

  select count(*),
         coalesce(jsonb_agg(jsonb_build_object('id', id, 'conteudo', left(conteudo, 120))), '[]'::jsonb)
    into v_qtd, v_candidatas
    from public.assistente_memorias
   where user_id = v_user and ativo and conteudo ilike v_padrao;

  if v_qtd = 0 then
    return jsonb_build_object('ok', false, 'motivo', 'nao_encontrada');
  elsif v_qtd > 1 then
    return jsonb_build_object('ok', false, 'motivo', 'ambigua', 'candidatas', v_candidatas);
  end if;

  update public.assistente_memorias
     set ativo = false
   where user_id = v_user and ativo and conteudo ilike v_padrao
  returning id into v_id;

  return jsonb_build_object('ok', true, 'esquecida', v_id);
end;
$$;

-- Cria ou atualiza um objetivo pelo título. Um match único atualiza
-- (progresso/data-alvo); nenhum match cria; mais de um devolve as candidatas.
create or replace function public.fn_objetivo_registrar_por_canal(
  p_identificador text,
  p_titulo        text,
  p_progresso     integer default null,
  p_alvo_data     date default null,
  p_area          text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user       uuid := public.fn_usuario_do_canal(p_identificador);
  v_titulo     text := trim(coalesce(p_titulo, ''));
  v_padrao     text;
  v_qtd        integer;
  v_id         uuid;
  v_candidatas jsonb;
  v_obj        record;
begin
  if v_titulo = '' or char_length(v_titulo) > 300 then
    return jsonb_build_object('ok', false, 'motivo', 'titulo_invalido');
  end if;

  if p_progresso is not null and (p_progresso < 0 or p_progresso > 100) then
    return jsonb_build_object('ok', false, 'motivo', 'progresso_fora_da_faixa');
  end if;

  v_padrao := '%' || public.fn_ilike_escapar(v_titulo) || '%';

  select count(*), coalesce(jsonb_agg(jsonb_build_object('id', id, 'titulo', titulo)), '[]'::jsonb)
    into v_qtd, v_candidatas
    from public.objetivos
   where user_id = v_user and status = 'ativo'
     and titulo ilike v_padrao;

  if v_qtd > 1 then
    return jsonb_build_object('ok', false, 'motivo', 'ambiguo', 'candidatas', v_candidatas);
  end if;

  if v_qtd = 1 then
    select id into v_id
      from public.objetivos
     where user_id = v_user and status = 'ativo'
       and titulo ilike v_padrao;

    update public.objetivos
       set progresso = coalesce(p_progresso, progresso),
           alvo_data = coalesce(p_alvo_data, alvo_data),
           area      = coalesce(p_area, area),
           status    = case when coalesce(p_progresso, progresso) >= 100
                            then 'alcancado'::public.status_objetivo
                            else status end
     where id = v_id
    returning id, titulo, progresso, alvo_data, status into v_obj;

    return jsonb_build_object('ok', true, 'atualizado', true, 'objetivo', to_jsonb(v_obj));
  end if;

  -- Nenhum ativo casou. Antes de criar, procura entre alcançados/pausados:
  -- um 100% registrado por engano precisa ter caminho de volta — sem isto, a
  -- correção ("na verdade é 10%") criaria um objetivo duplicado, e o errado
  -- ficaria "alcançado" para sempre.
  select count(*),
         coalesce(jsonb_agg(jsonb_build_object('id', id, 'titulo', titulo, 'status', status)), '[]'::jsonb)
    into v_qtd, v_candidatas
    from public.objetivos
   where user_id = v_user and status in ('alcancado', 'pausado')
     and titulo ilike v_padrao;

  if v_qtd > 1 then
    return jsonb_build_object('ok', false, 'motivo', 'ambiguo', 'candidatas', v_candidatas);
  end if;

  if v_qtd = 1 then
    select id into v_id
      from public.objetivos
     where user_id = v_user and status in ('alcancado', 'pausado')
       and titulo ilike v_padrao;

    update public.objetivos
       set progresso = coalesce(p_progresso, progresso),
           alvo_data = coalesce(p_alvo_data, alvo_data),
           area      = coalesce(p_area, area),
           status    = case when coalesce(p_progresso, progresso) >= 100
                            then 'alcancado'::public.status_objetivo
                            else 'ativo'::public.status_objetivo end
     where id = v_id
    returning id, titulo, progresso, alvo_data, status into v_obj;

    return jsonb_build_object('ok', true, 'reaberto', true, 'objetivo', to_jsonb(v_obj));
  end if;

  -- O INSERT respeita a mesma regra do UPDATE: nascer com 100 é nascer
  -- alcançado, não "ativo para sempre" no contexto.
  insert into public.objetivos (user_id, titulo, area, progresso, alvo_data, status)
  values (v_user, v_titulo, left(p_area, 100), coalesce(p_progresso, 0), p_alvo_data,
          case when coalesce(p_progresso, 0) >= 100
               then 'alcancado'::public.status_objetivo
               else 'ativo'::public.status_objetivo end)
  returning id, titulo, progresso, alvo_data, status into v_obj;

  return jsonb_build_object('ok', true, 'criado', true, 'objetivo', to_jsonb(v_obj));
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissões: só o n8n (service_role) alcança as funções de canal
-- ---------------------------------------------------------------------------

revoke all on function public.fn_assistente_contexto_por_canal(text)                                          from public, anon, authenticated;
revoke all on function public.fn_tarefa_criar_por_canal(text, text, date, public.prioridade_tarefa, text)     from public, anon, authenticated;
revoke all on function public.fn_tarefa_concluir_por_canal(text, text)                                        from public, anon, authenticated;
revoke all on function public.fn_memoria_salvar_por_canal(text, text, text)                                   from public, anon, authenticated;
revoke all on function public.fn_memoria_esquecer_por_canal(text, text)                                       from public, anon, authenticated;
revoke all on function public.fn_objetivo_registrar_por_canal(text, text, integer, date, text)                from public, anon, authenticated;

grant execute on function public.fn_assistente_contexto_por_canal(text)                                       to service_role;
grant execute on function public.fn_tarefa_criar_por_canal(text, text, date, public.prioridade_tarefa, text)  to service_role;
grant execute on function public.fn_tarefa_concluir_por_canal(text, text)                                     to service_role;
grant execute on function public.fn_memoria_salvar_por_canal(text, text, text)                                to service_role;
grant execute on function public.fn_memoria_esquecer_por_canal(text, text)                                    to service_role;
grant execute on function public.fn_objetivo_registrar_por_canal(text, text, integer, date, text)             to service_role;

comment on table public.assistente_memorias is
  'O que o assistente aprendeu sobre o usuário. É o "treinamento": permanente, e volta como contexto em toda conversa.';
comment on function public.fn_assistente_contexto_por_canal is
  'Contexto compacto do assistente pessoal: data, tarefas pendentes, objetivos, memórias e uma linha de finanças.';

commit;
