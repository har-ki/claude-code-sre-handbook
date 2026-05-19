const express = require('express');
const { v4: uuidv4 } = require('uuid');
const { trace, SpanStatusCode } = require('@opentelemetry/api');
const { logs, SeverityNumber } = require('@opentelemetry/api-logs');
const { reserveInventory } = require('../services/inventory');
const { processPayment } = require('../services/payment');

const logger = logs.getLogger('ecommerce-api');
const tracer = trace.getTracer('ecommerce-api');
const router = express.Router();

router.post('/checkout', async (req, res) => {
  const span = trace.getActiveSpan();
  const orderId = 'ORD-' + uuidv4().slice(0, 8).toUpperCase();

  if (span) {
    span.setAttribute('order.id', orderId);
    span.setAttribute('order.item_count', req.body.items?.length || 0);
   }

  try {
    const { items, shipping } = req.body;

    if (!items || items.length === 0) {
      return res.status(400).json({ error: 'No items in order' });
     }

    logger.emit({
      severityNumber: SeverityNumber.INFO,
      severityText: 'INFO',
      body: `Checkout started: order=${orderId}, items=${items.length}`,
      attributes: { 'order.id': orderId },
     });

     // Step 1: Reserve inventory
    const reserved = await reserveInventory(items);

     // Step 2: Calculate total
    const PRICES = {
       1: 79.99, 2: 199.99, 3: 49.99, 4: 24.99, 5: 59.99, 6: 89.99,
       7: 19.99, 8: 34.99, 9: 39.99, 10: 59.99, 11: 129.99, 12: 79.99,
     };
    const subtotal = items.reduce((sum, i) => sum + (PRICES[i.id] || 0) * i.quantity, 0);
    const shippingCost = subtotal > 100 ? 0 : 9.99;
    const tax = subtotal * 0.08;
    const total = subtotal + shippingCost + tax;

     // Step 3: Process payment
    const payment = await processPayment({ orderId, total });

    logger.emit({
      severityNumber: SeverityNumber.INFO,
      severityText: 'INFO',
      body: `Order completed: order=${orderId}, total=$${total.toFixed(2)}, txn=${payment.transactionId}`,
      attributes: {
         'order.id': orderId,
         'order.total': String(total),
         'payment.transaction_id': payment.transactionId,
       },
     });

    res.json({
      orderId,
      status: 'confirmed',
      total,
      transactionId: payment.transactionId,
      items: reserved,
     });
   } catch (err) {
    logger.emit({
      severityNumber: SeverityNumber.ERROR,
      severityText: 'ERROR',
      body: `Checkout failed: order=${orderId} — ${err.message}`,
      attributes: {
         'exception.type': err.constructor.name,
         'exception.message': err.message,
         'exception.stacktrace': err.stack,
         'order.id': orderId,
       },
     });

    if (span) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      span.recordException(err);
     }

    const status = err.message.includes('Insufficient stock') ? 409 : 500;
    res.status(status).json({ error: err.message, orderId });
   }
});

module.exports = router;
