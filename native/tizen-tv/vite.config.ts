import { resolve } from "node:path";
import { defineConfig } from "vite";

export default defineConfig({
  base: "./",
  build: {
    outDir: "dist",
    emptyOutDir: true,
    target: "es2015",
    modulePreload: false,
    cssCodeSplit: false,
    rollupOptions: {
      input: resolve(__dirname, "index.html"),
    },
  },
});
