import {
  Bot,
  LayoutDashboard,
  LogOut,
  ReceiptText,
  TrendingDown,
  Upload,
} from "lucide-react";
import { NavLink, Outlet } from "react-router-dom";

import { Button } from "@/components/ui/button";
import { useAuth } from "@/hooks/useAuth";
import { cn } from "@/lib/utils";

const NAV = [
  { to: "/", rotulo: "Painel", Icone: LayoutDashboard, exato: true },
  { to: "/dividas", rotulo: "Dívidas", Icone: TrendingDown },
  { to: "/transacoes", rotulo: "Transações", Icone: ReceiptText },
  { to: "/importar", rotulo: "Importar", Icone: Upload },
  { to: "/agente", rotulo: "Agente", Icone: Bot },
];

export function AppShell() {
  const { user, sair } = useAuth();

  return (
    <div className="min-h-screen bg-background">
      <header className="sticky top-0 z-40 border-b bg-background/95 backdrop-blur">
        <div className="container flex h-16 items-center justify-between gap-4">
          <div className="flex items-center gap-6">
            <span className="text-lg font-semibold tracking-tight">FinBR</span>

            <nav className="flex items-center gap-1">
              {NAV.map(({ to, rotulo, Icone, exato }) => (
                <NavLink
                  key={to}
                  to={to}
                  end={exato}
                  className={({ isActive }) =>
                    cn(
                      "inline-flex items-center gap-2 rounded-md px-3 py-2 text-sm font-medium transition-colors",
                      isActive
                        ? "bg-secondary text-secondary-foreground"
                        : "text-muted-foreground hover:bg-accent hover:text-accent-foreground",
                    )
                  }
                >
                  <Icone className="size-4" />
                  <span className="hidden sm:inline">{rotulo}</span>
                </NavLink>
              ))}
            </nav>
          </div>

          <div className="flex items-center gap-3">
            <span className="hidden text-sm text-muted-foreground md:inline">{user?.email}</span>
            <Button variant="ghost" size="icon" onClick={sair} aria-label="Sair">
              <LogOut className="size-4" />
            </Button>
          </div>
        </div>
      </header>

      <main className="container py-8">
        <Outlet />
      </main>
    </div>
  );
}
