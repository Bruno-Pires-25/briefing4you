import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { supabase } from "@/lib/supabase";
import type {
  Categoria,
  Conta,
  Divida,
  EstrategiaQuitacao,
  Perfil,
  RaioX,
  Simulacao,
  Transacao,
} from "@/types/db";

export function usePerfil() {
  return useQuery({
    queryKey: ["perfil"],
    queryFn: async (): Promise<Perfil> => {
      const { data, error } = await supabase.from("perfis").select("*").single();
      if (error) throw error;
      return data as Perfil;
    },
  });
}

export function useContas() {
  return useQuery({
    queryKey: ["contas"],
    queryFn: async (): Promise<Conta[]> => {
      const { data, error } = await supabase
        .from("contas")
        .select("*")
        .eq("ativa", true)
        .order("apelido");
      if (error) throw error;
      return (data ?? []) as Conta[];
    },
  });
}

export function useCategorias() {
  return useQuery({
    queryKey: ["categorias"],
    // Categorias mudam raramente e são lidas em quase toda tela.
    staleTime: 15 * 60 * 1000,
    queryFn: async (): Promise<Categoria[]> => {
      const { data, error } = await supabase.from("categorias").select("*").order("nome");
      if (error) throw error;
      return (data ?? []) as Categoria[];
    },
  });
}

export function useDividas() {
  return useQuery({
    queryKey: ["dividas"],
    queryFn: async (): Promise<Divida[]> => {
      const { data, error } = await supabase
        .from("dividas")
        .select("*")
        .neq("status", "quitada")
        .order("taxa_juros_mensal", { ascending: false });
      if (error) throw error;
      return (data ?? []) as Divida[];
    },
  });
}

export function useTransacoes(limite = 100) {
  return useQuery({
    queryKey: ["transacoes", limite],
    queryFn: async (): Promise<Transacao[]> => {
      const { data, error } = await supabase
        .from("transacoes")
        .select("*")
        .order("data", { ascending: false })
        .limit(limite);
      if (error) throw error;
      return (data ?? []) as Transacao[];
    },
  });
}

/** O snapshot completo. Mesma função que o agente do n8n chama. */
export function useRaioX() {
  return useQuery({
    queryKey: ["raio-x"],
    queryFn: async (): Promise<RaioX> => {
      const { data, error } = await supabase.rpc("fn_raio_x_financeiro");
      if (error) throw error;
      return data as RaioX;
    },
  });
}

export function useSimulacao(estrategia: EstrategiaQuitacao, aporteExtra: number | null) {
  return useQuery({
    queryKey: ["simulacao", estrategia, aporteExtra],
    // O resultado só muda se as dívidas mudarem; mantém o slider fluido.
    staleTime: 60 * 1000,
    queryFn: async (): Promise<Simulacao> => {
      const { data, error } = await supabase.rpc("fn_simular_quitacao", {
        p_estrategia: estrategia,
        p_aporte_extra: aporteExtra,
      });
      if (error) throw error;
      return data as Simulacao;
    },
  });
}

export function useSalvarDivida() {
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async (divida: Partial<Divida> & { user_id?: string }) => {
      const { data, error } = divida.id
        ? await supabase.from("dividas").update(divida).eq("id", divida.id).select().single()
        : await supabase.from("dividas").insert(divida).select().single();
      if (error) throw error;
      return data as Divida;
    },
    onSuccess: () => {
      // Dívida alterada invalida simulação e raio-x junto — senão a tela
      // mostraria um plano calculado sobre dados velhos.
      qc.invalidateQueries({ queryKey: ["dividas"] });
      qc.invalidateQueries({ queryKey: ["simulacao"] });
      qc.invalidateQueries({ queryKey: ["raio-x"] });
    },
  });
}

export function useSalvarPerfil() {
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async (patch: Partial<Perfil> & { id: string }) => {
      const { error } = await supabase.from("perfis").update(patch).eq("id", patch.id);
      if (error) throw error;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["perfil"] });
      qc.invalidateQueries({ queryKey: ["simulacao"] });
      qc.invalidateQueries({ queryKey: ["raio-x"] });
    },
  });
}
