/**
 * Normalização de descrição de lançamento.
 *
 * Extrato bancário brasileiro vem cheio de ruído que muda a cada linha —
 * NSU, número de documento, data embutida, código de autorização. Se as regras
 * de categorização casassem contra a descrição crua, cada compra no mesmo
 * mercado viraria uma string diferente e nenhuma regra pegaria duas vezes.
 *
 * O que sobra depois daqui é o miolo estável: "compra cartao mercado bom preco".
 */

// A ORDEM importa: cada regra consome o texto que casa, então as mais
// específicas vêm primeiro. Parcelamento antes de data, senão o padrão de data
// engole o "03/12" e sobra um "parc" órfão na chave.
const RUIDOS: RegExp[] = [
  // Parcelamento: "parc 03/12", "parcela 3 de 12". O número da parcela muda
  // todo mês, então ele não pode entrar na chave de categorização.
  /\bparc(?:ela)?\s*\d{1,2}\s*(?:\/|de)\s*\d{1,2}\b/gi,
  // Rótulos de identificador seguidos do número.
  /\b(nsu|doc|documento|aut|autoriz(?:acao)?|ref|referencia|cod|codigo|id|protocolo)\b[\s.:#-]*\w+/g,
  // Datas embutidas: 12/03, 12/03/2026, 12-03-26.
  /\b\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?\b/g,
  // Horas: 14:35, 14:35:02.
  /\b\d{1,2}:\d{2}(?::\d{2})?\b/g,
  // Sequências longas de dígitos (contas, cartões mascarados, NSU solto).
  /\b\d{6,}\b/g,
  // Cartão mascarado: ****1234, xxxx1234.
  /\b[*x]{2,}\s*\d{2,4}\b/gi,
];

/** Remove acentos preservando as letras (NFD + corte dos diacríticos). */
export function semAcento(texto: string): string {
  return texto.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
}

export function normalizarDescricao(descricao: string): string {
  let saida = semAcento(descricao).toLowerCase();

  for (const ruido of RUIDOS) {
    saida = saida.replace(ruido, " ");
  }

  return saida
    // Tudo que não é letra, dígito ou espaço vira espaço.
    .replace(/[^a-z0-9\s]/g, " ")
    // Dígitos soltos remanescentes não ajudam a identificar o estabelecimento.
    .replace(/\b\d{1,5}\b/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Impressão digital para detectar reimportação do mesmo CSV.
 *
 * Não é identidade: duas compras iguais no mesmo dia produzem o mesmo hash e
 * são ambas legítimas. Serve para a tela de revisão sinalizar "isso parece
 * repetido", nunca para descartar linha sozinha.
 */
export function hashDedupe(
  data: string,
  valor: number,
  descricaoNormalizada: string,
): string {
  const base = `${data}|${valor.toFixed(2)}|${descricaoNormalizada}`;

  // FNV-1a 32 bits: barato, sem dependência, e colisão aqui só causa um aviso
  // falso na revisão — não perde nem sobrescreve dado.
  let h = 0x811c9dc5;
  for (let i = 0; i < base.length; i++) {
    h ^= base.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }

  return (h >>> 0).toString(16).padStart(8, "0");
}
