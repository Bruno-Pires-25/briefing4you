import { AlertTriangle, CheckCircle2, FileUp } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { FormNovaConta } from "@/components/contas/FormNovaConta";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Select } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useAuth } from "@/hooks/useAuth";
import { useContas } from "@/hooks/useFinancas";
import { brl, dataBr } from "@/lib/format";
import { lerArquivoDeExtrato } from "@/lib/parsers";
import type { ResultadoParse } from "@/lib/parsers/tipos";
import { supabase } from "@/lib/supabase";
import { useQueryClient } from "@tanstack/react-query";

export default function Importar() {
  const { user } = useAuth();
  const { data: contas } = useContas();
  const qc = useQueryClient();

  const [resultado, setResultado] = useState<ResultadoParse | null>(null);
  const [nomeArquivo, setNomeArquivo] = useState("");
  const [contaId, setContaId] = useState("");
  const [erro, setErro] = useState<{ mensagem: string; sugestao?: string } | null>(null);
  const [gravando, setGravando] = useState(false);

  async function aoEscolherArquivo(e: React.ChangeEvent<HTMLInputElement>) {
    const arquivo = e.target.files?.[0];
    if (!arquivo) return;

    setErro(null);
    setResultado(null);
    setNomeArquivo(arquivo.name);

    try {
      const r = await lerArquivoDeExtrato(arquivo);
      setResultado(r);

      // Se o OFX declara a conta e já existe uma cadastrada com esse número,
      // pré-seleciona — evita o erro clássico de importar na conta errada.
      const casada = contas?.find(
        (c) => r.conta.numeroConta && c.apelido.includes(r.conta.numeroConta),
      );
      if (casada) setContaId(casada.id);
    } catch (err) {
      const e2 = err as { message?: string; sugestao?: string };
      setErro({ mensagem: e2.message ?? "Não consegui ler o arquivo.", sugestao: e2.sugestao });
    }
  }

  async function confirmar() {
    if (!resultado || !contaId || !user) return;
    setGravando(true);

    try {
      const { data: imp, error: erroImp } = await supabase
        .from("importacoes")
        .insert({
          user_id: user.id,
          conta_id: contaId,
          arquivo_nome: nomeArquivo,
          formato: resultado.formato,
          status: "processando",
          periodo_inicio: resultado.periodoInicio,
          periodo_fim: resultado.periodoFim,
          linhas_lidas: resultado.lancamentos.length,
        })
        .select()
        .single();

      if (erroImp) throw erroImp;

      const linhas = resultado.lancamentos.map((l) => ({
        user_id: user.id,
        conta_id: contaId,
        importacao_id: imp.id,
        data: l.data,
        descricao: l.descricao,
        descricao_normalizada: l.descricaoNormalizada,
        valor: l.valor,
        origem: resultado.formato,
        fitid: l.fitid ?? null,
        hash_dedupe: l.hashDedupe,
      }));

      // upsert com ignoreDuplicates: o índice único (conta_id, fitid) descarta
      // silenciosamente o que já foi importado antes. É o que torna reimportar
      // o mesmo OFX uma operação segura em vez de destrutiva.
      const { data: inseridas, error: erroTx } = await supabase
        .from("transacoes")
        .upsert(linhas, { onConflict: "conta_id,fitid", ignoreDuplicates: true })
        .select("id");

      if (erroTx) throw erroTx;

      const importadas = inseridas?.length ?? 0;
      const duplicadas = linhas.length - importadas;

      await supabase
        .from("importacoes")
        .update({
          status: resultado.avisos.length > 0 ? "concluida_com_avisos" : "concluida",
          linhas_importadas: importadas,
          linhas_duplicadas: duplicadas,
        })
        .eq("id", imp.id);

      toast.success(
        duplicadas > 0
          ? `${importadas} lançamento(s) importado(s). ${duplicadas} já existiam e foram ignorados.`
          : `${importadas} lançamento(s) importado(s).`,
      );

      qc.invalidateQueries({ queryKey: ["transacoes"] });
      qc.invalidateQueries({ queryKey: ["raio-x"] });
      setResultado(null);
      setNomeArquivo("");
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Falha ao gravar os lançamentos.");
    } finally {
      setGravando(false);
    }
  }

  const entradas = resultado?.lancamentos.filter((l) => l.valor > 0) ?? [];
  const saidas = resultado?.lancamentos.filter((l) => l.valor < 0) ?? [];
  const somaEntradas = entradas.reduce((s, l) => s + l.valor, 0);
  const somaSaidas = saidas.reduce((s, l) => s + l.valor, 0);

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Importar extrato</h1>
        <p className="text-sm text-muted-foreground">
          Baixe o extrato no site ou app do banco em <strong>OFX</strong> (às vezes aparece como
          "Money" ou "OFX/Money") e solte o arquivo aqui. CSV também funciona.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">1. Escolha o arquivo</CardTitle>
          <CardDescription>
            O arquivo é lido no seu navegador. Só os lançamentos vão para o banco de dados — o
            arquivo em si não é enviado a lugar nenhum.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <label className="flex cursor-pointer flex-col items-center justify-center gap-2 rounded-lg border-2 border-dashed p-10 text-center transition-colors hover:bg-accent">
            <FileUp className="size-8 text-muted-foreground" />
            <span className="text-sm font-medium">
              {nomeArquivo || "Clique para escolher um arquivo .ofx ou .csv"}
            </span>
            <input
              type="file"
              accept=".ofx,.csv,.txt,text/csv"
              className="hidden"
              onChange={aoEscolherArquivo}
            />
          </label>
        </CardContent>
      </Card>

      {erro && (
        <Card className="border-destructive/50">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-base text-destructive">
              <AlertTriangle className="size-4" />
              {erro.mensagem}
            </CardTitle>
            {erro.sugestao && <CardDescription>{erro.sugestao}</CardDescription>}
          </CardHeader>
        </Card>
      )}

      {resultado && (
        <>
          <Card>
            <CardHeader>
              <CardTitle className="text-base">2. Confira antes de gravar</CardTitle>
              <CardDescription>
                {resultado.lancamentos.length} lançamento(s) de{" "}
                {dataBr(resultado.periodoInicio)} a {dataBr(resultado.periodoFim)}, formato{" "}
                {resultado.formato.toUpperCase()}.
              </CardDescription>
            </CardHeader>

            <CardContent className="space-y-4">
              <div className="grid gap-4 sm:grid-cols-3">
                <div className="rounded-lg border p-4">
                  <p className="text-xs text-muted-foreground">Entradas</p>
                  <p className="tabular text-lg font-semibold text-positive">
                    {brl(somaEntradas)}
                  </p>
                  <p className="text-xs text-muted-foreground">{entradas.length} lançamento(s)</p>
                </div>
                <div className="rounded-lg border p-4">
                  <p className="text-xs text-muted-foreground">Saídas</p>
                  <p className="tabular text-lg font-semibold text-negative">{brl(somaSaidas)}</p>
                  <p className="text-xs text-muted-foreground">{saidas.length} lançamento(s)</p>
                </div>
                <div className="rounded-lg border p-4">
                  <p className="text-xs text-muted-foreground">Resultado do período</p>
                  <p className="tabular text-lg font-semibold">
                    {brl(somaEntradas + somaSaidas)}
                  </p>
                  {resultado.conta.saldo !== undefined && (
                    <p className="text-xs text-muted-foreground">
                      saldo no banco: {brl(resultado.conta.saldo)}
                    </p>
                  )}
                </div>
              </div>

              {resultado.avisos.length > 0 && (
                <div className="space-y-2 rounded-lg border border-warning/40 bg-warning/5 p-4">
                  {resultado.avisos.map((a, i) => (
                    <p key={i} className="flex items-start gap-2 text-sm">
                      <AlertTriangle className="mt-0.5 size-4 shrink-0 text-warning" />
                      <span>{a}</span>
                    </p>
                  ))}
                </div>
              )}

              <div className="space-y-2">
                <Label htmlFor="conta">Conta de destino</Label>
                <Select id="conta" value={contaId} onChange={(e) => setContaId(e.target.value)}>
                  <option value="">Selecione…</option>
                  {contas?.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.apelido} {c.instituicao ? `— ${c.instituicao}` : ""}
                    </option>
                  ))}
                </Select>
                {(!contas || contas.length === 0) && (
                  <p className="text-xs text-muted-foreground">
                    Você ainda não tem contas cadastradas. Crie uma antes de importar.
                  </p>
                )}
                <FormNovaConta />
              </div>

              <div className="max-h-80 overflow-y-auto rounded-lg border">
                <table className="w-full text-sm">
                  <thead className="sticky top-0 bg-muted">
                    <tr className="text-left">
                      <th className="p-2 font-medium">Data</th>
                      <th className="p-2 font-medium">Descrição</th>
                      <th className="p-2 text-right font-medium">Valor</th>
                    </tr>
                  </thead>
                  <tbody>
                    {resultado.lancamentos.slice(0, 200).map((l, i) => (
                      <tr key={`${l.fitid ?? l.hashDedupe}-${i}`} className="border-t">
                        <td className="whitespace-nowrap p-2 text-muted-foreground">
                          {dataBr(l.data)}
                        </td>
                        <td className="p-2">
                          {l.descricao}
                          {!l.fitid && (
                            <Badge variant="outline" className="ml-2 text-xs">
                              sem ID
                            </Badge>
                          )}
                        </td>
                        <td
                          className={`tabular whitespace-nowrap p-2 text-right ${
                            l.valor > 0 ? "text-positive" : "text-negative"
                          }`}
                        >
                          {brl(l.valor)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
                {resultado.lancamentos.length > 200 && (
                  <p className="border-t p-2 text-center text-xs text-muted-foreground">
                    Mostrando os 200 primeiros de {resultado.lancamentos.length}. Todos serão
                    importados.
                  </p>
                )}
              </div>

              <Button onClick={confirmar} disabled={!contaId || gravando} className="w-full">
                <CheckCircle2 className="size-4" />
                {gravando
                  ? "Gravando…"
                  : `Importar ${resultado.lancamentos.length} lançamento(s)`}
              </Button>
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}
