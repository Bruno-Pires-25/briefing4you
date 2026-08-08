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
