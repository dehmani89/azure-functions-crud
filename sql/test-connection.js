// Quick connectivity test for Azure Database for PostgreSQL.
// Run with:  node sql/test-connection.js
//
// Fill in the values below (or set the matching env vars before running).
// Azure PG host looks like:  <server-name>.postgres.database.azure.com

const { Client } = require('pg');

const client = new Client({
  host: process.env.PGHOST || 'azure-postgresql-poc.postgres.database.azure.com',
  port: Number(process.env.PGPORT) || 5432,
  user: process.env.PGUSER || 'dbadmin',
  password: process.env.PGPASSWORD || 'Qwerty89!',
  database: process.env.PGDATABASE || 'postgres', // change to 'productsDB' once created
  ssl: { rejectUnauthorized: false }, // Azure PG requires SSL
  connectionTimeoutMillis: 10000,
});

(async () => {
  try {
    console.log(`Connecting to ${client.host}:${client.port} ...`);
    await client.connect();

    const { rows } = await client.query('SELECT version(), current_database(), now()');
    console.log('✅ Connected!');
    console.log('   version :', rows[0].version);
    console.log('   database:', rows[0].current_database);
    console.log('   time    :', rows[0].now);
  } catch (err) {
    console.error('❌ Connection failed:', err.message);
    process.exitCode = 1;
  } finally {
    await client.end();
  }
})();