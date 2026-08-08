import { parseCsv } from "./csv";
import { parseOfx } from "./ofx";
import { ErroDeParse, type ResultadoParse } from "./tipos";

export * from "./tipos";
export { normalizarDescricao, hashDedupe } from "./normalizar";
export { parseCsv } from "./csv";
export { parseOfx } from "./ofx";

/**
 * Lê o arquivo respeitando a codificação declarada.
 *
 * Bancos brasileiros ainda exportam muito OFX em ISO-8859-1 (Latin-1). Lido
 * como UTF-8, "SALÁRIO" vira "SAL�RIO" e a descrição fica quebrada para
 * sempre no banco. O cabeçalho do OFX declara o charset — usamos ele.
 */
async function lerTexto(arquivo: File): Promise<string> {
  const buffer = await arquivo.arrayBuffer();

  // O cabeçalho OFX é ASCII puro, então decodificar como Latin-1 para inspecionar
  // é seguro qualquer que seja a codificação real do corpo.
  const espiada = new TextDecoder("iso-8859-1").decode(buffer.slice(0, 512));
  const charset = /CHARSET:\s*([\w-]+)/i.exec(espiada)?.[1]?.toUpperCase();
  const encoding = /ENCODING:\s*([\w-]+)/i.exec(espiada)?.[1]?.toUpperCase();

  const ehLatin1 =
    charset === "1252" ||
    charset === "8859-1" ||
    charset === "ISO-8859-1" ||
    encoding === "USASCII";

  if (ehLatin1) return new TextDecoder("windows-1252").decode(buffer);

  const utf8 = new TextDecoder("utf-8").decode(buffer);

  // Sem declaração de charset, o sinal de que erramos é o caractere de
  // substituição. Nesse caso Latin-1 é o palpite certo no contexto brasileiro.
  if (utf8.includes("�")) {
    return new TextDecoder("windows-1252").decode(buffer);
  }

  return utf8;
}

export async function lerArquivoDeExtrato(arquivo: File): Promise<ResultadoParse> {
  const texto = await lerTexto(arquivo);
  const nome = arquivo.name.toLowerCase();

  // A extensão é só uma dica: gente renomeia arquivo. O conteúdo decide.
  if (/<OFX>/i.test(texto)) return parseOfx(texto);
  if (nome.endsWith(".ofx")) return parseOfx(texto);
  if (nome.endsWith(".csv") || nome.endsWith(".txt")) return parseCsv(texto);

  throw new ErroDeParse(
    "Não reconheci o formato do arquivo.",
    "Use um extrato em OFX ou CSV baixado direto do seu banco.",
  );
}
