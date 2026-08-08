/**
 * Tipos do banco, escritos à mão.
 *
 * Assim que o projeto Supabase existir, dá para gerar automaticamente:
 *   npx supabase gen types typescript --project-id <ref> > src/types/supabase.ts
 * Até lá estes tipos espelham as migrations em supabase/migrations/.
 */

export type TipoConta = "corrente" | "poupanca" | "cartao_credito" | "investimento" | "carteira";

export type GrupoCategoria =
  | "receita"
  | "essencial"
  | "nao_essencial"
  | "divida"
  | "investimento"
  | "transferencia";

export type TipoDivida =
  | "cartao_credito"
  | "cheque_especial"
  | "emprestimo_pessoal"
  | "consignado"
  | "financiamento_veiculo"
  | "financiamento_imovel"
  | "credito_rotativo"
  | "parcelamento_fatura"
  | "conta_atrasada"
  | "agiota_informal"
  | "outro";

export type StatusDivida =
  | "ativa"
  | "em_atraso"
  | "em_negociacao"
  | "acordo_firmado"
  | "quitada"
  | "judicial";

export type EstrategiaQuitacao = "avalanche" | "bola_de_neve" | "personalizada";

export interface Perfil {
  id: string;
  nome: string | null;
  renda_mensal: number;
  aporte_extra_mensal: number;
  reserva_meta_meses: number;
}

export interface Conta {
  id: string;
  user_id: string;
  apelido: string;
  instituicao: string | null;
  tipo: TipoConta;
  banco_codigo: string | null;
  saldo_atual: number;
  ativa: boolean;
}

export interface Categoria {
  id: string;
  user_id: string | null;
  nome: string;
  grupo: GrupoCategoria;
  cor: string | null;
  icone: string | null;
}

export interface Transacao {
  id: string;
  user_id: string;
  conta_id: string;
  categoria_id: string | null;
  importacao_id: string | null;
  divida_id: string | null;
  data: string;
  descricao: string;
  descricao_normalizada: string;
  valor: number;
  tipo: "credito" | "debito";
  origem: "ofx" | "csv" | "manual" | "api";
  fitid: string | null;
  hash_dedupe: string | null;
  conciliada: boolean;
  observacao: string | null;
}

export interface Divida {
  id: string;
  user_id: string;
  credor: string;
  tipo: TipoDivida;
  status: StatusDivida;
  saldo_devedor: number;
  valor_original: number | null;
  taxa_juros_mensal: number;
  parcela_minima: number;
  parcelas_total: number | null;
  parcelas_pagas: number;
  dia_vencimento: number | null;
  dias_em_atraso: number;
  aceita_negociacao: boolean;
  em_orgao_protecao: boolean;
  ordem_prioridade: number | null;
  observacoes: string | null;
}

// --- Retornos das funções (fn_*) -------------------------------------------

export interface DividaSimulada {
  divida_id: string;
  credor: string;
  tipo: TipoDivida;
  saldo_inicial: number;
  taxa_mensal: number;
  parcela_minima: number;
  juros_pagos: number;
  total_pago: number;
  mes_quitacao: number | null;
  ordem_ataque: number;
}

export interface MesCronograma {
  mes: number;
  competencia: string;
  juros: number;
  pago: number;
  saldo_restante: number;
  quitadas: { divida_id: string; credor: string }[];
}

/** Resultado de `fn_simular_quitacao`. Discriminado por `viavel`. */
export type Simulacao =
  | {
      viavel: false;
      motivo: "orcamento_menor_que_juros";
      estrategia: EstrategiaQuitacao;
      aporte_extra: number;
      orcamento_mensal: number;
      juros_primeiro_mes: number;
      /** Quanto falta por mês só para a dívida parar de crescer. */
      deficit_mensal: number;
      saldo_total: number;
      cronograma: [];
    }
  | {
      viavel: true;
      sem_dividas?: boolean;
      estrategia: EstrategiaQuitacao;
      aporte_extra: number;
      orcamento_mensal: number;
      meses: number;
      data_liberdade: string;
      juros_total: number;
      pago_total: number;
      saldo_inicial: number;
      dividas: DividaSimulada[];
      cronograma: MesCronograma[];
    };

export interface ResumoMes {
  mes: string;
  receitas: number | null;
  despesas: number | null;
  despesas_essenciais: number | null;
  despesas_nao_essenciais: number | null;
  pagamento_dividas: number | null;
  resultado: number | null;
  qtd_transacoes: number;
}

export interface RaioX {
  gerado_em: string;
  perfil: {
    nome: string;
    renda_mensal: number;
    aporte_extra_mensal: number;
    reserva_meta_meses: number;
  };
  dividas_resumo: {
    qtd_dividas?: number;
    saldo_total?: number;
    parcela_minima_total?: number;
    juros_mensais?: number;
    maior_taxa?: number;
    qtd_em_atraso?: number;
    qtd_negativado?: number;
    qtd_negociaveis?: number;
  };
  indicadores: {
    comprometimento_renda: number | null;
    juros_mensais_perc_renda: number | null;
  };
  dividas: (Divida & { juros_mes: number })[];
  resumo_mensal: ResumoMes[];
  gastos_categoria_3m: { categoria: string; grupo: GrupoCategoria; total: number; qtd: number }[];
  cenarios: {
    avalanche: Simulacao;
    bola_de_neve: Simulacao;
  };
}
