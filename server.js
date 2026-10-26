const express = require('express');
const path = require('path');
const os = require('os');
const { Pool } = require('pg');
const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
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
// Database & AWS Secrets Manager State
// --------------------------------------------------
let dbPool = null;
let dbState = {
  connected: false,
  source: 'Not initialized',
  host: null,
  database: null,
  latencyMs: null,
  error: null,
  lastChecked: null
};

// Function to fetch DB credentials from AWS Secrets Manager
async function getDbCredentials() {
  // Option 1: Direct environment variables (local or custom override)
  if (process.env.DB_HOST && process.env.DB_USER && process.env.DB_PASSWORD) {
    console.log('[DB] Using credentials from direct environment variables');
    return {
      host: process.env.DB_HOST,
      port: parseInt(process.env.DB_PORT || '5432', 10),
      username: process.env.DB_USER,
      password: process.env.DB_PASSWORD,
      dbname: process.env.DB_NAME || 'gmz_tasks_db',
      source: 'Direct Environment Variables'
    };
  }

  // Option 2: Dynamic fetch from AWS Secrets Manager
  const secretName = process.env.DB_SECRET_NAME || 'gmz-k8s-cluster-rds-credentials';
  const region = process.env.AWS_REGION || 'eu-north-1';

  console.log(`[Secrets Manager] Fetching secret "${secretName}" from region "${region}"...`);
  const client = new SecretsManagerClient({ region });
  const command = new GetSecretValueCommand({ SecretId: secretName });
  const response = await client.send(command);

  if (!response.SecretString) {
    throw new Error('SecretString is empty in AWS Secrets Manager response');
  }

  const secret = JSON.parse(response.SecretString);
  console.log(`[Secrets Manager] Successfully retrieved DB credentials for host: ${secret.host}`);

  return {
    host: secret.host,
    port: parseInt(secret.port || '5432', 10),
    username: secret.username,
    password: secret.password,
    dbname: secret.dbname || 'gmz_tasks_db',
    source: `AWS Secrets Manager (${secretName})`
  };
}

// Function to initialize PostgreSQL connection and auto-create tasks table
async function initDatabase() {
  try {
    const creds = await getDbCredentials();

    dbPool = new Pool({
      host: creds.host,
      port: creds.port,
      user: creds.username,
      password: creds.password,
      database: creds.dbname,
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
      source: creds.source,
      host: creds.host,
      database: creds.dbname,
      latencyMs: latency,
      error: null,
      lastChecked: new Date().toISOString()
    };

    console.log(`[PostgreSQL] Connected successfully to ${creds.host}/${creds.dbname} (Latency: ${latency}ms)`);
  } catch (err) {
    console.error('[DB Error] Could not connect to database:', err.message);
    dbState = {
      connected: false,
      source: 'AWS Secrets Manager Attempted',
      host: null,
      database: null,
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
  // Attempt DB initialization in background on startup
  await initDatabase();
});
