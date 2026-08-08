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
