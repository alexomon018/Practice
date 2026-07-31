import { useEffect, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';

import { config, listItems, createItem, deleteItem, fetchInfo } from './api.js';

const money = (cents) => `€${(cents / 100).toFixed(2)}`;

export default function App() {
  useEffect(() => {
    // Title comes from an env var read at container startup, not build time.
    document.title = config.appTitle;
  }, []);

  return (
    <div className="app">
      <Topbar />
      <main>
        <AddItemForm />
        <ItemList />
        <RuntimeInfo />
      </main>
    </div>
  );
}

function Topbar() {
  // Polls /api/info so you can watch the answering container change when you
  // run: docker compose up -d --scale backend=3
  const { data } = useQuery({
    queryKey: ['info'],
    queryFn: fetchInfo,
    refetchInterval: 5_000,
  });

  return (
    <header className="topbar">
      <h1>{config.appTitle}</h1>
      <span className="pill" title="Hostname of the backend container that answered">
        {data ? `backend: ${data.servedBy.slice(0, 12)}` : 'connecting…'}
      </span>
    </header>
  );
}

function AddItemForm() {
  const queryClient = useQueryClient();
  const [form, setForm] = useState({ name: '', description: '', price: '' });

  const mutation = useMutation({
    mutationFn: createItem,
    onSuccess: () => {
      // Mark the cached list stale so Query refetches it. We deliberately do
      // NOT hand-patch the cache: the server owns id and created_at, and
      // re-reading is the honest source of truth.
      queryClient.invalidateQueries({ queryKey: ['items'] });
      setForm({ name: '', description: '', price: '' });
    },
  });

  const update = (field) => (event) => setForm((prev) => ({ ...prev, [field]: event.target.value }));

  const submit = (event) => {
    event.preventDefault();
    mutation.mutate({
      name: form.name,
      description: form.description,
      // Prices travel as integer cents. Floats cannot represent 0.10 exactly,
      // and money that drifts by a cent per row is a real bug, not a rounding
      // curiosity -- see the price_cents column in db/init/01_schema.sql.
      priceCents: Math.round(Number(form.price || 0) * 100),
    });
  };

  return (
    <section className="card">
      <h2>Add an item</h2>
      <form onSubmit={submit}>
        <input value={form.name} onChange={update('name')} placeholder="Name" required maxLength={80} />
        <input value={form.description} onChange={update('description')} placeholder="Description" maxLength={200} />
        <input value={form.price} onChange={update('price')} type="number" min="0" step="0.01" placeholder="Price" />
        <button type="submit" disabled={mutation.isPending}>
          {mutation.isPending ? 'Saving…' : 'Add'}
        </button>
      </form>
      {mutation.isError && <p className="error">{mutation.error.message}</p>}
    </section>
  );
}

function ItemList() {
  const queryClient = useQueryClient();

  const { data: items, isPending, isError, error, isFetching } = useQuery({
    queryKey: ['items'],
    queryFn: listItems,
  });

  const removal = useMutation({
    mutationFn: deleteItem,
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['items'] }),
  });

  if (isPending) return <section className="card"><h2>Items</h2><p className="muted">Loading…</p></section>;

  if (isError) {
    return (
      <section className="card">
        <h2>Items</h2>
        {/* When the backend is stopped, the edge nginx returns the custom 503
            from nginx/conf.d/default.conf and this is what surfaces it. */}
        <p className="error">Cannot reach the API: {error.message}</p>
        <p className="muted">Try: <code>docker compose logs -f backend nginx</code></p>
      </section>
    );
  }

  return (
    <section className="card">
      <h2>
        Items <span className="pill">{items.length}</span>
        {isFetching && <span className="pill">refreshing…</span>}
      </h2>
      <ul>
        {items.map((item) => (
          <li key={item.id} className="item">
            <div>
              <strong>{item.name}</strong>
              {item.description && <small>{item.description}</small>}
            </div>
            <div className="right">
              <span className="price">{money(item.price_cents)}</span>
              <button
                className="delete"
                aria-label={`Delete ${item.name}`}
                onClick={() => removal.mutate(item.id)}
                disabled={removal.isPending}
              >
                ×
              </button>
            </div>
          </li>
        ))}
      </ul>
      {items.length === 0 && <p className="muted">No items yet.</p>}
    </section>
  );
}

function RuntimeInfo() {
  const { data } = useQuery({ queryKey: ['info'], queryFn: fetchInfo });

  return (
    <section className="card">
      <h2>Runtime info</h2>
      {/* Proof that env vars reached BOTH tiers: `frontend` values were
          injected into config.js at container start, `backend` values came
          from process.env inside the API container. */}
      <pre>{JSON.stringify({ frontend: config, backend: data ?? 'loading…' }, null, 2)}</pre>
    </section>
  );
}
