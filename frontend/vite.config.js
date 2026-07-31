import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],

  build: {
    // Everything under public/ is copied verbatim into dist/ -- including
    // config.js, which the container entrypoint overwrites at startup.
    // Files here are NOT hashed, which is precisely why it can be replaced.
    outDir: 'dist',
    emptyOutDir: true,
    // Source maps make production stack traces readable. They are separate
    // .map files, so they cost image size but not download size (browsers
    // only fetch them when devtools is open).
    sourcemap: true,
  },

  server: {
    // Only used by `npm run dev` on the host -- the built image is static.
    port: 5173,
    proxy: {
      // Mirrors what the edge nginx does in Docker, so local dev and the
      // containerised app hit the same relative /api path.
      '/api': 'http://localhost:8080',
    },
  },
});
