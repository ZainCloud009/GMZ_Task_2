// Load environment variables from .env file (if running locally or on server)
require('dotenv').config();

const express = require('express');
const path = require('path');
const os = require('os');
const { Pool } = require('pg');
const { createProxyMiddleware } = require('http-proxy-middleware');

const app = express();
const PORT = process.env.PORT || 3000;

// --------------------------------------------------
// Database Manager (phpMyAdmin / Adminer) Reverse Proxy
// --------------------------------------------------
// Redirect /phpmyadmin (exact match without slash) to /phpmyadmin/
app.get(/^\/phpmyadmin$/, (req, res) => {
  res.redirect(301, '/phpmyadmin/');
});

// Proxy /phpmyadmin to Adminer (placed BEFORE express.json to preserve POST body)
app.use(
  '/phpmyadmin',
  createProxyMiddleware({
    target: process.env.ADMINER_SERVICE_URL || 'http://gmz-adminer-service:8080',
    changeOrigin: true,
    pathRewrite: {
      '^/phpmyadmin': ''
    }
  })
);

// Middleware to parse incoming JSON bodies
app.use(express.json());

// Serve static frontend files from 'public' folder
app.use(express.static(path.join(__dirname, 'public')));

// --------------------------------------------------
// Database State & Configuration (via .env / process.env)
// --------------------------------------------------
let dbPool = null;
let dbState = {
  connected: false,
  source: '.env / Environment Variables',
  host: process.env.DB_HOST || null,
  database: process.env.DB_NAME || 'gmz_tasks_db',
  latencyMs: null,
  error: null,
  lastChecked: null
};

// Function to initialize PostgreSQL connection using Environment Variables (.env)
async function initDatabase() {
  try {
    const host = process.env.DB_HOST;
    const port = parseInt(process.env.DB_PORT || '5432', 10);
    const user = process.env.DB_USER || 'postgresadmin';
    const password = process.env.DB_PASSWORD;
    const database = process.env.DB_NAME || 'gmz_tasks_db';

    if (!host || !password) {
      throw new Error('Database credentials missing in environment variables (.env)');
    }

    console.log(`[Database] Connecting to PostgreSQL at ${host}:${port} using environment variables (.env)...`);

    dbPool = new Pool({
      host,
      port,
      user,
      password,
      database,
      ssl: { rejectUnauthorized: false }, // Encrypted SSL connection to AWS RDS PostgreSQL
      connectionTimeoutMillis: 7000
    });

    const start = Date.now();
    // Test connection & ensure table exists
    await dbPool.query(`
      CREATE TABLE IF NOT EXISTS tasks (
        id SERIAL PRIMARY KEY,
        title VARCHAR(255) NOT NULL,
        description TEXT,
        priority VARCHAR(50) DEFAULT 'Medium',
        status VARCHAR(50) DEFAULT 'Pending',
        created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
      );
    `);
    const latency = Date.now() - start;

    dbState = {
      connected: true,
      source: '.env / Environment Variables',
      host: host,
      database: database,
      latencyMs: latency,
      error: null,
      lastChecked: new Date().toISOString()
    };

    console.log(`[PostgreSQL] Connected successfully to ${host}/${database} (Latency: ${latency}ms)`);
  } catch (err) {
    console.error('[DB Error] Could not connect to database:', err.message);
    dbState = {
      connected: false,
      source: '.env / Environment Variables',
      host: process.env.DB_HOST || null,
      database: process.env.DB_NAME || 'gmz_tasks_db',
      latencyMs: null,
      error: err.message,
      lastChecked: new Date().toISOString()
    };
  }
}

// Helper to check active DB connection
function ensureDb(req, res, next) {
  if (!dbPool || !dbState.connected) {
    return res.status(503).json({
      error: 'Database not connected or initializing',
      details: dbState.error || 'RDS instance is starting or unreachable'
    });
  }
  next();
}

// --------------------------------------------------
// System Metrics Helper Functions
// --------------------------------------------------
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

// --------------------------------------------------
// REST APIs: Health Check & DB Status
// --------------------------------------------------
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
      cpuUsage: cpu.percentage,
      cpuUsagePoints: cpu.points,
      loadAverage: {
        "1m": parseFloat(load[0].toFixed(2)),
        "5m": parseFloat(load[1].toFixed(2)),
        "15m": parseFloat(load[2].toFixed(2))
      },
      freeMemory: `${(os.freemem() / (1024 * 1024)).toFixed(2)} MB`,
      totalMemory: `${(os.totalmem() / (1024 * 1024)).toFixed(2)} MB`
    },
    database: {
      status: dbState.connected ? 'CONNECTED' : 'DISCONNECTED',
      source: dbState.source,
      host: dbState.host,
      name: dbState.database,
      latency: dbState.latencyMs ? `${dbState.latencyMs}ms` : null,
      error: dbState.error
    }
  });
});

app.get('/api/db-status', (req, res) => {
  res.json(dbState);
});

// --------------------------------------------------
// REST APIs: CRUD Operations for Task & Incident Tracker
// --------------------------------------------------

// 1. READ ALL (GET /api/tasks)
app.get('/api/tasks', ensureDb, async (req, res) => {
  try {
    const result = await dbPool.query('SELECT * FROM tasks ORDER BY id DESC');
    res.json({
      success: true,
      count: result.rows.length,
      tasks: result.rows
    });
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch tasks', details: err.message });
  }
});

// 2. READ ONE (GET /api/tasks/:id)
app.get('/api/tasks/:id', ensureDb, async (req, res) => {
  try {
    const { id } = req.params;
    const result = await dbPool.query('SELECT * FROM tasks WHERE id = $1', [id]);
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Task not found' });
    }
    res.json({ success: true, task: result.rows[0] });
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch task', details: err.message });
  }
});

// 3. CREATE (POST /api/tasks)
app.post('/api/tasks', ensureDb, async (req, res) => {
  try {
    const { title, description, priority, status } = req.body;
    if (!title || title.trim() === '') {
      return res.status(400).json({ error: 'Task title is required' });
    }

    const query = `
      INSERT INTO tasks (title, description, priority, status)
      VALUES ($1, $2, $3, $4)
      RETURNING *;
    `;
    const values = [
      title.trim(),
      description ? description.trim() : '',
      priority || 'Medium',
      status || 'Pending'
    ];

    const result = await dbPool.query(query, values);
    res.status(201).json({
      success: true,
      message: 'Task created successfully in AWS RDS PostgreSQL',
      task: result.rows[0]
    });
  } catch (err) {
    res.status(500).json({ error: 'Failed to create task', details: err.message });
  }
});

// 4. UPDATE (PUT /api/tasks/:id)
app.put('/api/tasks/:id', ensureDb, async (req, res) => {
  try {
    const { id } = req.params;
    const { title, description, priority, status } = req.body;

    if (!title || title.trim() === '') {
      return res.status(400).json({ error: 'Task title cannot be empty' });
    }

    const query = `
      UPDATE tasks
      SET title = $1, description = $2, priority = $3, status = $4, updated_at = CURRENT_TIMESTAMP
      WHERE id = $5
      RETURNING *;
    `;
    const values = [title.trim(), description || '', priority || 'Medium', status || 'Pending', id];

    const result = await dbPool.query(query, values);
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Task not found' });
    }

    res.json({
      success: true,
      message: 'Task updated successfully',
      task: result.rows[0]
    });
  } catch (err) {
    res.status(500).json({ error: 'Failed to update task', details: err.message });
  }
});

// 5. DELETE (DELETE /api/tasks/:id)
app.delete('/api/tasks/:id', ensureDb, async (req, res) => {
  try {
    const { id } = req.params;
    const result = await dbPool.query('DELETE FROM tasks WHERE id = $1 RETURNING id', [id]);

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Task not found' });
    }

    res.json({
      success: true,
      message: `Task #${id} deleted successfully from RDS PostgreSQL`
    });
  } catch (err) {
    res.status(500).json({ error: 'Failed to delete task', details: err.message });
  }
});

// Start Express Server and trigger DB initialization
app.listen(PORT, async () => {
  console.log(`Server is running at http://localhost:${PORT}`);
  // Attempt DB initialization on startup using environment variables (.env)
  await initDatabase();
});
