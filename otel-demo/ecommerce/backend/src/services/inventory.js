const { trace, SpanStatusCode } = require('@opentelemetry/api');
const { logs, SeverityNumber } = require('@opentelemetry/api-logs');

const logger = logs.getLogger('ecommerce-api');
const tracer = trace.getTracer('ecommerce-api');

const PRODUCT_NAMES = {
    1: 'Wireless Headphones', 2: 'Smart Watch', 3: 'Laptop Stand',
    4: 'Cotton T-Shirt', 5: 'Denim Jeans', 6: 'Running Shoes',
    7: 'Ceramic Plant Pot', 8: 'LED Desk Lamp', 9: 'Throw Blanket',
    10: 'Bluetooth Speaker', 11: 'Winter Jacket', 12: 'Coffee Maker',
};

// In-memory inventory store — simulates a database table
const inventory = {
    1: 50, 2: 50, 3: 50, 4: 50, 5: 50, 6: 50,
    7: 5,        // Ceramic Plant Pot — limited stock
    8: 50, 9: 50, 10: 50, 11: 50, 12: 50,
};

// Async lock per product to prevent TOCTOU race conditions.
// Without this, concurrent requests can both read the same stock value
// before either decrements, leading to overselling (e.g. stock goes
// negative or errors even when total stock was sufficient).
const locks = new Map();

/**
 * Acquire an async mutex for a specific product.
 * Returns a release() function that must be called when done.
 */
async function acquireLock(productId) {
  if (!locks.has(productId)) {
    locks.set(productId, { queue: [] });
  }
  const lock = locks.get(productId);
  // Wait for all prior waiters to finish before taking the lock
  while (lock.queue.length > 0) {
    await new Promise(resolve => lock.queue.push(resolve));
  }
  return () => {
    const next = lock.queue.shift();
    if (next) next();
  };
}

/** Simulate async DB read */
async function getStock(productId) {
  await new Promise(resolve => setTimeout(resolve, 5));
  return inventory[productId];
}

/** Reserve inventory for the given items. */
async function reserveInventory(items) {
  return tracer.startActiveSpan('reserveInventory', async (span) => {
    const reserved = [];

    try {
      for (const item of items) {
        const productName = PRODUCT_NAMES[item.id] || `Product ${item.id}`;
        span.setAttribute(`product.${item.id}.name`, productName);
        span.setAttribute(`product.${item.id}.requested`, item.quantity);

        // ---- read current stock ----
        const currentStock = await getStock(item.id);
        span.setAttribute(`product.${item.id}.stock_before`, currentStock);

        if (currentStock < item.quantity) {
          const err = new Error(
              `Insufficient stock for product ${item.id} (${productName}): ` +
               `requested ${item.quantity}, available ${currentStock}`
          );
          span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
          span.recordException(err);
          throw err;
        }

        // Simulate async DB write / validation
        await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));

        // Acquire per-product lock to make the check-and-decrement atomic.
        // This ensures the stock value hasn't changed between the
        // initial read (line ~42) and now — preventing the TOCTOU race
        // where two concurrent requests both pass the check.
        const release = await acquireLock(item.id);
        try {
          // Re-check stock while holding the lock (double-check pattern)
          if (inventory[item.id] < item.quantity) {
            const err = new Error(
                `Insufficient stock for product ${item.id} (${productName}): ` +
                 `requested ${item.quantity}, available ${inventory[item.id]}`
            );
            span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
            span.recordException(err);
            throw err;
          }

          inventory[item.id] -= item.quantity;
          const newStock = inventory[item.id];

          if (newStock < 0) {
            const err = new Error(
                `Inventory inconsistency: stock for product ${item.id} ` +
                 `(${productName}) is ${newStock} after decrement ` +
                 `(was ${currentStock} at read time)`
            );
            err.productId = item.id;
            err.finalStock = newStock;

            logger.emit({
              severityNumber: SeverityNumber.ERROR,
              severityText: 'ERROR',
              body: err.message,
              attributes: {
                  'exception.type': 'StockMismatchError',
                  'exception.message': err.message,
                  'exception.stacktrace': err.stack,
                  'product.id': String(item.id),
                  'product.name': productName,
                  'stock.expected': String(currentStock - item.quantity),
                  'stock.actual': String(newStock),
                },
            });

            span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
            span.recordException(err);
            throw err;
          }

          logger.emit({
            severityNumber: SeverityNumber.INFO,
            severityText: 'INFO',
            body: `Reserved ${item.quantity} unit(s) of ${productName} — stock: ${currentStock} -> ${newStock}`,
            attributes: {
                 'product.id': String(item.id),
                 'product.name': productName,
                 'stock.before': String(currentStock),
                 'stock.after': String(newStock),
               },
          });

          reserved.push({ id: item.id, name: productName, reserved: item.quantity, remaining: newStock });
        } finally {
          release();
        }
       }

      span.setStatus({ code: SpanStatusCode.OK });
      return reserved;
     } catch (err) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      throw err;
     } finally {
      span.end();
     }
   });
}

function getInventory() {
  return Object.entries(inventory).map(([id, stock]) => ({
    id: Number(id),
    name: PRODUCT_NAMES[id],
    stock,
   }));
}

module.exports = { reserveInventory, getInventory };
