import assert from 'node:assert/strict'
import fs from 'node:fs'
import http from 'node:http'
import mqtt from 'mqtt'

const [url, authMode] = process.argv.slice(2)
assert.ok(url && ['anonymous', 'password'].includes(authMode))
const token = fs.readFileSync('/artifact/management-admin-client-token', 'utf8').trim()
const pause = ms => new Promise(resolve => setTimeout(resolve, ms))
const tls = url.startsWith('mqtts:')
const credentials = authMode === 'password'
  ? { username: 'sensor01', password: 'correct horse' } : {}
const deadline = setTimeout(() => {
  console.error('distribution admin smoke timed out')
  process.exit(1)
}, 30000)
function request(method, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: '127.0.0.1', port: 9091, method, path, agent: false, timeout: 2500,
      headers: { Authorization: 'Bearer ' + token,
        ...((method === 'POST' || method === 'DELETE') ? { 'Content-Length': 0 } : {}),
        ...headers }
    }, res => {
      const chunks = []
      res.on('data', chunk => chunks.push(chunk))
      res.on('end', () => resolve({ status: res.statusCode,
        body: Buffer.concat(chunks).toString() }))
    })
    req.on('timeout', () => req.destroy(new Error('admin HTTP timeout')))
    req.on('error', reject)
    req.end()
  })
}
function connect(clientId, will) {
  return new Promise((resolve, reject) => {
    const client = mqtt.connect(url, {
      protocolVersion: 4, clientId, clean: false,
      reconnectPeriod: 0, connectTimeout: 2000, ...credentials,
      ...(tls ? { ca: fs.readFileSync('/artifact/server.crt'),
        rejectUnauthorized: true } : {}),
      ...(will ? { will } : {})
    })
    client.once('connect', () => resolve(client))
    client.once('error', reject)
  })
}
const end = client => new Promise(resolve => client.end(false, resolve))
async function pages(path) {
  const rows = []
  let cursor
  for (let i = 0; i < 8; i++) {
    const response = await request('GET', path + (cursor ? '&cursor=' + cursor : ''))
    assert.equal(response.status, 200, response.body)
    const page = JSON.parse(response.body)
    rows.push(...page.items)
    cursor = page.next_cursor
    if (!cursor) return rows
  }
  throw new Error('page did not terminate')
}
async function finish(id) {
  for (let i = 0; i < 100; i++) {
    const response = await request('GET', '/v1/operations/' + id)
    assert.equal(response.status, 200, response.body)
    const record = JSON.parse(response.body)
    if (record.state === 'succeeded' || record.state === 'failed') return record
    await pause(20)
  }
  throw new Error('operation did not finish')
}
let offline, active
try {
  let config
  for (let i = 0; i < 50; i++) {
    try {
      config = await request('GET', '/v1/config')
      if (config.status === 200) break
    } catch {}
    await pause(100)
  }
  assert.equal(config?.status, 200)
  assert.equal(JSON.parse(config.body).operations_enabled, true)
  offline = await connect('dist-b-offline')
  await new Promise((resolve, reject) =>
    offline.subscribe('dist/b/#', { qos: 1 }, error => error ? reject(error) : resolve()))
  await end(offline)
  let row
  for (let i = 0; i < 30; i++) {
    row = (await pages('/v1/sessions?attached=false&limit=50'))
      .find(value => value.client_id === 'dist-b-offline')
    if (row) break
    await pause(20)
  }
  assert.ok(row)
  const headers = { 'If-Match': row.etag, 'Idempotency-Key': 'DistDelete_0123456789' }
  const deleted = await request('DELETE', '/v1/sessions/' + row.handle, headers)
  assert.equal(deleted.status, 202, deleted.body)
  assert.equal((await finish(JSON.parse(deleted.body).operation_id)).state, 'succeeded')
  assert.equal((await request('DELETE', '/v1/sessions/' + row.handle, headers)).status, 200)
  active = await connect('dist-b-active', {
    topic: 'dist/b/will', payload: 'closed', qos: 1, retain: false
  })
  const connection = (await pages('/v1/connections?limit=50'))
    .find(value => value.client_id === 'dist-b-active')
  assert.ok(connection)
  const kicked = await request('POST',
    '/v1/connections/' + connection.connection_id + '/disconnect',
    { 'If-Match': connection.connection_etag,
      'Idempotency-Key': 'DistKick_0123456789ab' })
  assert.equal(kicked.status, 202, kicked.body)
  const operation = await finish(JSON.parse(kicked.body).operation_id)
  assert.equal(operation.state, 'succeeded')
  assert.equal(operation.transport_closed, true)
  assert.equal(operation.completion_scope, 'runtime')
  console.log('DISTRIBUTION management read/kick/delete smoke passed: ' +
    (tls ? 'TLS' : 'plaintext') + ', ' + authMode)
} finally {
  if (active) active.end(true)
  if (offline) offline.end(true)
  clearTimeout(deadline)
}
