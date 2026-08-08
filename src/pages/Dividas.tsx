import { useState } from "react";
import {
  Area,
  AreaChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

import { FormNovaDivida } from "@/components/dividas/FormNovaDivida";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input, Select } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { usePerfil, useSalvarPerfil, useSimulacao } from "@/hooks/useFinancas";
import { brl, brlCompacto, competenciaBr, dataBr, duracaoBr, taxaMensal } from "@/lib/format";
import type { EstrategiaQuitacao, Simulacao } from "@/types/db";

/** Cartão de resultado de uma estratégia, para comparação lado a lado. */
function ResumoEstrategia({
  titulo,
  explicacao,
  sim,
  destaque,
}: {
  titulo: string;
  explicacao: string;
  sim: Simulacao | undefined;
  destaque?: string;
}) {
  if (!sim) return null;

  if (!sim.viavel) {
    return (
      <Card className="border-destructive/50">
        <CardHeader>
          <CardTitle className="text-base">{titulo}</CardTitle>
          <CardDescription>
            Inviável no orçamento atual: faltam {brl(sim.deficit_mensal)} por mês só para a dívida
            parar de crescer.
          </CardDescription>
        </CardHeader>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader>
        <div className="flex items-start justify-between gap-2">
          <CardTitle className="text-base">{titulo}</CardTitle>
          {destaque && <Badge variant="ok">{destaque}</Badge>}
        </div>
        <CardDescription>{explicacao}</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        <div className="grid grid-cols-2 gap-4">
          <div>
            <p className="text-xs text-muted-foreground">Tempo até zerar</p>
            <p className="tabular text-xl font-semibold">{duracaoBr(sim.meses)}</p>
          </div>
          <div>
            <p className="text-xs text-muted-foreground">Juros que você vai pagar</p>
            <p className="tabular text-xl font-semibold text-negative">{brl(sim.juros_total)}</p>
          </div>
        </div>

        <div className="border-t pt-3 text-sm">
          <p className="text-muted-foreground">
            Livre em <strong className="text-foreground">{dataBr(sim.data_liberdade)}</strong>,
            pagando {brl(sim.orcamento_mensal)}/mês.
          </p>
          {sim.dividas[0]?.mes_quitacao && (
            <p className="mt-1 text-muted-foreground">
              Primeira dívida quitada em{" "}
              <strong className="text-foreground">
                {duracaoBr(sim.dividas[0].mes_quitacao)}
              </strong>{" "}
              ({sim.dividas[0].credor}).
            </p>
          )}
        </div>
      </CardContent>
    </Card>
  );
}

export default function Dividas() {
  const { data: perfil } = usePerfil();
  const salvarPerfil = useSalvarPerfil();

  const [estrategia, setEstrategia] = useState<EstrategiaQuitacao>("avalanche");
  // `null` faz a RPC usar o aporte salvo no perfil; qualquer número sobrescreve.
  const [aporte, setAporte] = useState<number | null>(null);

  const avalanche = useSimulacao("avalanche", aporte);
  const bolaDeNeve = useSimulacao("bola_de_neve", aporte);
  const escolhida = useSimulacao(estrategia, aporte);

  const simA = avalanche.data;
  const simB = bolaDeNeve.data;
  const sim = escolhida.data;

  const aporteEfetivo = aporte ?? perfil?.aporte_extra_mensal ?? 0;

  // Só faz sentido comparar economia quando os dois cenários fecham.
  const economiaJuros =
    simA?.viavel && simB?.viavel ? simB.juros_total - simA.juros_total : null;
  const mesesEconomizados =
    simA?.viavel && simB?.viavel ? simB.meses - simA.meses : null;

  const cronograma =
    sim?.viavel
      ? sim.cronograma.map((m) => ({
          mes: competenciaBr(m.competencia),
          Saldo: m.saldo_restante,
          Juros: m.juros,
        }))
      : [];

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Plano de saída das dívidas</h1>
          <p className="text-sm text-muted-foreground">
            Duas estratégias, os mesmos dados. Escolha a que você consegue sustentar.
          </p>
        </div>
      </div>

      <FormNovaDivida />

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Quanto você consegue pagar a mais por mês?</CardTitle>
          <CardDescription>
            Além das parcelas mínimas. É esse valor que decide se a saída leva anos ou meses.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="flex flex-wrap items-end gap-4">
            <div className="w-48 space-y-2">
              <Label htmlFor="aporte">Aporte extra mensal</Label>
              <Input
                id="aporte"
                type="number"
                min={0}
                step={50}
                value={aporteEfetivo}
                onChange={(e) => setAporte(Number(e.target.value) || 0)}
              />
            </div>

            <div className="w-56 space-y-2">
              <Label htmlFor="estrategia">Estratégia do cronograma</Label>
              <Select
                id="estrategia"
                value={estrategia}
                onChange={(e) => setEstrategia(e.target.value as EstrategiaQuitacao)}
              >
                <option value="avalanche">Avalanche — juro mais alto primeiro</option>
                <option value="bola_de_neve">Bola de neve — saldo menor primeiro</option>
                <option value="personalizada">Personalizada — minha ordem</option>
              </Select>
            </div>

            {perfil && aporte !== null && aporte !== perfil.aporte_extra_mensal && (
              <Button
                variant="outline"
                onClick={() =>
                  salvarPerfil.mutate({ id: perfil.id, aporte_extra_mensal: aporte })
                }
                disabled={salvarPerfil.isPending}
              >
                Salvar {brl(aporte)} no meu perfil
              </Button>
            )}
          </div>

          <div className="flex flex-wrap gap-2">
            {[0, 100, 300, 500, 1000, 2000].map((v) => (
              <Button key={v} variant="secondary" size="sm" onClick={() => setAporte(v)}>
                {v === 0 ? "Só as mínimas" : `+${brl(v)}`}
              </Button>
            ))}
          </div>
        </CardContent>
      </Card>

      <div className="grid gap-4 lg:grid-cols-2">
        <ResumoEstrategia
          titulo="Avalanche"
          explicacao="Ataca primeiro o juro mais alto. Sempre paga menos juros no total — é a escolha matematicamente ótima."
          sim={simA}
          destaque={economiaJuros !== null && economiaJuros > 0 ? "Mais barata" : undefined}
        />
        <ResumoEstrategia
          titulo="Bola de neve"
          explicacao="Ataca primeiro o menor saldo. Custa mais caro, mas entrega a primeira vitória bem antes — o que sustenta a disciplina de quem já desistiu outras vezes."
          sim={simB}
          destaque={
            simA?.viavel && simB?.viavel && simB.dividas[0]?.mes_quitacao
              ? "Vitória mais rápida"
              : undefined
          }
        />
      </div>

      {economiaJuros !== null && economiaJuros > 0 && (
        <Card className="bg-secondary/50">
          <CardContent className="pt-6">
            <p className="text-sm">
              Escolher <strong>avalanche</strong> em vez de bola de neve economiza{" "}
              <strong className="text-positive">{brl(economiaJuros)}</strong> em juros
              {mesesEconomizados && mesesEconomizados > 0
                ? ` e antecipa sua liberdade em ${duracaoBr(mesesEconomizados)}`
                : ""}
              . Mas se você já tentou e desistiu antes, a bola de neve quita a primeira dívida em{" "}
              {simB?.viavel && simB.dividas[0]?.mes_quitacao
                ? duracaoBr(simB.dividas[0].mes_quitacao)
                : "menos tempo"}{" "}
              — e um plano que você mantém vale mais que um plano ótimo que você abandona.
            </p>
          </CardContent>
        </Card>
      )}

      {sim?.viavel && sim.dividas.length > 0 && (
        <Tabs defaultValue="ordem">
          <TabsList>
            <TabsTrigger value="ordem">Ordem de ataque</TabsTrigger>
            <TabsTrigger value="cronograma">Cronograma</TabsTrigger>
          </TabsList>

          <TabsContent value="ordem">
            <Card>
              <CardHeader>
                <CardTitle className="text-base">
                  Nesta ordem, pagando {brl(sim.orcamento_mensal)} por mês
                </CardTitle>
                <CardDescription>
                  Pague a mínima de todas e jogue toda a sobra na dívida nº 1 até ela zerar.
                </CardDescription>
              </CardHeader>
              <CardContent className="space-y-3">
                {sim.dividas.map((d) => (
                  <div
                    key={d.divida_id}
                    className="flex flex-wrap items-center gap-4 rounded-lg border p-4"
                  >
                    <div className="flex size-8 shrink-0 items-center justify-center rounded-full bg-primary text-sm font-semibold text-primary-foreground">
                      {d.ordem_ataque}
                    </div>

                    <div className="min-w-0 flex-1">
                      <p className="font-medium">{d.credor}</p>
                      <p className="text-xs text-muted-foreground">
                        {brl(d.saldo_inicial)} a {taxaMensal(d.taxa_mensal)} · mínima{" "}
                        {brl(d.parcela_minima)}
                      </p>
                    </div>

                    <div className="text-right">
                      <p className="text-sm font-medium">
                        Quitada em {duracaoBr(d.mes_quitacao ?? 0)}
                      </p>
                      <p className="text-xs text-negative">
                        {brl(d.juros_pagos)} de juros no caminho
                      </p>
                    </div>
                  </div>
                ))}
              </CardContent>
            </Card>
          </TabsContent>

          <TabsContent value="cronograma">
            <Card>
              <CardHeader>
                <CardTitle className="text-base">Saldo devedor mês a mês</CardTitle>
                <CardDescription>
                  De {brl(sim.saldo_inicial)} a zero em {duracaoBr(sim.meses)}.
                </CardDescription>
              </CardHeader>
              <CardContent>
                <ResponsiveContainer width="100%" height={300}>
                  <AreaChart data={cronograma}>
                    <CartesianGrid strokeDasharray="3 3" vertical={false} opacity={0.3} />
                    <XAxis
                      dataKey="mes"
                      tickLine={false}
                      axisLine={false}
                      fontSize={12}
                      interval="preserveStartEnd"
                      minTickGap={40}
                    />
                    <YAxis
                      tickFormatter={(v) => brlCompacto(Number(v))}
                      tickLine={false}
                      axisLine={false}
                      fontSize={12}
                      width={70}
                    />
                    <Tooltip formatter={(v) => brl(Number(v))} />
                    <Area
                      type="monotone"
                      dataKey="Saldo"
                      stroke="hsl(var(--negative))"
                      fill="hsl(var(--negative))"
                      fillOpacity={0.15}
                      strokeWidth={2}
                    />
                  </AreaChart>
                </ResponsiveContainer>

                <div className="mt-4 space-y-1 text-sm">
                  {sim.cronograma
                    .filter((m) => m.quitadas.length > 0)
                    .map((m) => (
                      <p key={m.mes} className="text-muted-foreground">
                        <strong className="text-positive">{competenciaBr(m.competencia)}</strong> —
                        quitada: {m.quitadas.map((q) => q.credor).join(", ")}
                      </p>
                    ))}
                </div>
              </CardContent>
            </Card>
          </TabsContent>
        </Tabs>
      )}

      {sim?.viavel && sim.sem_dividas && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Nenhuma dívida cadastrada</CardTitle>
            <CardDescription>
              Cadastre suas dívidas para o plano aparecer aqui. Você precisa de: credor, saldo
              devedor atual, taxa de juros ao mês e parcela mínima. Se não souber a taxa, o agente
              ajuda a estimar a partir do tipo da dívida.
            </CardDescription>
          </CardHeader>
        </Card>
      )}
    </div>
  );
}
