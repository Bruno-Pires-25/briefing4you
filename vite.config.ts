import path from "path";
import react from "@vitejs/plugin-react-swc";
import { defineConfig } from "vite";

export default defineConfig(({ mode }) => ({
  server: {
    host: "::",
    port: 8080,
  },
  plugins: [react()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  define: {
    __DEV__: mode !== "production",
  },
  build: {
    rollupOptions: {
      output: {
        // Separa as três dependências pesadas do código da aplicação. Sem
        // isso tudo vira um chunk único de ~1 MB, e qualquer alteração de
        // página invalida o cache do navegador para o bundle inteiro.
        manualChunks: {
          react: ["react", "react-dom", "react-router-dom"],
          charts: ["recharts"],
          supabase: ["@supabase/supabase-js"],
        },
      },
    },
  },
}));
