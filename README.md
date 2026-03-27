# shopfront-api

The HTTP API behind the Shopfront online store: customer accounts, a product catalog, a shopping cart and checkout.
Node 20 + TypeScript + Express, backed by PostgreSQL.

## Run locally

```bash
docker compose up --build
```

or, with a PostgreSQL you already have:

```bash
npm install
DATABASE_URL=postgresql://app:app@localhost:5432/shopfront JWT_SECRET=change-me PORT=3000 npm run dev
```

The schema (`db/schema.sql`) is applied on startup and seeds a starter catalog of 240 products.

| Variable | Required | Purpose |
|---|---|---|
| `DATABASE_URL` | yes | PostgreSQL connection string |
| `JWT_SECRET` | yes | secret used to sign access tokens |
| `PORT` | no | listen port (default `3000`) |

## Coupon codes

| Code | Discount | Minimum subtotal |
|---|---|---|
| `SAVE10` | 10% | $50.00 |
| `WELCOME15` | 15% | $100.00 |
