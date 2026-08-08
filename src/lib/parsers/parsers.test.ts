import { describe, expect, it } from "vitest";

import { dataBrParaIso, parseCsv, valorBrParaNumero } from "./csv";
import { dataOfxParaIso, parseOfx, valorOfx } from "./ofx";
import { hashDedupe, normalizarDescricao } from "./normalizar";
import { ErroDeParse } from "./tipos";

describe("normalizarDescricao", () => {
  it("remove acentos, caixa e pontuação", () => {
    expect(normalizarDescricao("COMPRA CARTÃO — Padaria São José"))
      .toBe("compra cartao padaria sao jose");
  });

  it("descarta NSU, documento e datas embutidas", () => {
    expect(normalizarDescricao("PIX ENVIADO DOC 998877 12/03/2026 JOAO SILVA"))
      .toBe("pix enviado joao silva");
  });

  it("colapsa a parcela para que todo mês gere a mesma chave", () => {
    const p3 = normalizarDescricao("LOJAS AMERICANAS PARC 03/12");
    const p4 = normalizarDescricao("LOJAS AMERICANAS PARC 04/12");
    expect(p3).toBe(p4);
    expect(p3).toBe("lojas americanas");
  });

  it("mantém estável a mesma compra em dias diferentes", () => {
    expect(normalizarDescricao("MERCADO BOM PRECO NSU 445566"))
      .toBe(normalizarDescricao("MERCADO BOM PRECO NSU 998811"));
  });
});

describe("hashDedupe", () => {
  it("é determinístico", () => {
    expect(hashDedupe("2026-03-15", -149.9, "mercado")).toBe(
      hashDedupe("2026-03-15", -149.9, "mercado"),
    );
  });

  it("muda quando o valor muda", () => {
    expect(hashDedupe("2026-03-15", -149.9, "mercado")).not.toBe(
      hashDedupe("2026-03-15", -149.91, "mercado"),
    );
  });
});

describe("valorOfx", () => {
  it("aceita ponto e vírgula decimais", () => {
    expect(valorOfx("-149.90")).toBe(-149.9);
    expect(valorOfx("-149,90")).toBe(-149.9);
    expect(valorOfx("+2500.00")).toBe(2500);
  });

  it("rejeita lixo", () => {
    expect(valorOfx("abc")).toBeUndefined();
    expect(valorOfx("")).toBeUndefined();
  });
});

describe("dataOfxParaIso", () => {
  it("ignora hora e fuso, preservando a data-calendário do banco", () => {
    expect(dataOfxParaIso("20260315000000[-3:BRT]")).toBe("2026-03-15");
    expect(dataOfxParaIso("20260315")).toBe("2026-03-15");
    // 23:30 de 15/03 em BRT continua sendo 15/03, não 16/03 UTC.
    expect(dataOfxParaIso("20260315233000[-3:BRT]")).toBe("2026-03-15");
  });

  it("rejeita mês inválido", () => {
    expect(dataOfxParaIso("20261515")).toBeUndefined();
  });
});

const OFX_SGML = `OFXHEADER:100
DATA:OFXSGML
VERSION:102

<OFX>
<BANKMSGSRSV1><STMTTRNRS><STMTRS>
<CURDEF>BRL
<BANKACCTFROM><BANKID>341<ACCTID>12345-6<ACCTTYPE>CHECKING</BANKACCTFROM>
<BANKTRANLIST>
<DTSTART>20260301
<DTEND>20260331
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>20260315120000[-3:BRT]
<TRNAMT>-149.90
<FITID>2026031500001
<MEMO>COMPRA CARTAO MERCADO BOM PRECO NSU 445566
</STMTTRN>
<STMTTRN>
<TRNTYPE>CREDIT
<DTPOSTED>20260305000000[-3:BRT]
<TRNAMT>6000,00
<FITID>2026030500001
<NAME>SALARIO
<MEMO>CREDITO EM CONTA
</STMTTRN>
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>20260320
<TRNAMT>-89.00
<FITID>2026031500001
<MEMO>DUPLICADO PELO BANCO
</STMTTRN>
</BANKTRANLIST>
<LEDGERBAL><BALAMT>1234.56<DTASOF>20260331</LEDGERBAL>
</STMTRS></STMTTRNRS></BANKMSGSRSV1>
</OFX>`;

describe("parseOfx", () => {
  const r = parseOfx(OFX_SGML);

  it("lê OFX 1.x em SGML, com tags não fechadas", () => {
    expect(r.lancamentos).toHaveLength(2);
    expect(r.lancamentos[0].valor).toBe(-149.9);
    expect(r.lancamentos[0].fitid).toBe("2026031500001");
  });

  it("aceita vírgula decimal fora do padrão", () => {
    expect(r.lancamentos[1].valor).toBe(6000);
  });

  it("junta NAME e MEMO sem repetir", () => {
    expect(r.lancamentos[1].descricao).toBe("SALARIO — CREDITO EM CONTA");
  });

  it("descarta FITID repetido dentro do arquivo e avisa", () => {
    expect(r.avisos.some((a) => a.includes("FITID repetido"))).toBe(true);
  });

  it("extrai conta, saldo e período", () => {
    expect(r.conta.bancoCodigo).toBe("341");
    expect(r.conta.numeroConta).toBe("12345-6");
    expect(r.conta.saldo).toBe(1234.56);
    expect(r.periodoInicio).toBe("2026-03-01");
    expect(r.periodoFim).toBe("2026-03-31");
  });

  it("dá erro acionável quando o arquivo não é OFX", () => {
    expect(() => parseOfx("data;valor\n01/01/2026;10")).toThrow(ErroDeParse);
  });

  it("aceita OFX 2.x com tags fechadas", () => {
    const xml = OFX_SGML
      .replace(/<TRNAMT>(-?[\d.,]+)/g, "<TRNAMT>$1</TRNAMT>")
      .replace(/<DTPOSTED>([^\n]+)/g, "<DTPOSTED>$1</DTPOSTED>");
    expect(parseOfx(xml).lancamentos).toHaveLength(2);
  });
});

describe("valorBrParaNumero", () => {
  it("lê o formato brasileiro com milhar", () => {
    expect(valorBrParaNumero("R$ 1.234,56")).toBe(1234.56);
    expect(valorBrParaNumero("-1.234,56")).toBe(-1234.56);
  });

  it("lê o formato americano", () => {
    expect(valorBrParaNumero("1234.56")).toBe(1234.56);
  });

  it("não confunde milhar com decimal", () => {
    // 1.234 tem 3 dígitos após o ponto: é milhar, não decimal.
    expect(valorBrParaNumero("1.234")).toBe(1234);
    expect(valorBrParaNumero("1,234")).toBe(1234);
    expect(valorBrParaNumero("12,34")).toBe(12.34);
  });

  it("entende parênteses e sufixo D/C", () => {
    expect(valorBrParaNumero("(150,00)")).toBe(-150);
    expect(valorBrParaNumero("150,00 D")).toBe(-150);
    expect(valorBrParaNumero("150,00 C")).toBe(150);
  });

  it("rejeita texto", () => {
    expect(valorBrParaNumero("saldo")).toBeUndefined();
    expect(valorBrParaNumero("")).toBeUndefined();
  });
});

describe("dataBrParaIso", () => {
  it("aceita dd/mm/aaaa, dd/mm/aa e ISO", () => {
    expect(dataBrParaIso("15/03/2026")).toBe("2026-03-15");
    expect(dataBrParaIso("15/03/26")).toBe("2026-03-15");
    expect(dataBrParaIso("2026-03-15")).toBe("2026-03-15");
    expect(dataBrParaIso("5/3/2026")).toBe("2026-03-05");
  });

  it("rejeita data impossível", () => {
    expect(dataBrParaIso("32/13/2026")).toBeUndefined();
  });
});

describe("parseCsv", () => {
  it("lê CSV com ; preâmbulo e valor com sinal", () => {
    const csv = [
      "Extrato de Conta Corrente",
      "Agencia: 1234 Conta: 56789-0",
      "",
      "Data;Historico;Documento;Valor;Saldo",
      "05/03/2026;SALARIO EMPRESA XYZ;000123;6.000,00;6.000,00",
      "15/03/2026;COMPRA CARTAO MERCADO;000124;-149,90;5.850,10",
      "Saldo final;;;5.850,10",
    ].join("\n");

    const r = parseCsv(csv);
    expect(r.lancamentos).toHaveLength(2);
    expect(r.lancamentos[0].valor).toBe(6000);
    expect(r.lancamentos[1].valor).toBe(-149.9);
    expect(r.lancamentos[1].descricao).toBe("COMPRA CARTAO MERCADO");
  });

  it("lê layout com colunas Débito e Crédito separadas", () => {
    const csv = [
      "Data,Descrição,Débito,Crédito",
      "05/03/2026,Salário,,6000.00",
      "15/03/2026,Mercado,149.90,",
    ].join("\n");

    const r = parseCsv(csv);
    expect(r.lancamentos.map((l) => l.valor)).toEqual([6000, -149.9]);
  });

  it("respeita aspas com o delimitador dentro", () => {
    const csv = [
      "Data;Descricao;Valor",
      '15/03/2026;"MERCADO BOM PRECO; FILIAL 2";-149,90',
    ].join("\n");

    expect(parseCsv(csv).lancamentos[0].descricao).toBe("MERCADO BOM PRECO; FILIAL 2");
  });

  it("avisa que CSV não permite dedupe forte", () => {
    const csv = "Data;Descricao;Valor\n15/03/2026;X;-10,00";
    expect(parseCsv(csv).avisos.some((a) => a.includes("identificador único"))).toBe(true);
  });

  it("dá erro acionável quando não acha as colunas", () => {
    expect(() => parseCsv("foo;bar\n1;2")).toThrow(/colunas de data e valor/i);
  });
});
