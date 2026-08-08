import { useMemo, useState } from "react";

import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input, Select } from "@/components/ui/input";
import { useCategorias, useTransacoes } from "@/hooks/useFinancas";
import { brl, dataBr } from "@/lib/format";
import { normalizarDescricao } from "@/lib/parsers/normalizar";

export default function Transacoes() {
  const { data: transacoes, isLoading } = useTransacoes(500);
  const { data: categorias } = useCategorias();

  const [busca, setBusca] = useState("");
  const [filtroTipo, setFiltroTipo] = useState<"todos" | "credito" | "debito">("todos");

  const porId = useMemo(
    () => new Map((categorias ?? []).map((c) => [c.id, c])),
    [categorias],
  );

  const filtradas = useMemo(() => {
    // Busca contra a descrição normalizada: quem digita "sao jose" acha
    // "Padaria São José" sem precisar acertar acento e caixa.
    const alvo = normalizarDescricao(busca);

    return (transacoes ?? []).filter((t) => {
      if (filtroTipo !== "todos" && t.tipo !== filtroTipo) return false;
      if (!alvo) return true;
      return t.descricao_normalizada.includes(alvo);
    });
  }, [transacoes, busca, filtroTipo]);

  const total = filtradas.reduce((s, t) => s + Number(t.valor), 0);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Transações</h1>
        <p className="text-sm text-muted-foreground">
          Tudo que entrou e saiu, das mais recentes para as mais antigas.
        </p>
      </div>

      <div className="flex flex-wrap gap-3">
        <Input
          placeholder="Buscar por descrição…"
          value={busca}
          onChange={(e) => setBusca(e.target.value)}
          className="max-w-xs"
        />
        <Select
          value={filtroTipo}
          onChange={(e) => setFiltroTipo(e.target.value as typeof filtroTipo)}
          className="max-w-[12rem]"
        >
          <option value="todos">Entradas e saídas</option>
          <option value="credito">Só entradas</option>
          <option value="debito">Só saídas</option>
        </Select>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">
            {filtradas.length} lançamento(s)
          </CardTitle>
          <CardDescription>
            Soma do que está sendo exibido: <span className="tabular">{brl(total)}</span>
          </CardDescription>
        </CardHeader>

        <CardContent>
          {isLoading ? (
            <p className="text-muted-foreground">Carregando…</p>
          ) : filtradas.length === 0 ? (
            <p className="text-muted-foreground">
              Nada por aqui. Importe um extrato na aba <strong>Importar</strong>.
            </p>
          ) : (
            <div className="overflow-x-auto rounded-lg border">
              <table className="w-full text-sm">
                <thead className="bg-muted text-left">
                  <tr>
                    <th className="p-3 font-medium">Data</th>
                    <th className="p-3 font-medium">Descrição</th>
                    <th className="p-3 font-medium">Categoria</th>
                    <th className="p-3 text-right font-medium">Valor</th>
                  </tr>
                </thead>
                <tbody>
                  {filtradas.map((t) => {
                    const cat = t.categoria_id ? porId.get(t.categoria_id) : undefined;
                    return (
                      <tr key={t.id} className="border-t hover:bg-accent/40">
                        <td className="whitespace-nowrap p-3 text-muted-foreground">
                          {dataBr(t.data)}
                        </td>
                        <td className="p-3">{t.descricao}</td>
                        <td className="p-3">
                          {cat ? (
                            <Badge variant="outline">{cat.nome}</Badge>
                          ) : (
                            <span className="text-xs text-muted-foreground">sem categoria</span>
                          )}
                        </td>
                        <td
                          className={`tabular whitespace-nowrap p-3 text-right font-medium ${
                            Number(t.valor) > 0 ? "text-positive" : "text-negative"
                          }`}
                        >
                          {brl(Number(t.valor))}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
