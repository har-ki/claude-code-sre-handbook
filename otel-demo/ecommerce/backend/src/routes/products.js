const express = require('express');
const { getInventory } = require('../services/inventory');

const router = express.Router();

router.get('/products', (req, res) => {
  res.json(getInventory());
});

module.exports = router;
