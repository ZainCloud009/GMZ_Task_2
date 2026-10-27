// Load environment variables from .env file (if running locally or on server)
require('dotenv').config();

// Load New Relic APM Agent (must be loaded before all other modules)
if (process.env.NEW_RELIC_LICENSE_KEY) {
  try {
    require('newrelic');
    console.log('[New Relic] APM Agent initialized successfully for app: GMZ-Health-App-Production');
  } catch (err) {
    console.warn('[New Relic] Could not initialize APM Agent:', err.message);
  }
}

const express = require('express');
const path = require('path');
const os = require('os');
const mysql = require('mysql2/promise');
const { Pool: PgPool } = require('pg');
const { createProxyMiddleware } = require('http-proxy-middleware');

const app = express();
const PORT = process.env.PORT || 3000;

// --------------------------------------------------
// Database Manager (phpMyAdmin) Reverse Proxy
// --------------------------------------------------
// Redirect /phpmyadmin (exact match without slash) to /phpmyadmin/
app.get(/^\/phpmyadmin$/, (req, res) => {
  res.redirect(301, '/phpmyadmin/');
});

// Proxy /phpmyadmin to phpMyAdmin (placed BEFORE express.json to preserve POST body)
app.use(
  '/phpmyadmin',
  createProxyMiddleware({
    target: process.env.PHPMYADMIN_SERVICE_URL || process.env.ADMINER_SERVICE_URL || 'http://gmz-phpmyadmin-service:80',
    changeOrigin: true,
    pathRewrite: {
      '^/phpmyadmin': ''
    },
    on: {
      proxyReq: (proxyReq, req, res) => {
        proxyReq.setHeader('X-Forwarded-Proto', 'https');
        proxyReq.setHeader('X-Forwarded-Prefix', '/phpmyadmin');
      }
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
let dbEngine = 'mysql';
let dbPool = null;
let dbState = {
  connected: false,
  source: '.env / Environment Variables',
  engine: 'MySQL',
  host: process.env.DB_HOST || null,
  database: process.env.DB_NAME || 'gmz_tasks_db',
  latencyMs: null,
  error: null,
  lastChecked: null
};

// Function to initialize Database connection using Environment Variables (.env)
async function initDatabase() {
  const engine = (process.env.DB_ENGINE || (process.env.DB_PORT === '5432' ? 'postgres' : 'mysql')).toLowerCase();
  dbEngine = engine;

  const host = process.env.DB_HOST;
  const port = parseInt(process.env.DB_PORT || (engine === 'mysql' ? '3306' : '5432'), 10);
  const user = process.env.DB_USER || (engine === 'mysql' ? 'admin' : 'postgresadmin');
  const password = process.env.DB_PASSWORD;
  const database = process.env.DB_NAME || 'gmz_tasks_db';

  if (!host || !password) {
    dbState = {
      connected: false,
      source: '.env / Environment Variables',
      engine: engine.toUpperCase(),
      host: null,
      database: database,
      latencyMs: null,
      error: 'Database credentials missing in environment variables (.env)',
      lastChecked: new Date().toISOString()
    };
    console.warn('[Database] Database credentials missing in environment variables (.env)');
    return;
  }

  try {
    if (engine === 'mysql') {
      console.log(`[Database] Connecting to MySQL at ${host}:${port} using environment variables (.env)...`);

      dbPool = mysql.createPool({
        host,
        port,
        user,
        password,
        database,
        waitForConnections: true,
        connectionLimit: 10,
        queueLimit: 0,
        ssl: { rejectUnauthorized: false }
      });

      const start = Date.now();
      await dbPool.query(`
        CREATE TABLE IF NOT EXISTS tasks (
          id INT AUTO_INCREMENT PRIMARY KEY,
          title VARCHAR(255) NOT NULL,
          description TEXT,
          priority VARCHAR(50) DEFAULT 'Medium',
          status VARCHAR(50) DEFAULT 'Pending',
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
      `);
      const latency = Date.now() - start;

      dbState = {
        connected: true,
        source: '.env / Environment Variables',
        engine: 'MySQL',
        host: host,
        database: database,
        latencyMs: latency,
        error: null,
        lastChecked: new Date().toISOString()
      };

      console.log(`[MySQL] Connected successfully to ${host}/${database} (Latency: ${latency}ms)`);
    } else {
      console.log(`[Database] Connecting to PostgreSQL at ${host}:${port} using environment variables (.env)...`);

      dbPool = new PgPool({
        host,
        port,
        user,
        password,
        database,
        ssl: { rejectUnauthorized: false },
        connectionTimeoutMillis: 7000
      });

      const start = Date.now();
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
        engine: 'PostgreSQL',
        host: host,
        database: database,
        latencyMs: latency,
        error: null,
        lastChecked: new Date().toISOString()
      };

      console.log(`[PostgreSQL] Connected successfully to ${host}/${database} (Latency: ${latency}ms)`);
    }
  } catch (err) {
    console.error(`[DB Error] Could not connect to ${engine.toUpperCase()} database:`, err.message);
    dbState = {
      connected: false,
      source: '.env / Environment Variables',
      engine: engine.toUpperCase(),
      host: host,
      database: database,
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
      engine: dbState.engine,
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
    if (dbEngine === 'mysql') {
      const [rows] = await dbPool.query('SELECT * FROM tasks ORDER BY id DESC');
      res.json({
        success: true,
        count: rows.length,
        tasks: rows
      });
    } else {
      const result = await dbPool.query('SELECT * FROM tasks ORDER BY id DESC');
      res.json({
        success: true,
        count: result.rows.length,
        tasks: result.rows
      });
    }
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch tasks', details: err.message });
  }
});

// 2. READ ONE (GET /api/tasks/:id)
app.get('/api/tasks/:id', ensureDb, async (req, res) => {
  try {
    const { id } = req.params;
    if (dbEngine === 'mysql') {
      const [rows] = await dbPool.query('SELECT * FROM tasks WHERE id = ?', [id]);
      if (rows.length === 0) {
        return res.status(404).json({ error: 'Task not found' });
      }
      res.json({ success: true, task: rows[0] });
    } else {
      const result = await dbPool.query('SELECT * FROM tasks WHERE id = $1', [id]);
      if (result.rows.length === 0) {
        return res.status(404).json({ error: 'Task not found' });
      }
      res.json({ success: true, task: result.rows[0] });
    }
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

    const t = title.trim();
    const d = description ? description.trim() : '';
    const p = priority || 'Medium';
    const s = status || 'Pending';

    if (dbEngine === 'mysql') {
      const [insertRes] = await dbPool.query(
        'INSERT INTO tasks (title, description, priority, status) VALUES (?, ?, ?, ?)',
        [t, d, p, s]
      );
      const [rows] = await dbPool.query('SELECT * FROM tasks WHERE id = ?', [insertRes.insertId]);
      res.status(201).json({
        success: true,
        message: 'Task created successfully in AWS RDS MySQL',
        task: rows[0]
      });
    } else {
      const query = `
        INSERT INTO tasks (title, description, priority, status)
        VALUES ($1, $2, $3, $4)
        RETURNING *;
      `;
      const result = await dbPool.query(query, [t, d, p, s]);
      res.status(201).json({
        success: true,
        message: 'Task created successfully in AWS RDS PostgreSQL',
        task: result.rows[0]
      });
    }
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

    const t = title.trim();
    const d = description || '';
    const p = priority || 'Medium';
    const s = status || 'Pending';

    if (dbEngine === 'mysql') {
      const [updateRes] = await dbPool.query(
        'UPDATE tasks SET title = ?, description = ?, priority = ?, status = ? WHERE id = ?',
        [t, d, p, s, id]
      );
      if (updateRes.affectedRows === 0) {
        return res.status(404).json({ error: 'Task not found' });
      }
      const [rows] = await dbPool.query('SELECT * FROM tasks WHERE id = ?', [id]);
      res.json({
        success: true,
        message: 'Task updated successfully in AWS RDS MySQL',
        task: rows[0]
      });
    } else {
      const query = `
        UPDATE tasks
        SET title = $1, description = $2, priority = $3, status = $4, updated_at = CURRENT_TIMESTAMP
        WHERE id = $5
        RETURNING *;
      `;
      const result = await dbPool.query(query, [t, d, p, s, id]);
      if (result.rows.length === 0) {
        return res.status(404).json({ error: 'Task not found' });
      }

      res.json({
        success: true,
        message: 'Task updated successfully',
        task: result.rows[0]
      });
    }
  } catch (err) {
    res.status(500).json({ error: 'Failed to update task', details: err.message });
  }
});

// 5. DELETE (DELETE /api/tasks/:id)
app.delete('/api/tasks/:id', ensureDb, async (req, res) => {
  try {
    const { id } = req.params;
    if (dbEngine === 'mysql') {
      const [deleteRes] = await dbPool.query('DELETE FROM tasks WHERE id = ?', [id]);
      if (deleteRes.affectedRows === 0) {
        return res.status(404).json({ error: 'Task not found' });
      }
      res.json({
        success: true,
        message: `Task #${id} deleted successfully from RDS MySQL`
      });
    } else {
      const result = await dbPool.query('DELETE FROM tasks WHERE id = $1 RETURNING id', [id]);
      if (result.rows.length === 0) {
        return res.status(404).json({ error: 'Task not found' });
      }
      res.json({
        success: true,
        message: `Task #${id} deleted successfully from RDS PostgreSQL`
      });
    }
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
