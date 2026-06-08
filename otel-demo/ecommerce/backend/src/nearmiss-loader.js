/**
 * Module loader for the near-miss inventory variant.
 *
 * Intercepts require() calls for the canonical inventory module and
 * redirects them to the near-miss variant. This allows the rest of
 * the application (checkout, products, server) to run unmodified.
 *
 * Usage: node -r ./src/instrumentation.js src/nearmiss-loader.js
 */
const Module = require('module');
const path = require('path');

const canonicalPath = path.resolve(__dirname, 'services', 'inventory.js');
const nearmissPath = path.resolve(__dirname, 'services', 'inventory-nearmiss.js');

const origResolve = Module._resolveFilename;
Module._resolveFilename = function (request, parent, isMain, options) {
  const resolved = origResolve.call(this, request, parent, isMain, options);
  if (resolved === canonicalPath) {
    return nearmissPath;
  }
  return resolved;
};

require('./server');
