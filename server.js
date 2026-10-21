const express = require('express');
const path = require('path');
const os = require('os');

const app = express();
const PORT = process.env.PORT || 3000;

// Serve static frontend files from 'public' folder
app.use(express.static(path.join(__dirname, 'public')));

// Health check endpoint
app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'UP',
    message: 'Node.js Backend is running smoothly',
    timestamp: new Date().toISOString(),
    uptime: `${Math.floor(process.uptime())} seconds`,
    system: {
      platform: os.platform(),
      cpus: os.cpus().length,
      freeMemory: `${(os.freemem() / (1024 * 1024)).toFixed(2)} MB`,
      totalMemory: `${(os.totalmem() / (1024 * 1024)).toFixed(2)} MB`
    }
  });
});

app.listen(PORT, () => {
  console.log(`Server is running at http://localhost:${PORT}`);
});
