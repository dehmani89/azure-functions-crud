const { app } = require('@azure/functions');
const pool = require('../../../db');

app.http('deleteProduct', {
    methods: ['DELETE'],
    authLevel: 'anonymous',
    route: 'products/{id}',
    handler: async (request, context) => {
        try {
            const id = request.params.id;
            const result = await pool.query('DELETE FROM products WHERE id = $1 RETURNING *', [id]);

            if (result.rows.length === 0) {
                return { status: 404, body: 'Product not found' };
            }

            return { status: 200, body: JSON.stringify({ message: 'Product deleted successfully' }) };
        } catch (error) {
            context.log.error('Error deleting product:', error);
            return { status: 500, body: 'Internal server error' };
        }
    }
});