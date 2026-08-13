
INSERT INTO items (name, description, price_cents) VALUES
    ('Container Mug',      'Holds 500ml of coffee. Does not hold state.',        1290),
    ('Volume Notebook',    'Persists your notes across restarts.',               890),
    ('Bridge Network Cap', 'One size resolves all.',                             2450),
    ('Multi-stage T-Shirt','Built large, shipped small.',                        1990);

INSERT INTO request_audit (action, detail) VALUES
    ('db_initialised', 'schema + seed applied by docker-entrypoint-initdb.d');
