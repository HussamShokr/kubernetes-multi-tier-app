const http = require('http');
const { MongoClient } = require('mongodb');

const PORT = process.env.PORT || 3000;
const MONGO_URI = process.env.MONGO_URI || 'mongodb://app-user:app-password@mongodb.multi-tier.svc.cluster.local:27017/app-database';

// Health check endpoint for Kubernetes probes
const handleHealthCheck = (res) => {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ status: 'ok' }));
};

// Main API endpoint
const handleApi = (res) => {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ message: 'Welcome to the backend API!' }));
};

// MongoDB connection test
const checkDbConnection = async (res) => {
  let client;
  try {
    client = new MongoClient(MONGO_URI);
    await client.connect();
    const dbInfo = await client.db().admin().serverInfo();
    
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ 
      status: 'connected', 
      version: dbInfo.version,
      message: 'Database connection successful'
    }));
  } catch (error) {
    console.error('MongoDB connection error:', error);
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ 
      status: 'error', 
      message: 'Database connection failed',
      error: error.message
    }));
  } finally {
    if (client) await client.close();
  }
};

// Create HTTP server
const server = http.createServer(async (req, res) => {
  console.log(`Received request: ${req.method} ${req.url}`);
  
  // Add CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  
  // Handle OPTIONS request
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // Route requests
  if (req.url === '/health') {
    handleHealthCheck(res);
  } else if (req.url === '/api') {
    handleApi(res);
  } else if (req.url === '/db') {
    await checkDbConnection(res);
  } else {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Not found' }));
  }
});

// Start the server
server.listen(PORT, '0.0.0.0', () => {
  console.log(`Backend server running on port ${PORT}`);
  console.log(`MongoDB URI: ${MONGO_URI}`);
});

// Handle shutdown gracefully
process.on('SIGTERM', () => {
  console.log('SIGTERM received, shutting down gracefully');
  server.close(() => {
    console.log('Server closed');
    process.exit(0);
  });
});