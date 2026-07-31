/**
 * API client.
 *
 * Config comes from window.__APP_CONFIG__, which is defined by /config.js --
 * a file the container's entrypoint REWRITES at startup from environment
 * variables. That is what lets one immutable image run in dev, staging and
 * prod without a rebuild.
 *
 * Contrast with `import.meta.env.VITE_API_URL`: Vite replaces that string at
 * BUILD time, permanently baking the value into the bundle. It works, but it
 * forces one image per environment -- exactly what we are avoiding.
 */
export const config = window.__APP_CONFIG__ ?? {
  apiBaseUrl: '/api',
  appTitle: 'Docker Practice Shop',
  builtAt: 'unknown',
};

/**
 * NOTE the base URL is a RELATIVE path ("/api"), never "http://backend:3000".
 *
 * This code runs in the browser on your laptop, which is NOT attached to the
 * Docker network -- `backend` is a name only containers can resolve. The
 * browser talks to nginx; nginx, which IS on the network, forwards to the
 * backend. Same-origin also means zero CORS configuration.
 */
const url = (path) => `${config.apiBaseUrl}${path}`;

class ApiError extends Error {
  constructor(message, status) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
  }
}

async function request(path, options = {}) {
  const response = await fetch(url(path), {
    headers: { 'Content-Type': 'application/json' },
    ...options,
  });

  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new ApiError(body.error ?? `Request failed (${response.status})`, response.status);
  }

  return response.status === 204 ? null : response.json();
}

export const listItems = () => request('/items').then((data) => data.items);

export const createItem = (input) =>
  request('/items', { method: 'POST', body: JSON.stringify(input) }).then((data) => data.item);

export const deleteItem = (id) => request(`/items/${id}`, { method: 'DELETE' });

export const fetchInfo = () => request('/info');

export const fetchReadiness = () => request('/ready');

export { ApiError };
