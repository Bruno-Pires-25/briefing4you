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
