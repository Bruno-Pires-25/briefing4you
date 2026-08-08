# Lovable + GitHub + desenvolvimento local

O objetivo aqui é poder editar o projeto nos dois lados — no Lovable, pelo
prompt, e localmente, com Claude Code — sem que um sobrescreva o outro.

## Como a sincronia funciona

O Lovable mantém uma sincronia **bidirecional** com o GitHub: o que ele
escreve vai para o repositório, e o que chega no repositório aparece no editor
dele. Não é um export de uma via só.

Consequência prática: **o Git é a fonte da verdade**. Se os dois lados
editarem o mesmo arquivo antes de sincronizar, o conflito aparece no
repositório e é resolvido lá.

## Passo a passo

### 1. Publique este repositório

O código já está na branch `claude/financial-dashboard-ai-agent-ng88x2`. Faça
o merge para a `main` (ou trabalhe direto na branch, se preferir) — o Lovable
importa a branch padrão do repositório.

### 2. Crie o projeto no Lovable a partir do GitHub

No Lovable: **New Project → Import from GitHub** e escolha
`bruno-pires-25/briefing4you`.

Importar em vez de criar do zero importa porque a stack já bate exatamente com
a que o Lovable usa — Vite + React 18 + TypeScript + Tailwind + shadcn/ui, com
alias `@/` e `components.json` no lugar certo. Ele reconhece o projeto como
dele e não tenta reestruturar nada.

### 3. Configure as variáveis no Lovable

Em **Project Settings → Environment Variables**, adicione:

```
VITE_SUPABASE_URL
VITE_SUPABASE_PUBLISHABLE_KEY
VITE_AGENTE_WEBHOOK_URL
```

O `.env` local não vai para o repositório (está no `.gitignore`), então o
Lovable precisa dos valores dele.

### 4. Conecte o Supabase no Lovable

O Lovable tem integração nativa com Supabase (**Settings → Integrations →
Supabase**). Conectar dá a ele contexto do seu schema, o que melhora bastante
a qualidade do que ele gera quando você pede uma tela nova.

## Convivendo com os dois editores

A regra que evita 90% dos problemas: **um lado por vez, sempre com pull antes**.

```bash
# antes de começar a trabalhar local
git pull origin main

# ... edite, teste ...
npm test && npm run build

git add -A
git commit -m "..."
git push origin main
# aguarde o Lovable sincronizar antes de pedir algo a ele
```

E, ao contrário: depois de pedir uma alteração no Lovable, faça `git pull`
antes de voltar a editar local.

### Divisão de trabalho que funciona bem

O Lovable é forte em produzir tela: layout, componentes, variações visuais,
responsividade. É lento e impreciso em lógica de domínio.

Então: **peça telas ao Lovable, mantenha a lógica no Git.**

Concretamente, mantenha sob seu controle (e revise qualquer alteração que o
Lovable proponha nestes arquivos):

- `supabase/migrations/` — schema, RLS e o simulador
- `src/lib/parsers/` — leitura de extrato, com testes
- `src/hooks/useFinancas.ts` — as queries
- `n8n/` — o agente

E deixe o Lovable trabalhar à vontade em `src/pages/` e `src/components/`.

### Uma proteção barata

Rode os testes antes de qualquer push. Se o Lovable mexer sem querer num
parser, os 29 testes acusam na hora:

```bash
npm test && npm run build
```
