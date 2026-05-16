const { app } = require('@azure/functions');
const pool = require('../../../db');

app.http('getProductById', {
    methods: ['GET'],
    authLevel: 'anonymous',
    route: 'products/{id}',
    handler: async (request, context) => {
        try {
            const id = request.params.id;
            const result = await pool.query('SELECT * FROM products WHERE id = $1', [id]);

            if (result.rows.length === 0) {
                return { status: 404, body: 'Product not found' };
            }

            return { status: 200, body: JSON.stringify(result.rows[0]) };
        } catch (error) {
            context.log.error('Error fetching product:', error);
            return { status: 500, body: 'Internal server error' };
        }
    }
});