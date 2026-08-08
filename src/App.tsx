import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Toaster } from "sonner";
import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";

import { AppShell } from "@/components/layout/AppShell";
import { AuthProvider, useAuth } from "@/hooks/useAuth";
import Agente from "@/pages/Agente";
import Dashboard from "@/pages/Dashboard";
import Dividas from "@/pages/Dividas";
import Importar from "@/pages/Importar";
import Login from "@/pages/Login";
import Transacoes from "@/pages/Transacoes";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30 * 1000,
      refetchOnWindowFocus: false,
      // Erro de RLS ou sessão expirada não melhora com retry; só atrasa a
      // mensagem que o usuário precisa ver.
      retry: 1,
    },
  },
});

function Protegido() {
  const { session, carregando } = useAuth();

  if (carregando) {
    return (
      <div className="flex min-h-screen items-center justify-center text-muted-foreground">
        Carregando…
      </div>
    );
  }

  return session ? <AppShell /> : <Navigate to="/login" replace />;
}

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <BrowserRouter>
          <Routes>
            <Route path="/login" element={<Login />} />
            <Route element={<Protegido />}>
              <Route index element={<Dashboard />} />
              <Route path="dividas" element={<Dividas />} />
              <Route path="transacoes" element={<Transacoes />} />
              <Route path="importar" element={<Importar />} />
              <Route path="agente" element={<Agente />} />
            </Route>
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </BrowserRouter>
        <Toaster richColors position="top-right" />
      </AuthProvider>
    </QueryClientProvider>
  );
}
