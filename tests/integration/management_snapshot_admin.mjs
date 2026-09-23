import assert from 'node:assert/strict'
import http from 'node:http'
import mqtt from 'mqtt'

const [action, mqttText, adminText, token, clientId] = process.argv.slice(2)
const mqttPort = Number(mqttText), adminPort = Number(adminText)
const pause = ms => new Promise(resolve => setTimeout(resolve, ms))
const deadline = setTimeout(() => {
  console.error('management snapshot admin timed out')
  process.exit(1)
}, 15000)
function request(method, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: '127.0.0.1', port: adminPort, method, path, agent: false, timeout: 2000,
      headers: { Authorization: 'Bearer ' + token,
        ...((method === 'DELETE') ? { 'Content-Length': 0 } : {}), ...headers }
    }, res => {
      const chunks = []
      res.on('data', chunk => chunks.push(chunk))
      res.on('end', () => resolve({ status: res.statusCode,
        body: Buffer.concat(chunks).toString() }))
    })
    req.on('timeout', () => req.destroy(new Error('snapshot HTTP timeout')))
    req.on('error', reject)
    req.end()
  })
}
async function sessions() {
  const rows = []
  let cursor
  for (let i = 0; i < 8; i++) {
    const response = await request('GET', '/v1/sessions?limit=50' +
      (cursor ? '&cursor=' + cursor : ''))
    assert.equal(response.status, 200, response.body)
    const page = JSON.parse(response.body)
    rows.push(...page.items)
    cursor = page.next_cursor
    if (!cursor) return rows
  }
  throw new Error('session pages did not terminate')
}
async function find() {
  return (await sessions()).find(row => row.client_id === clientId)
}
try {
  if (action === 'create') {
    const client = mqtt.connect('mqtt://127.0.0.1:' + mqttPort, {
      clientId, clean: false, reconnectPeriod: 0, connectTimeout: 2000
    })
    await new Promise((resolve, reject) => {
      client.once('connect', resolve)
      client.once('error', reject)
    })
    await new Promise((resolve, reject) =>
      client.subscribe('snapshot/' + clientId, { qos: 1 },
        error => error ? reject(error) : resolve()))
    await new Promise(resolve => client.end(false, resolve))
    let row
    for (let i = 0; i < 40; i++) {
      row = await find()
      if (row && row.attached === false) break
      await pause(20)
    }
    assert.ok(row && !row.attached)
    console.log(JSON.stringify({ action, client_id: clientId, handle: row.handle }))
  } else if (action === 'delete') {
    const row = await find()
    assert.ok(row && row.attached === false)
    const response = await request('DELETE', '/v1/sessions/' + row.handle,
      { 'If-Match': row.etag, 'Idempotency-Key': 'SnapshotDelete_01234567' })
    assert.equal(response.status, 202, response.body)
    const id = JSON.parse(response.body).operation_id
    let operation
    for (let i = 0; i < 100; i++) {
      const current = await request('GET', '/v1/operations/' + id)
      assert.equal(current.status, 200, current.body)
      operation = JSON.parse(current.body)
      if (operation.state === 'succeeded') break
      await pause(20)
    }
    assert.equal(operation.state, 'succeeded', JSON.stringify(operation))
    assert.equal(operation.persistence_mode, 'snapshot')
    assert.equal(operation.completion_scope, 'runtime')
    assert.equal(await find(), undefined)
    console.log(JSON.stringify({ action, client_id: clientId, operation_id: id,
      committed_at_finish: operation.snapshot_committed_revision_at_finish }))
  } else if (action === 'present' || action === 'absent') {
    const row = await find()
    assert.equal(Boolean(row), action === 'present')
    console.log(JSON.stringify({ action, client_id: clientId,
      recovered: Boolean(row) }))
  } else {
    throw new Error('unknown snapshot action')
  }
} finally {
  clearTimeout(deadline)
}
