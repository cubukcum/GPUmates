import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const projectRoot = fileURLToPath(new URL(".", import.meta.url));

export default defineConfig({
  root: fileURLToPath(new URL("./local", import.meta.url)),
  base: "./",
  plugins: [react()],
  publicDir: fileURLToPath(new URL("./public", import.meta.url)),
  build: {
    outDir: fileURLToPath(new URL("./static", import.meta.url)),
    emptyOutDir: true,
    sourcemap: false,
  },
  resolve: { alias: { "@gpumates": projectRoot } },
});
