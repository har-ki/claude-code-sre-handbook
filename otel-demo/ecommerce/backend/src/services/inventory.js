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
    7: 5,       // Ceramic Plant Pot — limited stock
    8: 50, 9: 50, 10: 50, 11: 50, 12: 50,
};

// Per-product lock chains to serialize operations per product.
// Prevents TOCTOU race conditions by ensuring check + decrement
// for a given product are never concurrent.
const _lockChains = new Map();

/**
 * Acquire a per-product lock. Returns a `release` function.
 * Uses a promise-chain (promise-queue) pattern — no external deps needed.
 */
async function acquireLock(productId) {
  if (!_lockChains.has(productId)) {
    _lockChains.set(productId, Promise.resolve());
  }

  const prev = _lockChains.get(productId);
  return new Promise((resolve) => {
    prev.then(() => {
      let releaseFn;
      const next = new Promise((r) => { releaseFn = r; });
      _lockChains.set(productId, next);
      resolve(releaseFn);
    });
  });
}

/**
 * Atomically check stock and decrement for a single product.
 * Returns the new stock level, or throws if insufficient.
 *
 * Key change: the read and the decrement happen inside the
 * same lock section, eliminating the TOCTOU gap.
 */
async function atomicDecrement(productId, quantity) {
  const release = await acquireLock(productId);
  try {
    const before = inventory[productId];
    if (before < quantity) {
      throw new Error(
        `Insufficient stock for product ${productId}: ` +
        `requested ${quantity}, available ${before}`
      );
    }
    // Simulate DB write latency
    await new Promise(r => setTimeout(r, 5));
    inventory[productId] -= quantity;
    return inventory[productId];
  } finally {
    release();
  }
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

        // ---- read current stock for span instrumentation ----
        const currentStock = inventory[item.id];
        span.setAttribute(`product.${item.id}.stock_before`, currentStock);

        // Validate inventory policies and apply business rules
        await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));

        // Atomic check-and-decrement: stock is read AND written
        // under the same per-product lock, so no two concurrent
        // operations can both see stale stock and oversell.
        const newStock = await atomicDecrement(item.id, item.quantity);

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
      }

      span.setStatus({ code: SpanStatusCode.OK });
      return reserved;
    } catch (err) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      span.recordException(err);
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
