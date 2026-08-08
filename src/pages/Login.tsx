import { useState } from "react";
import { Navigate } from "react-router-dom";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useAuth } from "@/hooks/useAuth";

export default function Login() {
  const { session, entrar, cadastrar } = useAuth();
  const [modo, setModo] = useState<"entrar" | "cadastrar">("entrar");
  const [nome, setNome] = useState("");
  const [email, setEmail] = useState("");
  const [senha, setSenha] = useState("");
  const [enviando, setEnviando] = useState(false);

  if (session) return <Navigate to="/" replace />;

  async function enviar(e: React.FormEvent) {
    e.preventDefault();
    setEnviando(true);

    try {
      if (modo === "entrar") {
        await entrar(email, senha);
      } else {
        await cadastrar(email, senha, nome);
        toast.success("Conta criada. Confirme o e-mail se o projeto exigir verificação.");
      }
    } catch (erro) {
      toast.error(erro instanceof Error ? erro.message : "Não foi possível autenticar.");
    } finally {
      setEnviando(false);
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center px-4">
      <Card className="w-full max-w-sm">
        <CardHeader>
          <CardTitle className="text-xl">FinBR</CardTitle>
          <CardDescription>
            {modo === "entrar"
              ? "Entre para ver seu painel e seu plano de saída das dívidas."
              : "Crie sua conta para começar."}
          </CardDescription>
        </CardHeader>

        <CardContent>
          <form onSubmit={enviar} className="space-y-4">
            {modo === "cadastrar" && (
              <div className="space-y-2">
                <Label htmlFor="nome">Nome</Label>
                <Input id="nome" value={nome} onChange={(e) => setNome(e.target.value)} required />
              </div>
            )}

            <div className="space-y-2">
              <Label htmlFor="email">E-mail</Label>
              <Input
                id="email"
                type="email"
                autoComplete="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                required
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="senha">Senha</Label>
              <Input
                id="senha"
                type="password"
                autoComplete={modo === "entrar" ? "current-password" : "new-password"}
                value={senha}
                onChange={(e) => setSenha(e.target.value)}
                minLength={8}
                required
              />
            </div>

            <Button type="submit" className="w-full" disabled={enviando}>
              {enviando ? "Aguarde…" : modo === "entrar" ? "Entrar" : "Criar conta"}
            </Button>

            <Button
              type="button"
              variant="link"
              className="w-full"
              onClick={() => setModo(modo === "entrar" ? "cadastrar" : "entrar")}
            >
              {modo === "entrar" ? "Não tenho conta" : "Já tenho conta"}
            </Button>
          </form>
        </CardContent>
      </Card>
    </div>
  );
}
