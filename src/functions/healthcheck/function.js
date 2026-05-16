const { app } = require('@azure/functions');

app.http('healthcheck', {
    methods: ['GET'],
    authLevel: 'anonymous',
    route: 'healthcheck',
    handler: async (request, context) => {
        try {
            return {
                status: 200,
                body: JSON.stringify({ status: 'Service Up' }),
            };
        } catch (error) {
            context.log.error('Healthcheck failure:', error);
            return {
                status: 500,
                body: JSON.stringify({ status: 'Service Down' }),
            };
        }
    }
});
