import { Bot, Send, User } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { useAuth } from "@/hooks/useAuth";
import { cn } from "@/lib/utils";

interface Mensagem {
  papel: "user" | "assistant";
  conteudo: string;
}

const WEBHOOK = import.meta.env.VITE_AGENTE_WEBHOOK_URL as string | undefined;

const SUGESTOES = [
  "Faça um raio-X da minha situação e me diga a verdade.",
  "Qual dívida eu ataco primeiro e por quê?",
  "Monte um roteiro para eu negociar minha dívida do cartão.",
  "Onde eu consigo cortar R$ 300 por mês sem passar aperto?",
  "Vale a pena pegar um empréstimo para quitar o rotativo?",
];

export default function Agente() {
  const { session } = useAuth();
  const [mensagens, setMensagens] = useState<Mensagem[]>([]);
  const [entrada, setEntrada] = useState("");
  const [pensando, setPensando] = useState(false);
  const fim = useRef<HTMLDivElement>(null);

  // A sessão do chat amarra a memória do agente no n8n. Fica presa ao usuário
  // para a conversa sobreviver a um reload da página.
  const sessionId = session?.user.id ?? "anonimo";

  useEffect(() => {
    fim.current?.scrollIntoView({ behavior: "smooth" });
  }, [mensagens, pensando]);

  async function enviar(texto: string) {
    const pergunta = texto.trim();
    if (!pergunta || pensando) return;

    if (!WEBHOOK) {
      toast.error("VITE_AGENTE_WEBHOOK_URL não está configurada no .env.");
      return;
    }

    setMensagens((m) => [...m, { papel: "user", conteudo: pergunta }]);
    setEntrada("");
    setPensando(true);

    try {
      const resposta = await fetch(WEBHOOK, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          // O n8n repassa este token ao Supabase para que as ferramentas do
          // agente leiam os dados SOB A RLS deste usuário. Sem isso o agente
          // precisaria da service_role key, que enxergaria todo mundo.
          Authorization: `Bearer ${session?.access_token ?? ""}`,
        },
        body: JSON.stringify({ sessionId, mensagem: pergunta }),
      });

      if (!resposta.ok) {
        throw new Error(`O agente respondeu ${resposta.status}.`);
      }

      const dados = await resposta.json();
      const texto2 =
        dados.output ?? dados.resposta ?? dados.text ?? "Não consegui formular uma resposta.";

      setMensagens((m) => [...m, { papel: "assistant", conteudo: String(texto2) }]);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Falha ao falar com o agente.");
      setMensagens((m) => m.slice(0, -1));
      setEntrada(pergunta);
    } finally {
      setPensando(false);
    }
  }

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Agente financeiro</h1>
        <p className="text-sm text-muted-foreground">
          Ele lê os seus números antes de responder. Pode perguntar sem rodeio.
        </p>
      </div>

      {mensagens.length === 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Por onde começar</CardTitle>
            <CardDescription>
              O agente tem acesso ao seu raio-X, às suas dívidas e ao simulador de quitação — os
              mesmos dados que você vê no painel.
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap gap-2">
            {SUGESTOES.map((s) => (
              <Button key={s} variant="secondary" size="sm" onClick={() => enviar(s)}>
                {s}
              </Button>
            ))}
          </CardContent>
        </Card>
      )}

      <div className="space-y-4">
        {mensagens.map((m, i) => (
          <div
            key={i}
            className={cn("flex gap-3", m.papel === "user" ? "justify-end" : "justify-start")}
          >
            {m.papel === "assistant" && (
              <div className="flex size-8 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground">
                <Bot className="size-4" />
              </div>
            )}

            <div
              className={cn(
                "max-w-[80%] whitespace-pre-wrap rounded-lg px-4 py-3 text-sm",
                m.papel === "user" ? "bg-primary text-primary-foreground" : "bg-muted",
              )}
            >
              {m.conteudo}
            </div>

            {m.papel === "user" && (
              <div className="flex size-8 shrink-0 items-center justify-center rounded-full bg-secondary">
                <User className="size-4" />
              </div>
            )}
          </div>
        ))}

        {pensando && (
          <div className="flex gap-3">
            <div className="flex size-8 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground">
              <Bot className="size-4" />
            </div>
            <div className="rounded-lg bg-muted px-4 py-3 text-sm text-muted-foreground">
              Consultando seus números…
            </div>
          </div>
        )}

        <div ref={fim} />
      </div>

      <form
        onSubmit={(e) => {
          e.preventDefault();
          enviar(entrada);
        }}
        className="sticky bottom-4 flex gap-2 rounded-lg border bg-background p-2 shadow-sm"
      >
        <Input
          value={entrada}
          onChange={(e) => setEntrada(e.target.value)}
          placeholder="Pergunte sobre suas dívidas, seus gastos ou uma negociação…"
          className="border-0 focus-visible:ring-0"
          disabled={pensando}
        />
        <Button type="submit" size="icon" disabled={pensando || !entrada.trim()}>
          <Send className="size-4" />
        </Button>
      </form>
    </div>
  );
}
