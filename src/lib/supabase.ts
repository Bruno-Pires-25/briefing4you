import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL;
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;

if (!url || !key) {
  // Falhar aqui, no boot, é melhor do que deixar cada query estourar um 401
  // genérico depois — o erro aponta direto para o .env que falta.
  throw new Error(
    "VITE_SUPABASE_URL e VITE_SUPABASE_PUBLISHABLE_KEY não estão definidas. Copie .env.example para .env e preencha.",
  );
}

export const supabase = createClient(url, key, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
});

/**
 * A chave publishable é pública por natureza — ela vai no bundle do navegador.
 * O que impede um usuário de ler os dados de outro é a RLS do banco, não o
 * sigilo desta chave. Por isso nenhuma tabela pode ficar sem policy.
 */
