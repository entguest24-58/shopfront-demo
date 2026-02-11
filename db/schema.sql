CREATE TABLE IF NOT EXISTS users (
  id            SERIAL PRIMARY KEY,
  email         TEXT        NOT NULL UNIQUE,
  name          TEXT        NOT NULL,
  password_hash TEXT        NOT NULL,
  role          TEXT        NOT NULL DEFAULT 'customer',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS products (
  id          SERIAL PRIMARY KEY,
  sku         TEXT        NOT NULL UNIQUE,
  name        TEXT        NOT NULL,
  description TEXT        NOT NULL DEFAULT '',
  category    TEXT        NOT NULL,
  price_cents INTEGER     NOT NULL CHECK (price_cents >= 0),
  stock       INTEGER     NOT NULL DEFAULT 0 CHECK (stock >= 0),
  active      BOOLEAN     NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cart_items (
  user_id    INTEGER     NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  product_id INTEGER     NOT NULL REFERENCES products(id),
  quantity   INTEGER     NOT NULL CHECK (quantity > 0),
  added_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, product_id)
);

CREATE TABLE IF NOT EXISTS orders (
  id             SERIAL PRIMARY KEY,
  user_id        INTEGER     NOT NULL REFERENCES users(id),
  status         TEXT        NOT NULL DEFAULT 'placed',
  subtotal_cents INTEGER     NOT NULL,
  discount_cents INTEGER     NOT NULL DEFAULT 0,
  tax_cents      INTEGER     NOT NULL,
  total_cents    INTEGER     NOT NULL,
  coupon_code    TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS order_items (
  order_id         INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id       INTEGER NOT NULL REFERENCES products(id),
  name             TEXT    NOT NULL,
  unit_price_cents INTEGER NOT NULL,
  quantity         INTEGER NOT NULL,
  PRIMARY KEY (order_id, product_id)
);

-- Starter catalog so a fresh environment has something to browse.
INSERT INTO products (sku, name, description, category, price_cents, stock)
SELECT
  'SKU-' || lpad(g::text, 4, '0'),
  (ARRAY['Trail', 'City', 'Studio', 'Summit', 'Harbor', 'Canyon'])[1 + g % 6] || ' ' ||
    (ARRAY['Backpack', 'Water Bottle', 'Headphones', 'Desk Lamp', 'Notebook', 'Sneakers', 'Jacket', 'Mug'])[1 + g % 8],
  'Everyday gear, item ' || g,
  (ARRAY['bags', 'kitchen', 'audio', 'home', 'stationery', 'footwear', 'apparel'])[1 + g % 7],
  499 + (g * 137) % 15000,
  (g * 7) % 40
FROM generate_series(1, 240) AS g
ON CONFLICT (sku) DO NOTHING;
