const { trace, SpanStatusCode } = require('@opentelemetry/api');
const { logs, SeverityNumber } = require('@opentelemetry/api-logs');
const { v4: uuidv4 } = require('uuid');

const logger = logs.getLogger('ecommerce-api');
const tracer = trace.getTracer('ecommerce-api');

async function processPayment(order) {
  return tracer.startActiveSpan('processPayment', async (span) => {
    try {
      span.setAttribute('order.id', order.orderId);
      span.setAttribute('payment.amount', order.total);

       // Simulate payment gateway latency
      await new Promise(resolve => setTimeout(resolve, 80 + Math.random() * 120));

      const transactionId = uuidv4();
      span.setAttribute('payment.transaction_id', transactionId);

      logger.emit({
        severityNumber: SeverityNumber.INFO,
        severityText: 'INFO',
        body: `Payment processed: order=${order.orderId}, amount=$${order.total.toFixed(2)}, txn=${transactionId}`,
        attributes: {
           'order.id': order.orderId,
           'payment.amount': String(order.total),
           'payment.transaction_id': transactionId,
         },
       });

      span.setStatus({ code: SpanStatusCode.OK });
      return { transactionId, status: 'approved' };
     } catch (err) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      span.recordException(err);
      throw err;
     } finally {
      span.end();
     }
   });
}

module.exports = { processPayment };
