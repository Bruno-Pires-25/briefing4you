import { hashDedupe, normalizarDescricao, semAcento } from "./normalizar";
import { ErroDeParse, type LancamentoBruto, type ResultadoParse } from "./tipos";

/**
 * Parser de CSV de extrato bancário brasileiro.
 *
 * Não existe padrão: cada banco escolhe o delimitador (`;` é o mais comum aqui,
 * porque a vírgula já é o separador decimal), o formato de data, e se manda
 * uma coluna `Valor` com sinal ou duas colunas `Débito`/`Crédito`. Vários
 * ainda jogam linhas de cabeçalho institucional antes da tabela.
 *
 * A estratégia é detectar tudo isso a partir do conteúdo, em vez de exigir que
 * o usuário formate o arquivo.
 */

const ALIAS_DATA = ["data", "data lancamento", "data do lancamento", "dt", "data mov", "data movimento", "data da compra"];
const ALIAS_DESCRICAO = ["descricao", "historico", "lancamento", "detalhe", "movimentacao", "estabelecimento", "titulo", "memo"];
const ALIAS_VALOR = ["valor", "valor r", "montante", "quantia", "valor da compra", "amount"];
const ALIAS_DEBITO = ["debito", "saida", "pagamento", "valor debito"];
const ALIAS_CREDITO = ["credito", "entrada", "recebimento", "valor credito"];
const ALIAS_DOC = ["documento", "doc", "numero do documento", "num doc", "nsu"];

/** Divide uma linha respeitando aspas duplas (com `""` como aspa escapada). */
function dividirLinha(linha: string, delim: string): string[] {
  const campos: string[] = [];
  let atual = "";
  let dentroDeAspas = false;

  for (let i = 0; i < linha.length; i++) {
    const c = linha[i];

    if (dentroDeAspas) {
      if (c === '"') {
        if (linha[i + 1] === '"') {
          atual += '"';
          i++;
        } else {
          dentroDeAspas = false;
        }
      } else {
        atual += c;
      }
      continue;
    }

    if (c === '"') {
      dentroDeAspas = true;
    } else if (c === delim) {
      campos.push(atual.trim());
      atual = "";
    } else {
      atual += c;
    }
  }

  campos.push(atual.trim());
  return campos;
}

/**
 * Detecta o delimitador pelo que produz mais colunas de forma CONSISTENTE.
 * Contar ocorrências puras erraria: `1.234,56` infla a contagem de vírgulas.
 */
function detectarDelimitador(linhas: string[]): string {
  const candidatos = [";", ",", "\t", "|"];
  let melhor = ";";
  let melhorNota = -1;

  for (const delim of candidatos) {
    const contagens = linhas.slice(0, 20).map((l) => dividirLinha(l, delim).length);
    const max = Math.max(...contagens);
    if (max < 2) continue;

    // Nota = nº de colunas, penalizado pela variação entre as linhas.
    const consistentes = contagens.filter((c) => c === max).length;
    const nota = max * 10 + consistentes;

    if (nota > melhorNota) {
      melhorNota = nota;
      melhor = delim;
    }
  }

  return melhor;
}

function casaAlias(cabecalho: string, aliases: string[]): boolean {
  const limpo = semAcento(cabecalho).toLowerCase().replace(/[^a-z\s]/g, " ").replace(/\s+/g, " ").trim();
  return aliases.some((a) => limpo === a || limpo.startsWith(a + " ") || limpo === a.replace(/\s/g, ""));
}

/** Acha a linha que é de fato o cabeçalho da tabela, pulando o preâmbulo. */
function acharCabecalho(linhas: string[], delim: string): number {
  for (let i = 0; i < Math.min(linhas.length, 30); i++) {
    const cols = dividirLinha(linhas[i], delim);
    if (cols.length < 2) continue;

    const temData = cols.some((c) => casaAlias(c, ALIAS_DATA));
    const temValor = cols.some(
      (c) => casaAlias(c, ALIAS_VALOR) || casaAlias(c, ALIAS_DEBITO) || casaAlias(c, ALIAS_CREDITO),
    );

    if (temData && temValor) return i;
  }

  return -1;
}

/**
 * Converte data brasileira ou ISO para `YYYY-MM-DD`.
 * Ano com 2 dígitos vira 20xx — extrato bancário de 1970 não existe na prática.
 */
export function dataBrParaIso(bruto: string): string | undefined {
  const t = bruto.trim();

  const iso = /^(\d{4})-(\d{2})-(\d{2})/.exec(t);
  if (iso) return `${iso[1]}-${iso[2]}-${iso[3]}`;

  const br = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})$/.exec(t);
  if (!br) return undefined;

  const dia = Number(br[1]);
  const mes = Number(br[2]);
  let ano = Number(br[3]);

  if (br[3].length === 2) ano += 2000;
  if (mes < 1 || mes > 12 || dia < 1 || dia > 31) return undefined;

  return `${String(ano).padStart(4, "0")}-${String(mes).padStart(2, "0")}-${String(dia).padStart(2, "0")}`;
}

/**
 * Converte valor monetário brasileiro.
 *
 * Trata `R$ 1.234,56`, `1234.56`, `(150,00)` (negativo contábil) e `150,00 D`
 * (sufixo de débito usado por alguns bancos). A regra para decidir qual
 * separador é o decimal: o ÚLTIMO que aparecer, desde que seguido de 1 ou 2
 * dígitos — assim `1.234` (mil e duzentos) não vira `1,234`.
 */
export function valorBrParaNumero(bruto: string): number | undefined {
  let t = bruto.trim();
  if (!t) return undefined;

  let sinal = 1;

  // Parênteses = negativo na notação contábil.
  if (/^\(.*\)$/.test(t)) {
    sinal = -1;
    t = t.slice(1, -1);
  }

  // Sufixo D (débito) / C (crédito).
  const sufixo = /\s([DC])$/i.exec(t);
  if (sufixo) {
    if (sufixo[1].toUpperCase() === "D") sinal = -1;
    t = t.slice(0, sufixo.index);
  }

  t = t.replace(/R\$/gi, "").replace(/\s/g, "").trim();

  if (t.startsWith("-")) {
    sinal *= -1;
    t = t.slice(1);
  } else if (t.startsWith("+")) {
    t = t.slice(1);
  }

  if (!/^[\d.,]+$/.test(t) || !/\d/.test(t)) return undefined;

  const ultimaVirgula = t.lastIndexOf(",");
  const ultimoPonto = t.lastIndexOf(".");
  const posDecimal = Math.max(ultimaVirgula, ultimoPonto);

  let inteiro = t;
  let decimais = "";

  // Só é separador decimal se sobrarem no máximo 2 dígitos depois dele.
  if (posDecimal >= 0 && t.length - posDecimal - 1 <= 2 && t.length - posDecimal - 1 > 0) {
    inteiro = t.slice(0, posDecimal);
    decimais = t.slice(posDecimal + 1);
  }

  inteiro = inteiro.replace(/[.,]/g, "");
  if (!/^\d*$/.test(inteiro) || !/^\d*$/.test(decimais)) return undefined;

  const n = Number(`${inteiro || "0"}.${decimais || "0"}`);
  return Number.isFinite(n) ? sinal * n : undefined;
}

export function parseCsv(conteudo: string): ResultadoParse {
  const linhas = conteudo
    .replace(/^\uFEFF/, "")
    .split(/\r\n|\n|\r/)
    .filter((l) => l.trim() !== "");

  if (linhas.length < 2) {
    throw new ErroDeParse(
      "O arquivo CSV está vazio ou tem apenas uma linha.",
      "Baixe o extrato novamente selecionando um período com movimentação.",
    );
  }

  const delim = detectarDelimitador(linhas);
  const iCab = acharCabecalho(linhas, delim);

  if (iCab === -1) {
    throw new ErroDeParse(
      "Não encontrei as colunas de data e valor no CSV.",
      "O arquivo precisa ter uma linha de cabeçalho com algo como 'Data' e 'Valor' (ou 'Débito'/'Crédito'). Se o seu banco exporta em outro layout, use o OFX.",
    );
  }

  const cabecalho = dividirLinha(linhas[iCab], delim);
  const acharCol = (aliases: string[]) => cabecalho.findIndex((c) => casaAlias(c, aliases));

  const colData = acharCol(ALIAS_DATA);
  const colDescricao = acharCol(ALIAS_DESCRICAO);
  const colValor = acharCol(ALIAS_VALOR);
  const colDebito = acharCol(ALIAS_DEBITO);
  const colCredito = acharCol(ALIAS_CREDITO);
  const colDoc = acharCol(ALIAS_DOC);

  if (colValor === -1 && colDebito === -1 && colCredito === -1) {
    throw new ErroDeParse(
      "O CSV não tem coluna de valor reconhecível.",
      `Colunas encontradas: ${cabecalho.join(", ")}.`,
    );
  }

  const avisos: string[] = [];
  const lancamentos: LancamentoBruto[] = [];
  let ignoradas = 0;

  for (let i = iCab + 1; i < linhas.length; i++) {
    const cols = dividirLinha(linhas[i], delim);

    // Linhas de rodapé ("Saldo final", totalizadores) têm menos colunas.
    if (cols.length < cabecalho.length - 1) {
      ignoradas++;
      continue;
    }

    const data = dataBrParaIso(cols[colData] ?? "");
    if (!data) {
      ignoradas++;
      continue;
    }

    let valor: number | undefined;

    if (colValor !== -1) {
      valor = valorBrParaNumero(cols[colValor] ?? "");
    } else {
      // Layout com colunas separadas: débito é saída, crédito é entrada.
      const deb = colDebito !== -1 ? valorBrParaNumero(cols[colDebito] ?? "") : undefined;
      const cred = colCredito !== -1 ? valorBrParaNumero(cols[colCredito] ?? "") : undefined;

      if (deb !== undefined && deb !== 0) valor = -Math.abs(deb);
      else if (cred !== undefined && cred !== 0) valor = Math.abs(cred);
    }

    if (valor === undefined || valor === 0) {
      ignoradas++;
      continue;
    }

    const descricao = (colDescricao !== -1 ? cols[colDescricao] : "")?.trim() || "Lançamento sem descrição";
    const descricaoNormalizada = normalizarDescricao(descricao);

    lancamentos.push({
      data,
      descricao,
      descricaoNormalizada,
      valor,
      documento: colDoc !== -1 ? cols[colDoc] || undefined : undefined,
      hashDedupe: hashDedupe(data, valor, descricaoNormalizada),
    });
  }

  if (lancamentos.length === 0) {
    throw new ErroDeParse(
      "Nenhuma linha do CSV pôde ser interpretada como lançamento.",
      "Confira se as datas estão em dd/mm/aaaa e se a coluna de valor tem números.",
    );
  }

  if (ignoradas > 0) {
    avisos.push(
      `${ignoradas} linha(s) foram puladas por não terem data ou valor válidos (normalmente cabeçalho extra, saldo ou rodapé).`,
    );
  }

  // CSV não tem FITID. A reimportação do mesmo arquivo não é bloqueada pelo
  // banco de dados, então o usuário precisa saber disso antes de confirmar.
  avisos.push(
    "CSV não traz identificador único de transação. Se você já importou este período, revise os itens marcados como possível duplicata.",
  );

  const datas = lancamentos.map((l) => l.data).sort();

  return {
    formato: "csv",
    conta: {},
    lancamentos,
    periodoInicio: datas[0],
    periodoFim: datas[datas.length - 1],
    avisos,
  };
}
