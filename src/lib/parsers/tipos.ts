/** Uma linha de extrato já normalizada, pronta para virar `transacoes`. */
export interface LancamentoBruto {
  /** ISO `YYYY-MM-DD`. */
  data: string;
  descricao: string;
  descricaoNormalizada: string;
  /** Positivo entra, negativo sai. Sempre em BRL. */
  valor: number;
  /** FITID do OFX. Ausente em CSV. */
  fitid?: string;
  hashDedupe: string;
  /** Nº do cheque/documento, quando o arquivo traz. */
  documento?: string;
}

/** Metadados da conta declarados pelo próprio arquivo. */
export interface ContaDoArquivo {
  /** Código Febraban do banco (001 BB, 237 Bradesco, 260 Nubank...). */
  bancoCodigo?: string;
  numeroConta?: string;
  tipoConta?: string;
  moeda?: string;
  saldo?: number;
  saldoEm?: string;
}

export interface ResultadoParse {
  formato: "ofx" | "csv";
  conta: ContaDoArquivo;
  lancamentos: LancamentoBruto[];
  periodoInicio?: string;
  periodoFim?: string;
  /** Problemas que não impedem a importação, mas o usuário deve ver. */
  avisos: string[];
}

export class ErroDeParse extends Error {
  constructor(
    message: string,
    /** Texto acionável: o que o usuário deve fazer a respeito. */
    readonly sugestao?: string,
  ) {
    super(message);
    this.name = "ErroDeParse";
  }
}
