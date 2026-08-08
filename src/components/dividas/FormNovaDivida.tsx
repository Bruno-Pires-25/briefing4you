import { Plus } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input, Select } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useAuth } from "@/hooks/useAuth";
import { useSalvarDivida } from "@/hooks/useFinancas";
import { taxaAnualEquivalente } from "@/lib/format";
import type { TipoDivida } from "@/types/db";

/**
 * Taxas mensais típicas do mercado brasileiro, por tipo de dívida.
 *
 * Servem como CHUTE INICIAL para quem não sabe a taxa do próprio contrato —
 * é comum não saber, e um plano com taxa aproximada é muito melhor que
 * nenhum plano. O campo continua editável e o usuário é avisado de que o
 * número certo está na fatura ou no contrato.
 */
const TAXA_TIPICA: Record<TipoDivida, number> = {
  credito_rotativo: 0.135,
  cartao_credito: 0.135,
  cheque_especial: 0.079,
  parcelamento_fatura: 0.085,
  emprestimo_pessoal: 0.055,
  conta_atrasada: 0.02,
  agiota_informal: 0.2,
  financiamento_veiculo: 0.021,
  consignado: 0.018,
  financiamento_imovel: 0.009,
  outro: 0.03,
};

const ROTULO_TIPO: Record<TipoDivida, string> = {
  credito_rotativo: "Rotativo do cartão",
  cartao_credito: "Cartão de crédito",
  cheque_especial: "Cheque especial",
  parcelamento_fatura: "Parcelamento de fatura",
  emprestimo_pessoal: "Empréstimo pessoal",
  conta_atrasada: "Conta atrasada (luz, água, condomínio)",
  agiota_informal: "Empréstimo informal",
  financiamento_veiculo: "Financiamento de veículo",
  consignado: "Consignado",
  financiamento_imovel: "Financiamento imobiliário",
  outro: "Outro",
};

export function FormNovaDivida() {
  const { user } = useAuth();
  const salvar = useSalvarDivida();

  const [aberto, setAberto] = useState(false);
  const [credor, setCredor] = useState("");
  const [tipo, setTipo] = useState<TipoDivida>("credito_rotativo");
  const [saldo, setSaldo] = useState("");
  const [taxa, setTaxa] = useState((TAXA_TIPICA.credito_rotativo * 100).toFixed(2));
  const [minima, setMinima] = useState("");
  const [vencimento, setVencimento] = useState("");
  const [emAtraso, setEmAtraso] = useState(false);
  const [negativado, setNegativado] = useState(false);

  function trocarTipo(novo: TipoDivida) {
    setTipo(novo);
    // Só sobrescreve a taxa se o usuário ainda não mexeu nela de propósito.
    setTaxa((atual) => {
      const eraTipica = Object.values(TAXA_TIPICA).some(
        (t) => Math.abs(t * 100 - Number(atual)) < 0.001,
      );
      return eraTipica ? (TAXA_TIPICA[novo] * 100).toFixed(2) : atual;
    });
  }

  async function enviar(e: React.FormEvent) {
    e.preventDefault();
    if (!user) return;

    const saldoNum = Number(saldo.replace(",", "."));
    const taxaNum = Number(taxa.replace(",", ".")) / 100;
    const minimaNum = Number(minima.replace(",", ".")) || 0;

    if (!credor.trim() || !Number.isFinite(saldoNum) || saldoNum <= 0) {
      toast.error("Informe o credor e um saldo devedor maior que zero.");
      return;
    }

    try {
      await salvar.mutateAsync({
        user_id: user.id,
        credor: credor.trim(),
        tipo,
        saldo_devedor: saldoNum,
        taxa_juros_mensal: taxaNum,
        parcela_minima: minimaNum,
        dia_vencimento: vencimento ? Number(vencimento) : null,
        status: emAtraso ? "em_atraso" : "ativa",
        em_orgao_protecao: negativado,
      });

      toast.success(`${credor} cadastrada. O plano já foi recalculado.`);
      setCredor("");
      setSaldo("");
      setMinima("");
      setVencimento("");
      setEmAtraso(false);
      setNegativado(false);
      setAberto(false);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Não consegui salvar a dívida.");
    }
  }

  if (!aberto) {
    return (
      <Button variant="outline" onClick={() => setAberto(true)}>
        <Plus className="size-4" />
        Cadastrar dívida
      </Button>
    );
  }

  const anual = taxaAnualEquivalente(Number(taxa.replace(",", ".")) / 100);

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Nova dívida</CardTitle>
        <CardDescription>
          Saldo devedor é o que quitaria a dívida <strong>hoje</strong>, não o valor original nem a
          soma das parcelas que faltam.
        </CardDescription>
      </CardHeader>

      <CardContent>
        <form onSubmit={enviar} className="space-y-4">
          <div className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-2">
              <Label htmlFor="credor">Credor</Label>
              <Input
                id="credor"
                value={credor}
                onChange={(e) => setCredor(e.target.value)}
                placeholder="Cartão Nubank, Banco X…"
                required
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="tipo">Tipo</Label>
              <Select
                id="tipo"
                value={tipo}
                onChange={(e) => trocarTipo(e.target.value as TipoDivida)}
              >
                {(Object.keys(ROTULO_TIPO) as TipoDivida[]).map((t) => (
                  <option key={t} value={t}>
                    {ROTULO_TIPO[t]}
                  </option>
                ))}
              </Select>
            </div>

            <div className="space-y-2">
              <Label htmlFor="saldo">Saldo devedor hoje (R$)</Label>
              <Input
                id="saldo"
                inputMode="decimal"
                value={saldo}
                onChange={(e) => setSaldo(e.target.value)}
                placeholder="8000,00"
                required
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="taxa">Juros ao mês (%)</Label>
              <Input
                id="taxa"
                inputMode="decimal"
                value={taxa}
                onChange={(e) => setTaxa(e.target.value)}
              />
              <p className="text-xs text-muted-foreground">
                Equivale a {(anual * 100).toFixed(0)}% ao ano. Preenchido com a taxa típica do
                tipo — o número exato está na sua fatura ou contrato.
              </p>
            </div>

            <div className="space-y-2">
              <Label htmlFor="minima">Parcela mínima mensal (R$)</Label>
              <Input
                id="minima"
                inputMode="decimal"
                value={minima}
                onChange={(e) => setMinima(e.target.value)}
                placeholder="800,00"
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="venc">Dia do vencimento</Label>
              <Input
                id="venc"
                type="number"
                min={1}
                max={31}
                value={vencimento}
                onChange={(e) => setVencimento(e.target.value)}
                placeholder="10"
              />
            </div>
          </div>

          <div className="flex flex-wrap gap-6">
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={emAtraso}
                onChange={(e) => setEmAtraso(e.target.checked)}
                className="size-4"
              />
              Está em atraso
            </label>

            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={negativado}
                onChange={(e) => setNegativado(e.target.checked)}
                className="size-4"
              />
              Estou negativado por ela (Serasa/SPC)
            </label>
          </div>

          <div className="flex gap-2">
            <Button type="submit" disabled={salvar.isPending}>
              {salvar.isPending ? "Salvando…" : "Salvar dívida"}
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
