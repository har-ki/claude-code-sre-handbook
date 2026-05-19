/**
 * Load generator for the ecommerce API.
 * Sends a mix of normal and concurrent checkout requests.
 */

const API_URL = process.env.API_URL || 'http://localhost:3000';

const PRODUCTS = [
   { id: 1, stock: 50 }, { id: 2, stock: 50 }, { id: 3, stock: 50 },
   { id: 4, stock: 50 }, { id: 5, stock: 50 }, { id: 6, stock: 50 },
   { id: 7, stock: 5 },
   { id: 8, stock: 50 }, { id: 9, stock: 50 }, { id: 10, stock: 50 },
   { id: 11, stock: 50 }, { id: 12, stock: 50 },
];

function randomItem(excludeId) {
  const highStock = PRODUCTS.filter(p => p.stock > 10 && p.id !== excludeId);
  return highStock[Math.floor(Math.random() * highStock.length)];
}

async function checkout(items, label) {
  const body = {
    items,
    shipping: {
      firstName: 'Test', lastName: 'User',
      email: 'test@example.com',
      address: '123 Main St', city: 'Springfield',
      state: 'IL', zip: '62704',
     },
    payment: { cardNumber: '4111111111111111', expiry: '12/28', cvv: '123' },
   };

  try {
    const res = await fetch(`${API_URL}/api/checkout`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
     });
    const data = await res.json();
    if (res.ok) {
      console.log(`[OK]     ${label} — order ${data.orderId}`);
     } else {
      console.log(`[ERROR] ${label} — ${data.error}`);
     }
   } catch (err) {
    console.log(`[FAIL]   ${label} — ${err.message}`);
   }
}

async function resetInventory() {
   // Hit the health endpoint to confirm API is up; inventory resets on pod restart
  try {
    await fetch(`${API_URL}/api/health`);
   } catch {
    console.error('API not reachable at', API_URL);
    process.exit(1);
   }
}

async function run() {
  await resetInventory();
  let round = 0;

  while (true) {
    round++;

    const normalItem = randomItem(7);
    await checkout(
       [{ id: normalItem.id, quantity: 1 }],
       `Round ${round} normal (product ${normalItem.id})`
     );

    if (round % 3 === 0) {
      console.log(`\n--- Round ${round}: burst checkout for product 7 (Ceramic Plant Pot) ---`);
      const concurrent = Array.from({ length: 4 }, (_, i) =>
        checkout(
           [{ id: 7, quantity: 2 }],
           `Round ${round} concurrent-${i + 1} (product 7, qty 2)`
         )
       );
      await Promise.all(concurrent);
      console.log('');
     }

     // Wait between rounds
    await new Promise(resolve => setTimeout(resolve, 2000 + Math.random() * 3000));
   }
}

run().catch(console.error);
