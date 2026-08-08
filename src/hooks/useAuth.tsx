import type { Session, User } from "@supabase/supabase-js";
import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from "react";

import { supabase } from "@/lib/supabase";

interface AuthContexto {
  session: Session | null;
  user: User | null;
  carregando: boolean;
  entrar: (email: string, senha: string) => Promise<void>;
  cadastrar: (email: string, senha: string, nome: string) => Promise<void>;
  sair: () => Promise<void>;
}

const Ctx = createContext<AuthContexto | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [carregando, setCarregando] = useState(true);

  useEffect(() => {
    // O listener é registrado ANTES do getSession para não perder o evento
    // de restauração de sessão que o cliente dispara no boot.
    const { data: sub } = supabase.auth.onAuthStateChange((_evento, s) => {
      setSession(s);
      setCarregando(false);
    });

    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setCarregando(false);
    });

    return () => sub.subscription.unsubscribe();
  }, []);

  const valor = useMemo<AuthContexto>(
    () => ({
      session,
      user: session?.user ?? null,
      carregando,
      async entrar(email, senha) {
        const { error } = await supabase.auth.signInWithPassword({ email, password: senha });
        if (error) throw error;
      },
      async cadastrar(email, senha, nome) {
        const { error } = await supabase.auth.signUp({
          email,
          password: senha,
          options: { data: { nome } },
        });
        if (error) throw error;
      },
      async sair() {
        await supabase.auth.signOut();
      },
    }),
    [session, carregando],
  );

  return <Ctx.Provider value={valor}>{children}</Ctx.Provider>;
}

export function useAuth() {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error("useAuth precisa estar dentro de <AuthProvider>");
  return ctx;
}
