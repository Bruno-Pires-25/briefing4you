# Extratos: formatos, duplicidade e o caminho para a API

## Por que OFX é o formato preferido

OFX (Open Financial Exchange) traz o **`FITID`** — um identificador único da
transação, atribuído pelo próprio banco e estável entre downloads.

Isso resolve o problema mais chato de importar extrato: reimportar o mesmo
período sem duplicar tudo. O banco tem índice único em `(conta_id, fitid)`, e a
importação usa `upsert` com `ignoreDuplicates`. Reimportar é seguro.

Onde achar no seu banco: procure por **OFX**, **Money**, **OFX/Money** ou
"Microsoft Money" na tela de exportação de extrato. Quase todo banco brasileiro
oferece, mesmo quando o formato mais visível é PDF ou Excel.

## CSV: funciona, com uma ressalva honesta

CSV não tem identificador de transação. O parser calcula um `hash_dedupe` a
partir de data + valor + descrição normalizada, mas **isso não é identidade**:
duas compras de R$ 12,00 na mesma padaria no mesmo dia geram o mesmo hash e as
duas são reais.

Por isso o hash **sinaliza** possível duplicata na revisão, mas não descarta
nada sozinho. A tela avisa antes de você confirmar.

### O que o parser de CSV aguenta

Não existe padrão de CSV bancário no Brasil, então o parser detecta tudo a
partir do conteúdo:

- **Delimitador** — `;`, `,`, tab ou `|`, escolhido pelo que produz colunas
  mais consistentes (contar vírgulas erraria, porque `1.234,56` tem vírgula)
- **Preâmbulo** — pula linhas institucionais até achar a linha que tem data e
  valor
- **Colunas** — reconhece variações comuns: `Data`/`Data Lançamento`,
  `Histórico`/`Descrição`/`Lançamento`, `Valor` ou o par `Débito`/`Crédito`
- **Datas** — `dd/mm/aaaa`, `dd/mm/aa`, `aaaa-mm-dd`
- **Valores** — `R$ 1.234,56`, `1234.56`, `(150,00)` (negativo contábil),
  `150,00 D` (sufixo de débito)
- **Aspas** — campos com o delimitador dentro
- **Rodapé** — descarta linhas de totalizador e saldo final

## Codificação

Muito OFX brasileiro ainda sai em **ISO-8859-1 / Windows-1252**, não UTF-8.
Lido como UTF-8, "SALÁRIO" vira "SAL�RIO" e a descrição fica quebrada
permanentemente no banco.

O leitor inspeciona o cabeçalho `CHARSET:` do OFX e decodifica de acordo. Sem
declaração, ele tenta UTF-8 e, se aparecer caractere de substituição, refaz em
Windows-1252.

## Normalização da descrição

Extrato vem cheio de ruído que muda a cada linha: NSU, número de documento,
data embutida, código de autorização, número da parcela. Se as regras de
categorização casassem contra o texto cru, cada compra no mesmo mercado seria
uma string diferente.

```
"COMPRA CARTAO MERCADO BOM PRECO NSU 445566"  ─┐
                                               ├─▶  "compra cartao mercado bom preco"
"COMPRA CARTAO MERCADO BOM PRECO NSU 998811"  ─┘
```

O resultado vai em `transacoes.descricao_normalizada`, e é contra ela que as
`regras_categorizacao` casam. A descrição original é preservada intacta em
`descricao`.

A ordem das regras de limpeza importa: parcelamento é removido **antes** de
data, senão o padrão de data engole o `03/12` de "PARC 03/12" e sobra um
`parc` órfão na chave. Tem teste cobrindo exatamente isso.

## Plugando a API depois (Pluggy / Open Finance)

O caminho está aberto e **não exige refazer nada**. A tabela `transacoes` já
tem `origem = 'api'` no enum e o campo `metadata jsonb` para guardar o payload
do provedor.

Esboço do que seria preciso:

1. **Conta no [Pluggy](https://pluggy.ai)** — é o agregador com melhor cobertura
   de bancos PF no Brasil. Tem sandbox gratuito para desenvolver.
2. **Pluggy Connect no painel** — o widget onde o usuário autoriza o acesso à
   conta dele. Você guarda o `itemId` retornado.
3. **Tabela `conexoes_bancarias`** — `user_id`, `conta_id`, `provedor`,
   `item_id`, `status`, `ultima_sincronizacao`.
4. **Workflow no n8n** — Schedule Trigger diário que, para cada conexão ativa,
   chama `GET /transactions?itemId=...` e grava em `transacoes` com
   `origem = 'api'` e `fitid` = o id da transação no Pluggy (o índice único de
   dedupe passa a valer para a API também, de graça).
5. **Webhook do Pluggy** — o provedor avisa quando há transação nova, o que
   evita ficar varrendo a API sem necessidade.

Os segredos (client id e secret do Pluggy) ficam nas credenciais do n8n, nunca
no frontend.

Uma ressalva que vale saber antes de investir nisso: a conexão via Open Finance
**expira** e o usuário precisa reautorizar periodicamente. O painel vai
precisar de uma tela mostrando quais conexões estão vencidas — e o upload de
OFX continua sendo o plano B para quando isso acontecer. Não jogue fora a tela
de importação.
