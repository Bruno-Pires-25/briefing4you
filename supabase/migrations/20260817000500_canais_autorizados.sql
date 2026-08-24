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
