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
