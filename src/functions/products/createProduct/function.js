const { app } = require('@azure/functions');
const pool = require('../../../db');

app.http('createProduct', {
    methods: ['POST'],
    authLevel: 'anonymous',
    route: 'products',
    handler: async (request, context) => {
        try {
            const { name, description, price } = await request.json();

            if (!name || !price) {
                return { status: 400, body: 'Name and price are required' };
            }

            const query = 'INSERT INTO products (name, description, price) VALUES ($1, $2, $3) RETURNING *';
            const values = [name, description, price];
            const result = await pool.query(query, values);

            return { status: 201, body: JSON.stringify(result.rows[0]) };
        } catch (error) {
            context.log.error('Error creating product:', error);
            return { status: 500, body: 'Internal server error' };
        }
    }
});