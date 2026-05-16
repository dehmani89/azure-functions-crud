const { app } = require('@azure/functions');
const pool = require('../../../db');

app.http('updateProduct', {
    methods: ['PUT'],
    authLevel: 'anonymous',
    route: 'products/{id}',
    handler: async (request, context) => {
        try {
            const id = request.params.id;
            const { name, description, price } = await request.json();

            if (!name || !price) {
                return { status: 400, body: 'Name and price are required' };
            }

            const query = 'UPDATE products SET name = $1, description = $2, price = $3, updated_at = CURRENT_TIMESTAMP WHERE id = $4 RETURNING *';
            const values = [name, description, price, id];
            const result = await pool.query(query, values);

            if (result.rows.length === 0) {
                return { status: 404, body: 'Product not found' };
            }

            return { status: 200, body: JSON.stringify(result.rows[0]) };
        } catch (error) {
            context.log.error('Error updating product:', error);
            return { status: 500, body: 'Internal server error' };
        }
    }
});