#!/usr/bin/env node
/**
 * Concatena as migrations num arquivo único, para colar de uma vez no SQL
 * Editor do Supabase.
 *
 * As migrations continuam sendo a fonte da verdade — este bundle é derivado.
 * Rode `npm run db:bundle` depois de mexer em qualquer migration, senão o
 * arquivo gerado passa a mentir sobre o schema.
 */

import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const DIR = "supabase/migrations";
const SAIDA = "supabase/schema-completo.sql";

const arquivos = readdirSync(DIR)
  .filter((f) => f.endsWith(".sql"))
  // Ordem alfabética do nome do arquivo é a ordem de aplicação — o prefixo
  // de timestamp existe exatamente para isso.
  .sort();

if (arquivos.length === 0) {
  console.error(`Nenhuma migration encontrada em ${DIR}`);
  process.exit(1);
}

const partes = arquivos.map((nome) => {
  const conteudo = readFileSync(join(DIR, nome), "utf8").trimEnd();
  return [
    "-- " + "=".repeat(74),
    `-- ${nome}`,
    "-- " + "=".repeat(74),
    "",
    conteudo,
    "",
  ].join("\n");
});

const cabecalho = [
  "-- FinBR — schema completo.",
  "--",
  "-- ARQUIVO GERADO. Não edite aqui: mexa em supabase/migrations/ e rode",
  "--   npm run db:bundle",
  "--",
  `-- Origem: ${arquivos.length} migrations, nesta ordem:`,
  ...arquivos.map((f) => `--   ${f}`),
  "--",
  "-- Como usar: cole tudo no SQL Editor do Supabase e execute uma vez, num",
  "-- projeto com o schema public vazio. Rodar duas vezes falha no segundo",
  "-- CREATE TABLE — o que é o comportamento desejado, porque avisa que o",
  "-- schema já existe em vez de duplicar dado silenciosamente.",
  "",
  "begin;",
  "",
].join("\n");

const rodape = ["", "commit;", ""].join("\n");

writeFileSync(SAIDA, cabecalho + partes.join("\n") + rodape);

const linhas = (cabecalho + partes.join("\n") + rodape).split("\n").length;
console.log(`${SAIDA}: ${arquivos.length} migrations, ${linhas} linhas`);
