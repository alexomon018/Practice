import React from 'react';
import ReactDOM from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';

import App from './App.jsx';
import './style.css';

/**
 * A single QueryClient for the whole app -- it owns the in-memory server-state
 * cache. Created OUTSIDE the component tree so a re-render never throws the
 * cache away.
 */
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      // How long fetched data is considered fresh. Within this window,
      // remounting a component reads the cache instead of hitting nginx.
      staleTime: 10_000,

      // Retry transient failures. Relevant here: when you `docker compose stop
      // backend`, nginx returns our custom 503 page and Query will retry --
      // then recover on its own once the container is back. Try it.
      retry: (failureCount, error) => {
        // 4xx means WE sent something wrong; retrying cannot help.
        if (error?.status >= 400 && error?.status < 500) return false;
        return failureCount < 3;
      },
      retryDelay: (attempt) => Math.min(1000 * 2 ** attempt, 8000),

      refetchOnWindowFocus: true,
    },
  },
});

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <App />
    </QueryClientProvider>
  </React.StrictMode>
);
