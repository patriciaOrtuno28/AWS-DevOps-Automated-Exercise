const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;
const VERSION = process.env.APP_VERSION || '1.0.0';

app.use(express.json());

app.get('/', (req, res) => {
  res.json({
    message: 'Hello from the DevOps exercise!',
    version: VERSION,
    hostname: require('os').hostname(),
    timestamp: new Date().toISOString(),
    environment: process.env.NODE_ENV || 'development'
  });
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok', version: VERSION });
});

app.get('/info', (req, res) => {
  res.json({
    node: process.version,
    uptime: process.uptime(),
    memory: process.memoryUsage(),
    version: VERSION
  });
});

app.listen(PORT, () => {
  console.log(`[${new Date().toISOString()}] App v${VERSION} running on port ${PORT}`);
});

module.exports = app;