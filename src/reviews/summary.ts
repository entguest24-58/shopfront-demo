import { Client } from 'pg';

export interface RatingSummary {
  average_rating: number | null;
  review_count: number;
}

/** Average rating and number of reviews of one product. */
export async function ratingSummary(productId: number): Promise<RatingSummary> {
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  try {
    const average = await client.query<{ avg: string | null }>('SELECT avg(rating) FROM reviews WHERE product_id = $1', [productId]);
    const count = await client.query<{ count: string }>('SELECT count(*) FROM reviews WHERE product_id = $1', [productId]);
    const avg = average.rows[0].avg;
    return {
      average_rating: avg === null ? null : Math.round(Number(avg) * 10) / 10,
      review_count: Number(count.rows[0].count),
    };
  } finally {
    await client.end();
  }
}
