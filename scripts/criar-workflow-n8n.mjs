#!/usr/bin/env node
/**
 * Cria (ou atualiza) um workflow no n8n via API pública, já com os
 * placeholders substituídos pelas credenciais do ambiente.
 *
 *   node scripts/criar-workflow-n8n.mjs n8n/agente-whatsapp.json
 *
 * Variáveis lidas do ambiente (ou de um .env.n8n na raiz):
 *
 *   N8N_URL                    https://seu-n8n.com   (sem barra no fim)
 *   N8N_API_KEY                Settings -> n8n API
 *
 *   SUPABASE_URL               https://xxx.supabase.co
 *   SUPABASE_SERVICE_ROLE_KEY  Settings -> API -> service_role
 *   EVOLUTION_URL              https://sua-evolution.com
 *   EVOLUTION_INSTANCE         nome da instância
 *   EVOLUTION_APIKEY           apikey da Evolution
 *   GROQ_API_KEY               console.groq.com (transcrição de áudio)
 *   ANTHROPIC_API_KEY          só informativo — a credencial do modelo é
 *                              criada na interface do n8n, não pela API
 *
 * O que este script NÃO faz: criar as credenciais do nó Anthropic e do
 * Postgres. A API pública do n8n não expõe isso de forma estável entre
 * versões, então esses dois ficam para dois cliques na interface.
 */

import { readFileSync, existsSync } from "node:fs";

// ---------------------------------------------------------------------------
// Ambiente
// ---------------------------------------------------------------------------

function carregarEnvArquivo(caminho) {
  if (!existsSync(caminho)) return;

  for (const linha of readFileSync(caminho, "utf8").split("\n")) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(linha);
    if (!m) continue;
    // Só preenche o que não veio do ambiente — variável exportada ganha do
    // arquivo, que é o comportamento que as pessoas esperam.
    if (process.env[m[1]] === undefined) {
      process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
    }
  }
}

carregarEnvArquivo(".env.n8n");

const env = (nome, obrigatoria = true) => {
  const v = process.env[nome];
  if (!v && obrigatoria) {
    console.error(`\nFalta a variável ${nome}.`);
    console.error("Defina no ambiente ou num arquivo .env.n8n na raiz do projeto.");
    console.error("O cabeçalho de scripts/criar-workflow-n8n.mjs lista todas.\n");
    process.exit(1);
  }
  return v ?? "";
};

// ---------------------------------------------------------------------------
// Substituição dos placeholders
// ---------------------------------------------------------------------------

const arquivo = process.argv[2] ?? "n8n/agente-whatsapp.json";
if (!existsSync(arquivo)) {
  console.error(`Arquivo não encontrado: ${arquivo}`);
  process.exit(1);
}

const N8N_URL = env("N8N_URL").replace(/\/+$/, "");
const N8N_API_KEY = env("N8N_API_KEY");

const SUBSTITUICOES = {
  "https://SEU_PROJECT_REF.supabase.co": env("SUPABASE_URL"),
  "https://hxclrrcuqsduymgmbhph.supabase.co": env("SUPABASE_URL"),
  SUA_SERVICE_ROLE_KEY: env("SUPABASE_SERVICE_ROLE_KEY"),
  SUA_PUBLISHABLE_KEY: process.env.SUPABASE_PUBLISHABLE_KEY ?? "",
  "https://SEU_EVOLUTION": env("EVOLUTION_URL", false),
  SUA_INSTANCIA: env("EVOLUTION_INSTANCE", false),
  SUA_APIKEY_EVOLUTION: env("EVOLUTION_APIKEY", false),
  SUA_GROQ_API_KEY: env("GROQ_API_KEY", false),
};

let bruto = readFileSync(arquivo, "utf8");
const trocados = [];

for (const [de, para] of Object.entries(SUBSTITUICOES)) {
  if (!para || !bruto.includes(de)) continue;
  bruto = bruto.split(de).join(para);
  trocados.push(de);
}

const wf = JSON.parse(bruto);

// Placeholder que sobrou vira workflow quebrado em produção, e o erro só
// aparece na primeira mensagem real. Melhor barrar agora.
const restantes = [...bruto.matchAll(/\b(SUA?_[A-Z_]+|SEU_[A-Z_]+)\b/g)]
  .map((m) => m[1])
  .filter((v, i, a) => a.indexOf(v) === i);

if (restantes.length > 0) {
  console.error(`\nAinda há placeholders sem valor: ${restantes.join(", ")}`);
  console.error("Preencha as variáveis correspondentes antes de criar o workflow.\n");
  process.exit(1);
}

// ---------------------------------------------------------------------------
// API do n8n
// ---------------------------------------------------------------------------

const api = async (caminho, opcoes = {}) => {
  const resp = await fetch(`${N8N_URL}/api/v1${caminho}`, {
    ...opcoes,
    headers: {
      "X-N8N-API-KEY": N8N_API_KEY,
      "Content-Type": "application/json",
      ...(opcoes.headers ?? {}),
    },
  });

  const texto = await resp.text();
  let corpo;
  try {
    corpo = texto ? JSON.parse(texto) : null;
  } catch {
    corpo = texto;
  }

  if (!resp.ok) {
    const erro = new Error(
      `n8n respondeu ${resp.status}: ${typeof corpo === "string" ? corpo : JSON.stringify(corpo)}`,
    );
    erro.status = resp.status;
    throw erro;
  }

  return corpo;
};

// A API de criação rejeita o corpo inteiro se vier campo a mais
// ("must NOT have additional properties"), então mandamos só o que ela aceita.
const corpoCriacao = {
  name: wf.name,
  nodes: wf.nodes,
  connections: wf.connections,
  settings: wf.settings ?? { executionOrder: "v1" },
};

console.log(`n8n:        ${N8N_URL}`);
console.log(`workflow:   ${wf.name}`);
console.log(`nós:        ${wf.nodes.length}`);
console.log(`preenchido: ${trocados.length} placeholder(s)`);
console.log("");

try {
  const existentes = await api("/workflows?limit=250");
  const igual = (existentes.data ?? []).find((w) => w.name === wf.name);

  if (igual) {
    console.log(`Já existe um workflow com esse nome (id ${igual.id}). Atualizando.`);
    const atualizado = await api(`/workflows/${igual.id}`, {
      method: "PUT",
      body: JSON.stringify(corpoCriacao),
    });
    console.log(`\nAtualizado: ${N8N_URL}/workflow/${atualizado.id}`);
  } else {
    const criado = await api("/workflows", {
      method: "POST",
      body: JSON.stringify(corpoCriacao),
    });
    console.log(`\nCriado: ${N8N_URL}/workflow/${criado.id}`);
  }

  console.log("\nFalta fazer na interface, uma vez:");
  console.log("  1. Nó 'Claude Haiku'  -> credencial Anthropic API");
  console.log("  2. Nó 'Memória...'    -> credencial Postgres (Supabase, modo Session)");
  console.log("  3. Ativar o workflow e copiar a Production URL do webhook");
} catch (erro) {
  if (erro.status === 401) {
    console.error("\n401: a API key do n8n foi recusada. Gere outra em Settings -> n8n API.");
  } else if (erro.status === 404) {
    console.error("\n404: a URL não parece ser um n8n, ou a API pública está desabilitada.");
    console.error("A API pública exige plano/licença que a habilite em algumas versões.");
  } else {
    console.error(`\n${erro.message}`);
  }
  process.exit(1);
}
