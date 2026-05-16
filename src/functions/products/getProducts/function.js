const { app } = require('@azure/functions');
const pool = require('../../../db');

app.http('getProducts', {
    methods: ['GET'],
    authLevel: 'anonymous',
    route: 'products',
    handler: async (request, context) => {
        try {
            const result = await pool.query('SELECT * FROM products ORDER BY id DESC');
            return { status: 200, body: JSON.stringify(result.rows) };
        } catch (error) {
            context.log.error('Error fetching products:', error);
            return { status: 500, body: 'Internal server error' };
        }
    }
});