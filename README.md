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

## API

All bodies are JSON. Money is in integer cents. Authenticated routes take
`Authorization: Bearer <token>` from `POST /auth/login`.

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/health` | – | liveness + database check |
| POST | `/auth/register` | – | create a customer account |
| POST | `/auth/login` | – | exchange email + password for an access token |
| GET | `/auth/me` | customer | the signed-in account |
| GET | `/products` | – | search the catalog (`q`, `category`, `page`, `page_size`) |
| GET | `/products/:id` | – | product detail |
| POST / PATCH / DELETE | `/products[/:id]` | admin | manage the catalog |
| GET | `/products/:id/reviews` | – | reviews and average rating of a product |
| POST | `/products/:id/reviews` | customer | review a product you bought |
| GET | `/cart` | customer | view cart |
| POST | `/cart/items` | customer | add a product to the cart |
| DELETE | `/cart/items/:productId` | customer | remove a line |
| POST | `/checkout` | customer | turn the cart into an order (optional `coupon_code`) |
| GET | `/coupons/:code` | – | what a coupon code gives |
| GET | `/orders` | customer | your orders |
| GET | `/orders/:id` | customer | order detail |
| POST | `/orders/:id/cancel` | customer | cancel an order |
| GET | `/admin/inventory/low-stock` | admin | products running low (`threshold`) |

## Coupon codes

| Code | Discount | Minimum subtotal |
|---|---|---|
| `SAVE10` | 10% | $50.00 |
| `WELCOME15` | 15% | $100.00 |
