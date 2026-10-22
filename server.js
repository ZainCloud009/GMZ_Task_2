const express = require('express');
const path = require('path');
const os = require('os');

const app = express();
const PORT = process.env.PORT || 3000;

// Serve static frontend files from 'public' folder
app.use(express.static(path.join(__dirname, 'public')));

// Helper function to get CPU times across all cores
function getCpuTimes() {
  const cpus = os.cpus();
  let idle = 0;
  let total = 0;
  for (const cpu of cpus) {
    for (const type in cpu.times) {
      total += cpu.times[type];
    }
    idle += cpu.times.idle;
  }
  return { idle, total };
}

// Helper function to measure live CPU usage with 2 decimal points precision
function getCpuUsage() {
  return new Promise((resolve) => {
    const start = getCpuTimes();
    setTimeout(() => {
      const end = getCpuTimes();
      const idleDiff = end.idle - start.idle;
      const totalDiff = end.total - start.total;
      const raw = totalDiff > 0 ? (100 - (idleDiff / totalDiff) * 100) : 0;
      const numeric = Math.max(0, Math.min(100, parseFloat(raw.toFixed(2))));
      resolve({
        percentage: `${numeric.toFixed(2)}%`,
        points: numeric
      });
    }, 150);
  });
}

// Health check endpoint
app.get('/health', async (req, res) => {
  const cpu = await getCpuUsage();
  const load = os.loadavg();

  res.status(200).json({
    status: 'UP',
    message: 'Node.js Backend is running smoothly',
    timestamp: new Date().toISOString(),
    uptime: `${Math.floor(process.uptime())} seconds`,
    system: {
      platform: os.platform(),
      cpus: os.cpus().length,
      cpuUsage: cpu.percentage,         // e.g. "0.52%"
      cpuUsagePoints: cpu.points,       // e.g. 0.52 (decimal points me)
      loadAverage: {
        "1m": parseFloat(load[0].toFixed(2)),   // 1-minute load average (points me)
        "5m": parseFloat(load[1].toFixed(2)),   // 5-minute load average
        "15m": parseFloat(load[2].toFixed(2))   // 15-minute load average
      },
      freeMemory: `${(os.freemem() / (1024 * 1024)).toFixed(2)} MB`,
      totalMemory: `${(os.totalmem() / (1024 * 1024)).toFixed(2)} MB`
    }
  });
});

app.listen(PORT, () => {
  console.log(`Server is running at http://localhost:${PORT}`);
});
