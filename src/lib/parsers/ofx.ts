import { hashDedupe, normalizarDescricao } from "./normalizar";
import { ErroDeParse, type ContaDoArquivo, type LancamentoBruto, type ResultadoParse } from "./tipos";

/**
 * Parser de OFX (Open Financial Exchange).
 *
 * Os bancos brasileiros emitem quase sempre OFX 1.x, que é SGML e NÃO é XML:
 * as tags de valor não são fechadas.
 *
 *     <STMTTRN>
 *     <TRNTYPE>DEBIT
 *     <DTPOSTED>20260315120000[-3:BRT]
 *     <TRNAMT>-149.90
 *     <FITID>202603150001
 *     <MEMO>COMPRA CARTAO MERCADO BOM PRECO
 *     </STMTTRN>
 *
 * Por isso o parser é baseado em varredura de tags e não em DOMParser — jogar
 * isso num parser de XML dá erro de "tag não fechada" na primeira linha.
 * O OFX 2.x (XML de verdade, com tags fechadas) também passa aqui, porque
 * fechar a tag só antecipa o fim do valor.
 */

/** Lê o conteúdo de uma tag SGML/XML, parando na próxima tag ou quebra. */
function lerTag(bloco: string, tag: string): string | undefined {
  const re = new RegExp(`<${tag}>([^<\\r\\n]*)`, "i");
  const m = re.exec(bloco);
  const valor = m?.[1]?.trim();
  return valor ? valor : undefined;
}

/**
 * Converte data OFX para ISO.
 *
 * Formato: `YYYYMMDD[HHMMSS[.mmm]][[±h:TZ]]`. A parte de fuso é descartada de
 * propósito: para conciliação de extrato, o que vale é a data-calendário que o
 * banco carimbou, não o instante UTC. Converter fuso aqui empurraria
 * lançamentos da madrugada para o dia anterior.
 */
export function dataOfxParaIso(bruto: string): string | undefined {
  const m = /^(\d{4})(\d{2})(\d{2})/.exec(bruto.trim());
  if (!m) return undefined;

  const [, ano, mes, dia] = m;
  const a = Number(ano);
  const me = Number(mes);
  const d = Number(dia);

  if (me < 1 || me > 12 || d < 1 || d > 31 || a < 1900 || a > 2200) {
    return undefined;
  }

  return `${ano}-${mes}-${dia}`;
}

/**
 * Converte o valor monetário do OFX.
 *
 * O padrão manda ponto decimal, mas parte dos bancos brasileiros emite vírgula
 * (`-149,90`). Aceitamos os dois; o que nunca aparece em TRNAMT é separador de
 * milhar, então o último separador presente é sempre o decimal.
 */
export function valorOfx(bruto: string): number | undefined {
  const limpo = bruto.trim().replace(/\s/g, "").replace(",", ".");
  if (!/^[+-]?\d+(\.\d+)?$/.test(limpo)) return undefined;

  const n = Number(limpo);
  return Number.isFinite(n) ? n : undefined;
}

function extrairConta(texto: string): ContaDoArquivo {
  const conta: ContaDoArquivo = {
    bancoCodigo: lerTag(texto, "BANKID"),
    numeroConta: lerTag(texto, "ACCTID"),
    tipoConta: lerTag(texto, "ACCTTYPE"),
    moeda: lerTag(texto, "CURDEF"),
  };

  // <LEDGERBAL> traz o saldo consolidado no fim do período.
  const ledger = /<LEDGERBAL>([\s\S]*?)(?:<\/LEDGERBAL>|<\/STMTRS>|$)/i.exec(texto);
  if (ledger) {
    const bal = lerTag(ledger[1], "BALAMT");
    const em = lerTag(ledger[1], "DTASOF");
    if (bal) conta.saldo = valorOfx(bal);
    if (em) conta.saldoEm = dataOfxParaIso(em);
  }

  return conta;
}

export function parseOfx(conteudo: string): ResultadoParse {
  // BOM em arquivo salvo no Windows quebra o match da primeira tag.
  const texto = conteudo.replace(/^\uFEFF/, "");
  const avisos: string[] = [];

  if (!/<OFX>/i.test(texto)) {
    throw new ErroDeParse(
      "O arquivo não parece ser um OFX.",
      "Confira se você baixou o extrato no formato OFX (às vezes aparece como 'Money' ou 'OFX/Money' no site do banco).",
    );
  }

  const blocos = texto.match(/<STMTTRN>[\s\S]*?<\/STMTTRN>/gi) ?? [];

  if (blocos.length === 0) {
    throw new ErroDeParse(
      "O OFX foi lido, mas não contém nenhum lançamento.",
      "Verifique se o período selecionado no banco realmente tem movimentação.",
    );
  }

  const lancamentos: LancamentoBruto[] = [];
  const fitidsVistos = new Set<string>();
  let semFitid = 0;
  let duplicadosNoArquivo = 0;

  for (const bloco of blocos) {
    const dtRaw = lerTag(bloco, "DTPOSTED") ?? lerTag(bloco, "DTUSER");
    const vlRaw = lerTag(bloco, "TRNAMT");

    const data = dtRaw ? dataOfxParaIso(dtRaw) : undefined;
    const valor = vlRaw ? valorOfx(vlRaw) : undefined;

    if (!data || valor === undefined) {
      avisos.push(
        `Lançamento ignorado por data ou valor ilegível (data="${dtRaw ?? "?"}", valor="${vlRaw ?? "?"}").`,
      );
      continue;
    }

    // Valor zero em OFX costuma ser linha de controle do banco, não movimento.
    if (valor === 0) continue;

    // MEMO é o campo livre; NAME é o nome da contraparte. Bancos diferentes
    // preenchem um ou outro, então juntamos o que houver sem repetir.
    const memo = lerTag(bloco, "MEMO");
    const name = lerTag(bloco, "NAME");
    const descricao =
      [name, memo].filter(Boolean).filter((v, i, a) => a.indexOf(v) === i).join(" — ") ||
      lerTag(bloco, "TRNTYPE") ||
      "Lançamento sem descrição";

    const fitid = lerTag(bloco, "FITID");

    if (!fitid) {
      semFitid++;
    } else if (fitidsVistos.has(fitid)) {
      // O banco repetiu o mesmo FITID no arquivo. Como o par (conta, FITID) é
      // único no banco de dados, importar os dois quebraria a inserção — e o
      // certo é ficar com um só mesmo.
      duplicadosNoArquivo++;
      continue;
    } else {
      fitidsVistos.add(fitid);
    }

    const descricaoNormalizada = normalizarDescricao(descricao);

    lancamentos.push({
      data,
      descricao,
      descricaoNormalizada,
      valor,
      fitid,
      documento: lerTag(bloco, "CHECKNUM"),
      hashDedupe: hashDedupe(data, valor, descricaoNormalizada),
    });
  }

  if (lancamentos.length === 0) {
    throw new ErroDeParse(
      "Nenhum lançamento do arquivo pôde ser lido.",
      "O arquivo pode estar corrompido ou truncado. Tente baixar de novo pelo banco.",
    );
  }

  if (semFitid > 0) {
    avisos.push(
      `${semFitid} lançamento(s) sem FITID. Sem esse identificador, reimportar o mesmo extrato pode duplicar — confira a revisão antes de confirmar.`,
    );
  }

  if (duplicadosNoArquivo > 0) {
    avisos.push(
      `${duplicadosNoArquivo} lançamento(s) com FITID repetido dentro do próprio arquivo foram descartados.`,
    );
  }

  const datas = lancamentos.map((l) => l.data).sort();

  return {
    formato: "ofx",
    conta: extrairConta(texto),
    lancamentos,
    periodoInicio: lerTag(texto, "DTSTART")
      ? dataOfxParaIso(lerTag(texto, "DTSTART")!)
      : datas[0],
    periodoFim: lerTag(texto, "DTEND")
      ? dataOfxParaIso(lerTag(texto, "DTEND")!)
      : datas[datas.length - 1],
    avisos,
  };
}
