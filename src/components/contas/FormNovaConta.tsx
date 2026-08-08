import { useQueryClient } from "@tanstack/react-query";
import { Plus } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input, Select } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useAuth } from "@/hooks/useAuth";
import { supabase } from "@/lib/supabase";
import type { TipoConta } from "@/types/db";

const ROTULO_TIPO: Record<TipoConta, string> = {
  corrente: "Conta corrente",
  poupanca: "Poupança",
  cartao_credito: "Cartão de crédito",
  investimento: "Investimento",
  carteira: "Dinheiro / carteira",
};

export function FormNovaConta() {
  const { user } = useAuth();
  const qc = useQueryClient();

  const [aberto, setAberto] = useState(false);
  const [apelido, setApelido] = useState("");
  const [instituicao, setInstituicao] = useState("");
  const [tipo, setTipo] = useState<TipoConta>("corrente");
  const [salvando, setSalvando] = useState(false);

  async function enviar(e: React.FormEvent) {
    e.preventDefault();
    if (!user || !apelido.trim()) return;

    setSalvando(true);
    try {
      const { error } = await supabase.from("contas").insert({
        user_id: user.id,
        apelido: apelido.trim(),
        instituicao: instituicao.trim() || null,
        tipo,
      });
      if (error) throw error;

      toast.success(`Conta "${apelido}" criada.`);
      qc.invalidateQueries({ queryKey: ["contas"] });
      setApelido("");
      setInstituicao("");
      setAberto(false);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Não consegui criar a conta.");
    } finally {
      setSalvando(false);
    }
  }

  if (!aberto) {
    return (
      <Button variant="outline" size="sm" onClick={() => setAberto(true)}>
        <Plus className="size-4" />
        Nova conta
      </Button>
    );
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Nova conta</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={enviar} className="space-y-4">
          <div className="grid gap-4 sm:grid-cols-3">
            <div className="space-y-2">
              <Label htmlFor="apelido">Apelido</Label>
              <Input
                id="apelido"
                value={apelido}
                onChange={(e) => setApelido(e.target.value)}
                placeholder="Corrente Itaú"
                required
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="inst">Instituição</Label>
              <Input
                id="inst"
                value={instituicao}
                onChange={(e) => setInstituicao(e.target.value)}
                placeholder="Itaú"
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="tipoconta">Tipo</Label>
              <Select
                id="tipoconta"
                value={tipo}
                onChange={(e) => setTipo(e.target.value as TipoConta)}
              >
                {(Object.keys(ROTULO_TIPO) as TipoConta[]).map((t) => (
                  <option key={t} value={t}>
                    {ROTULO_TIPO[t]}
                  </option>
                ))}
              </Select>
            </div>
          </div>

          <div className="flex gap-2">
            <Button type="submit" disabled={salvando}>
              {salvando ? "Salvando…" : "Criar conta"}
            </Button>
            <Button type="button" variant="ghost" onClick={() => setAberto(false)}>
              Cancelar
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  );
}
