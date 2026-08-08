const MOEDA = new Intl.NumberFormat("pt-BR", {
  style: "currency",
  currency: "BRL",
});

const MOEDA_COMPACTA = new Intl.NumberFormat("pt-BR", {
  style: "currency",
  currency: "BRL",
  notation: "compact",
  maximumFractionDigits: 1,
});

export function brl(valor: number | null | undefined): string {
  if (valor === null || valor === undefined || !Number.isFinite(valor)) return "—";
  return MOEDA.format(valor);
}

/** Para eixos de gráfico e cartões apertados: R$ 43,0 mil. */
export function brlCompacto(valor: number | null | undefined): string {
  if (valor === null || valor === undefined || !Number.isFinite(valor)) return "—";
  return MOEDA_COMPACTA.format(valor);
}

/** Taxa mensal decimal (0.135) para exibição ("13,50% a.m."). */
export function taxaMensal(decimal: number | null | undefined): string {
  if (decimal === null || decimal === undefined || !Number.isFinite(decimal)) return "—";
  return `${(decimal * 100).toLocaleString("pt-BR", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}% a.m.`;
}

/**
 * Juro anual equivalente à taxa mensal composta.
 * É esse número que mostra o tamanho real do rotativo: 13,5% a.m. = 358% a.a.
 */
export function taxaAnualEquivalente(mensal: number): number {
  return Math.pow(1 + mensal, 12) - 1;
}

export function percentual(valor: number | null | undefined, casas = 1): string {
  if (valor === null || valor === undefined || !Number.isFinite(valor)) return "—";
  return `${valor.toLocaleString("pt-BR", {
    minimumFractionDigits: casas,
    maximumFractionDigits: casas,
  })}%`;
}

/** `2026-03-15` → `15/03/2026`, sem passar por Date (evita salto de fuso). */
export function dataBr(iso: string | null | undefined): string {
  if (!iso) return "—";
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
  return m ? `${m[3]}/${m[2]}/${m[1]}` : iso;
}

/** `2026-03` → `mar/2026`. */
export function competenciaBr(competencia: string | null | undefined): string {
  if (!competencia) return "—";
  const m = /^(\d{4})-(\d{2})/.exec(competencia);
  if (!m) return competencia;

  const meses = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"];
  return `${meses[Number(m[2]) - 1]}/${m[1]}`;
}

/** "22 meses" → "1 ano e 10 meses". Prazo longo em meses não comunica nada. */
export function duracaoBr(meses: number | null | undefined): string {
  if (meses === null || meses === undefined || !Number.isFinite(meses)) return "—";
  if (meses === 0) return "agora";
  if (meses < 12) return `${meses} ${meses === 1 ? "mês" : "meses"}`;

  const anos = Math.floor(meses / 12);
  const resto = meses % 12;
  const parteAnos = `${anos} ${anos === 1 ? "ano" : "anos"}`;

  return resto === 0 ? parteAnos : `${parteAnos} e ${resto} ${resto === 1 ? "mês" : "meses"}`;
}
