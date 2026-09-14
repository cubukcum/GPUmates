import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  root: fileURLToPath(new URL("./control", import.meta.url)),
  base: "./",
  plugins: [react()],
  publicDir: false,
  build: {
    outDir: fileURLToPath(new URL("../coordinator/static", import.meta.url)),
    emptyOutDir: true,
    sourcemap: false,
  },
});
