const request = require('supertest');
const app = require('./index');

describe('GET /', () => {
  it('returns 200 with message and version', async () => {
    const res = await request(app).get('/');
    expect(res.statusCode).toBe(200);
    expect(res.body.message).toBe('Hello from the DevOps exercise!');
    expect(res.body.version).toBeDefined();
    expect(res.body.timestamp).toBeDefined();
  });
});

describe('GET /health', () => {
  it('returns 200 with status ok', async () => {
    const res = await request(app).get('/health');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('ok');
  });
});

describe('GET /info', () => {
  it('returns 200 with runtime info', async () => {
    const res = await request(app).get('/info');
    expect(res.statusCode).toBe(200);
    expect(res.body.node).toBeDefined();
    expect(res.body.uptime).toBeDefined();
  });
});