import { AlertTriangle, CalendarCheck, Flame, TrendingDown, Wallet } from "lucide-react";
import {
  Bar,
  BarChart,
  CartesianGrid,
  Legend,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Progress } from "@/components/ui/progress";
import { useRaioX } from "@/hooks/useFinancas";
import {
  brl,
  brlCompacto,
  competenciaBr,
  duracaoBr,
  percentual,
  taxaAnualEquivalente,
} from "@/lib/format";
import { cn } from "@/lib/utils";

function Indicador({
  titulo,
  valor,
  detalhe,
  Icone,
  tom = "neutro",
}: {
  titulo: string;
  valor: string;
  detalhe?: string;
  Icone: typeof Wallet;
  tom?: "neutro" | "bom" | "ruim" | "alerta";
}) {
  const cor = {
    neutro: "text-foreground",
    bom: "text-positive",
    ruim: "text-negative",
    alerta: "text-warning",
  }[tom];

  return (
    <Card>
      <CardHeader className="flex-row items-center justify-between space-y-0 pb-2">
        <CardDescription>{titulo}</CardDescription>
        <Icone className={cn("size-4", cor)} />
      </CardHeader>
      <CardContent>
        <div className={cn("tabular text-2xl font-semibold", cor)}>{valor}</div>
        {detalhe && <p className="mt-1 text-xs text-muted-foreground">{detalhe}</p>}
      </CardContent>
    </Card>
  );
}

export default function Dashboard() {
  const { data: raioX, isLoading, error } = useRaioX();

  if (isLoading) {
    return <p className="text-muted-foreground">Carregando seu raio-X financeiro…</p>;
  }

  if (error) {
    return (
      <Card className="border-destructive/40">
        <CardHeader>
          <CardTitle className="text-destructive">Não consegui carregar os dados</CardTitle>
          <CardDescription>{(error as Error).message}</CardDescription>
        </CardHeader>
      </Card>
    );
  }

  if (!raioX) return null;

  const { perfil, dividas_resumo: resumo, indicadores, dividas, cenarios } = raioX;
  const comprometimento = indicadores.comprometimento_renda;
  const avalanche = cenarios.avalanche;

  // Ordena o histórico do mais antigo para o mais novo — o gráfico lê da
  // esquerda para a direita, mas a RPC devolve decrescente.
  const serie = [...raioX.resumo_mensal].reverse().map((m) => ({
    mes: competenciaBr(m.mes.slice(0, 7)),
    Receitas: Number(m.receitas ?? 0),
    Despesas: Math.abs(Number(m.despesas ?? 0)),
    Dívidas: Math.abs(Number(m.pagamento_dividas ?? 0)),
  }));

  const semDividas = !resumo.qtd_dividas;

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">
          {perfil.nome ? `Olá, ${perfil.nome.split(" ")[0]}` : "Seu painel"}
        </h1>
        <p className="text-sm text-muted-foreground">
          Foto completa das suas finanças e do caminho até zerar as dívidas.
        </p>
      </div>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Indicador
          titulo="Dívida total"
          valor={brl(resumo.saldo_total ?? 0)}
          detalhe={`${resumo.qtd_dividas ?? 0} dívida(s) ativa(s)`}
          Icone={TrendingDown}
          tom={semDividas ? "bom" : "ruim"}
        />

        <Indicador
          titulo="Juros por mês"
          valor={brl(resumo.juros_mensais ?? 0)}
          detalhe="O que você perde por mês sem amortizar nada"
          Icone={Flame}
          tom={(resumo.juros_mensais ?? 0) > 0 ? "ruim" : "bom"}
        />

        <Indicador
          titulo="Comprometimento da renda"
          valor={comprometimento === null ? "—" : percentual(comprometimento)}
          detalhe={
            comprometimento === null
              ? "Informe sua renda mensal no perfil"
              : comprometimento > 30
                ? "Acima de 30% é zona de risco"
                : "Dentro do limite saudável"
          }
          Icone={AlertTriangle}
          tom={comprometimento === null ? "neutro" : comprometimento > 30 ? "ruim" : "bom"}
        />

        <Indicador
          titulo="Livre de dívidas em"
          valor={
            semDividas
              ? "Você está livre"
              : avalanche.viavel
                ? duracaoBr(avalanche.meses)
                : "Sem saída no ritmo atual"
          }
          detalhe={
            semDividas
              ? undefined
              : avalanche.viavel
                ? `Pelo método avalanche, com ${brl(avalanche.aporte_extra)} extra/mês`
                : `Faltam ${brl(avalanche.deficit_mensal)}/mês só para parar de crescer`
          }
          Icone={CalendarCheck}
          tom={semDividas ? "bom" : avalanche.viavel ? "alerta" : "ruim"}
        />
      </div>

      {!avalanche.viavel && !semDividas && (
        <Card className="border-destructive/50 bg-destructive/5">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-destructive">
              <AlertTriangle className="size-5" />
              Sua dívida está crescendo mais rápido do que você paga
            </CardTitle>
            <CardDescription className="text-foreground">
              Com {brl(avalanche.orcamento_mensal)} por mês contra{" "}
              {brl(avalanche.juros_primeiro_mes)} de juros, o saldo aumenta todo mês. Nenhum plano
              de pagamento resolve isso sozinho — o caminho aqui é <strong>renegociar</strong> as
              dívidas de juro mais alto ou aumentar a renda em pelo menos{" "}
              {brl(avalanche.deficit_mensal)}/mês. Peça ao agente um roteiro de negociação.
            </CardDescription>
          </CardHeader>
        </Card>
      )}

      {comprometimento !== null && !semDividas && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Quanto da sua renda já está comprometida</CardTitle>
            <CardDescription>
              {brl(resumo.parcela_minima_total ?? 0)} em parcelas mínimas de uma renda de{" "}
              {brl(perfil.renda_mensal)}.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-2">
            <Progress
              value={Math.min(comprometimento, 100)}
              indicatorClassName={
                comprometimento > 30
                  ? "bg-destructive"
                  : comprometimento > 20
                    ? "bg-warning"
                    : "bg-positive"
              }
            />
            <div className="flex justify-between text-xs text-muted-foreground">
              <span>0%</span>
              <span>30% — limite de risco</span>
              <span>100%</span>
            </div>
          </CardContent>
        </Card>
      )}

      {serie.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Entradas e saídas por mês</CardTitle>
            <CardDescription>Últimos 6 meses, sem contar transferências entre contas.</CardDescription>
          </CardHeader>
          <CardContent>
            <ResponsiveContainer width="100%" height={280}>
              <BarChart data={serie}>
                <CartesianGrid strokeDasharray="3 3" vertical={false} opacity={0.3} />
                <XAxis dataKey="mes" tickLine={false} axisLine={false} fontSize={12} />
                <YAxis
                  tickFormatter={(v) => brlCompacto(Number(v))}
                  tickLine={false}
                  axisLine={false}
                  fontSize={12}
                  width={70}
                />
                <Tooltip formatter={(v) => brl(Number(v))} />
                <Legend />
                <Bar dataKey="Receitas" fill="hsl(var(--positive))" radius={[4, 4, 0, 0]} />
                <Bar dataKey="Despesas" fill="hsl(var(--negative))" radius={[4, 4, 0, 0]} />
                <Bar dataKey="Dívidas" fill="hsl(var(--warning))" radius={[4, 4, 0, 0]} />
              </BarChart>
            </ResponsiveContainer>
          </CardContent>
        </Card>
      )}

      {dividas.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Suas dívidas, da mais cara para a mais barata</CardTitle>
            <CardDescription>
              A ordem aqui é a ordem de ataque do método avalanche.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            {dividas.map((d) => {
              const anual = taxaAnualEquivalente(Number(d.taxa_juros_mensal));
              return (
                <div
                  key={d.id}
                  className="flex flex-wrap items-center justify-between gap-3 rounded-lg border p-4"
                >
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <span className="font-medium">{d.credor}</span>
                      {d.em_orgao_protecao && <Badge variant="critico">Negativado</Badge>}
                      {d.status === "em_atraso" && (
                        <Badge variant="critico">{d.dias_em_atraso} dias em atraso</Badge>
                      )}
                      {d.aceita_negociacao && Number(d.taxa_juros_mensal) >= 0.05 && (
                        <Badge variant="atencao">Vale negociar</Badge>
                      )}
                    </div>
                    <p className="mt-1 text-xs text-muted-foreground">
                      {(Number(d.taxa_juros_mensal) * 100).toFixed(2).replace(".", ",")}% a.m. ={" "}
                      {(anual * 100).toFixed(0)}% a.a. · queima {brl(d.juros_mes)}/mês
                    </p>
                  </div>

                  <div className="text-right">
                    <div className="tabular font-semibold">{brl(d.saldo_devedor)}</div>
                    <p className="text-xs text-muted-foreground">
                      mínima {brl(d.parcela_minima)}
                    </p>
                  </div>
                </div>
              );
            })}
          </CardContent>
        </Card>
      )}

      {raioX.gastos_categoria_3m.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Para onde o dinheiro foi (últimos 3 meses)</CardTitle>
            <CardDescription>
              O agente procura folga nas categorias marcadas como não essenciais.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-2">
            {raioX.gastos_categoria_3m.slice(0, 10).map((c) => (
              <div key={c.categoria} className="flex items-center justify-between gap-4 text-sm">
                <div className="flex items-center gap-2">
                  <span>{c.categoria}</span>
                  {c.grupo === "nao_essencial" && (
                    <Badge variant="outline" className="text-xs">
                      não essencial
                    </Badge>
                  )}
                </div>
                <span className="tabular text-muted-foreground">{brl(c.total)}</span>
              </div>
            ))}
          </CardContent>
        </Card>
      )}
    </div>
  );
}
