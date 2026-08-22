import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Where the drill server is, per the container-sandbox skill's API_PROXY_TARGET
// rule. `make -f Makefile.test drill-dev` runs the server and Vite in the same
// container, so the default is loopback rather than the host.
const target = process.env.API_PROXY_TARGET ?? "http://127.0.0.1:8090";

export default defineConfig({
  plugins: [react()],
  server: {
    host: "0.0.0.0",
    proxy: {
      "/api": { target, changeOrigin: true },
      "/ws": { target: target.replace(/^http/, "ws"), ws: true },
    },
  },
  build: { outDir: "dist", emptyOutDir: true },
});
