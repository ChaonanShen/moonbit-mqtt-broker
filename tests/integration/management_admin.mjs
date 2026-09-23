import assert from 'node:assert/strict'
import http from 'node:http'
import net from 'node:net'
import mqtt from 'mqtt'

const [adminText, mqttText, readerToken, operatorToken, configToken] = process.argv.slice(2)
const adminPort = Number(adminText)
const mqttPort = Number(mqttText)
assert.ok(Number.isInteger(adminPort) && Number.isInteger(mqttPort))
const pause = ms => new Promise(resolve => setTimeout(resolve, ms))
const clients = new Set()
const deadline = setTimeout(() => {
  console.error('management admin integration timed out')
  process.exit(1)
}, 120000)

function request(method, path, token, headers = {}, body) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? undefined : Buffer.from(body)
    const req = http.request({
      host: '127.0.0.1', port: adminPort, method, path, agent: false, timeout: 3000,
      headers: {
        ...(token ? { Authorization: 'Bearer ' + token } : {}),
        ...((method === 'POST' || method === 'DELETE') ? { 'Content-Length': data?.length ?? 0 } : {}),
        ...headers
      }
    }, res => {
      const chunks = []
      res.on('data', chunk => chunks.push(chunk))
      res.on('end', () => resolve({
        status: res.statusCode, headers: res.headers,
        text: Buffer.concat(chunks).toString()
      }))
    })
    req.on('timeout', () => req.destroy(new Error('HTTP timeout ' + method + ' ' + path)))
    req.on('error', reject)
    req.end(data)
  })
}
const json = response => JSON.parse(response.text)
function connect(clientId, options = {}) {
  return new Promise((resolve, reject) => {
    const client = mqtt.connect('mqtt://127.0.0.1:' + mqttPort, {
      clientId, clean: false, reconnectPeriod: 0, connectTimeout: 3000, ...options
    })
    clients.add(client)
    const timer = setTimeout(() => {
      client.end(true)
      reject(new Error('MQTT connect did not finish: ' + clientId))
    }, 3000)
    client.once('connect', () => { clearTimeout(timer); resolve(client) })
    client.once('error', error => { clearTimeout(timer); reject(error) })
  })
}
const subscribe = (client, topic, qos = 1) => new Promise((resolve, reject) =>
  client.subscribe(topic, { qos }, error => error ? reject(error) : resolve()))
const publish = (client, topic, payload, qos = 1, retain = false) =>
  new Promise((resolve, reject) =>
    client.publish(topic, payload, { qos, retain }, error => error ? reject(error) : resolve()))
const end = (client, force = false) => Promise.race([
  new Promise(resolve => client.end(force, resolve)),
  pause(3000).then(() => { throw new Error('MQTT end did not finish: ' + client.options.clientId) })
])
async function terminal(id) {
  for (let i = 0; i < 150; i++) {
    const result = await request('GET', '/v1/operations/' + id, operatorToken)
    assert.equal(result.status, 200, result.text)
    const current = json(result)
    if (current.state === 'succeeded' || current.state === 'failed') return current
    await pause(20)
  }
  throw new Error('operation did not finish: ' + id)
}
async function list(path, token = readerToken) {
  const rows = []
  let cursor
  for (let i = 0; i < 100; i++) {
    const url = path + (cursor ? (path.includes('?') ? '&' : '?') + 'cursor=' + cursor : '')
    const response = await request('GET', url, token)
    assert.equal(response.status, 200, response.text)
    const page = json(response)
    assert.equal(page.consistency, 'per_page')
    rows.push(...page.items)
    cursor = page.next_cursor
    if (!cursor) return rows
  }
  throw new Error('cursor did not terminate: ' + path)
}
async function offlineSession(clientId, filter) {
  const client = await connect(clientId)
  await subscribe(client, filter, 2)
  await end(client)
  const rows = await list('/v1/sessions?attached=false&limit=2')
  const row = rows.find(item => item.client_id === clientId)
  assert.ok(row, 'missing offline ' + clientId)
  return row
}
function deleteSession(row, key) {
  return request('DELETE', '/v1/sessions/' + row.handle, operatorToken,
    { 'If-Match': row.etag, 'Idempotency-Key': key })
}
function raw(head) {
  return new Promise((resolve, reject) => {
    let output = Buffer.alloc(0)
    const socket = net.connect(adminPort, '127.0.0.1')
    socket.setTimeout(3000)
    socket.on('connect', () => socket.write(head))
    socket.on('data', chunk => { output = Buffer.concat([output, chunk]) })
    socket.on('timeout', () => socket.destroy(new Error('raw HTTP timeout')))
    socket.on('error', error => output.length ? resolve(output.toString()) : reject(error))
    socket.on('close', () => output.length ? resolve(output.toString()) : reject(new Error('no HTTP reply')))
  })
}

try {
  assert.equal((await request('GET', '/health/ready')).status, 200)
  assert.equal((await request('GET', '/v1/listeners', readerToken)).status, 200)
  const status = json(await request('GET', '/v1/status', readerToken))
  assert.equal(status.details_available, true)
  assert.equal(status.capabilities.operations, true)
  assert.equal(status.capabilities.reload, false)
  const config = json(await request('GET', '/v1/config', readerToken))
  assert.equal(config.details_enabled, true)
  assert.equal(config.operations_enabled, true)
  assert.equal((await request('GET', '/v1/sessions', operatorToken)).status, 403)
  assert.equal((await request('GET', '/v1/audit', readerToken)).status, 403)
  assert.equal((await request('POST', '/v1/config/reload', operatorToken)).status, 403)
  assert.equal((await request('POST', '/v1/config/reload', configToken)).status, 501)
  assert.equal((await request('POST', '/v1/config/reload', configToken, {}, '{}')).status, 400)
  assert.equal((await request('GET', '/v1/sessions?bogus=1', readerToken)).status, 400)

  console.error('admin-stage=offline-delete')
  const publisher = await connect('b-admin-publisher')
  const offline = await offlineSession('b-admin-offline', 'b/admin/#')
  await publish(publisher, 'b/admin/retained', 'retained-payload', 1, true)
  await publish(publisher, 'b/admin/queued', 'queued-qos2', 2)
  const retained = await list('/v1/retained?limit=1')
  assert.ok(retained.some(item => item.topic === 'b/admin/retained' &&
    item.payload_bytes === String(Buffer.byteLength('retained-payload'))))
  assert.ok(!JSON.stringify(retained).includes('retained-payload'))
  const subs = await list('/v1/sessions/' + offline.handle + '/subscriptions?limit=1')
  assert.ok(subs.some(item => item.filter === 'b/admin/#' && item.qos === '2'))
  const detail = json(await request('GET', '/v1/sessions/' + offline.handle, readerToken))
  assert.ok(Number(detail.pending_count) >= 1)

  const deletePath = '/v1/sessions/' + offline.handle
  const headers = { 'If-Match': offline.etag, 'Idempotency-Key': 'Delete_0123456789ab' }
  assert.equal((await request('DELETE', deletePath, readerToken, headers)).status, 403)
  assert.equal((await request('DELETE', deletePath, operatorToken,
    { 'Idempotency-Key': headers['Idempotency-Key'] })).status, 428)
  assert.equal((await request('DELETE', deletePath, operatorToken,
    { ...headers, 'If-Match': 'W/' + offline.etag })).status, 400)
  assert.equal((await request('DELETE', deletePath, operatorToken, headers, '{}')).status, 400)
  const duplicate = await raw(
    'DELETE ' + deletePath + ' HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ' +
    operatorToken + '\r\nIf-Match: ' + offline.etag + '\r\nIf-Match: ' +
    offline.etag + '\r\nIdempotency-Key: ' + headers['Idempotency-Key'] + '\r\n\r\n')
  assert.match(duplicate, /^HTTP\/1\.1 400 /)
  const accepted = await request('DELETE', deletePath, operatorToken, headers)
  assert.equal(accepted.status, 202, accepted.text)
  assert.match(accepted.headers.location, /^\/v1\/operations\//)
  const deleteId = json(accepted).operation_id
  const deleted = await terminal(deleteId)
  assert.equal(deleted.state, 'succeeded')
  assert.equal(deleted.effect_applied, true)
  assert.equal(deleted.completion_scope, 'runtime')
  assert.equal((await request('GET', deletePath, readerToken)).status, 404)
  assert.ok((await list('/v1/retained')).some(item => item.topic === 'b/admin/retained'))
  const same = await request('DELETE', deletePath, operatorToken, headers)
  assert.equal(same.status, 200)
  assert.equal(json(same).operation_id, deleteId)
  assert.equal((await request('DELETE', deletePath, operatorToken,
    { ...headers, 'If-Match': '"' + config.boot_id + ':s:' + offline.handle + ':999"' })).status, 409)

  console.error('admin-stage=aba')
  const aba = await offlineSession('b-admin-aba', 'b/aba')
  const reconnected = await connect('b-admin-aba')
  await end(reconnected)
  assert.equal((await deleteSession(aba, 'Aba_0123456789abcd')).status, 412)

  console.error('admin-stage=kick')
  const observer = await connect('b-admin-observer')
  let willCount = 0
  observer.on('message', (topic, payload) => {
    if (topic === 'b/admin/will' && payload.toString() === 'bye') willCount++
  })
  await subscribe(observer, 'b/admin/will', 1)
  const victim = await connect('b-admin-victim', {
    will: { topic: 'b/admin/will', payload: 'bye', qos: 1, retain: false }
  })
  const connection = (await list('/v1/connections')).find(row => row.client_id === 'b-admin-victim')
  assert.ok(connection)
  const kickPath = '/v1/connections/' + connection.connection_id + '/disconnect'
  const kickHeaders = {
    'If-Match': connection.connection_etag,
    'Idempotency-Key': 'Kick_0123456789abcd'
  }
  const kicked = await request('POST', kickPath, operatorToken, kickHeaders)
  assert.equal(kicked.status, 202, kicked.text)
  const kickId = json(kicked).operation_id
  const completedKick = await terminal(kickId)
  assert.equal(completedKick.state, 'succeeded')
  assert.equal(completedKick.transport_closed, true)
  for (let i = 0; i < 100 && willCount < 1; i++) await pause(20)
  assert.equal(willCount, 1)
  await pause(100)
  assert.equal(willCount, 1)
  assert.equal((await request('POST', kickPath, operatorToken, kickHeaders)).status, 200)
  const replacement = await connect('b-admin-victim')
  await publish(replacement, 'b/admin/probe', 'alive', 1)
  assert.equal(replacement.connected, true)
  await end(replacement)
  victim.end(true)

  console.error('admin-stage=audit-gap')
  const firstAudit = json(await request('GET', '/v1/audit?limit=1', operatorToken))
  assert.ok(firstAudit.next_cursor)
  const audit = await list('/v1/audit?limit=20', operatorToken)
  assert.ok(audit.some(row => row.operation_id === deleteId && row.phase === 'completed'))
  assert.ok(audit.some(row => row.operation_id === kickId && row.phase === 'completed'))
  assert.ok(!JSON.stringify(audit).includes(operatorToken))
  for (let i = 0; i < 24; i++) {
    const row = await offlineSession('b-admin-gap-' + i, 'b/gap/' + i)
    const key = 'Gap_' + String(i).padStart(2, '0') + '_0123456789'
    const response = await deleteSession(row, key)
    assert.equal(response.status, 202, response.text)
    assert.equal((await terminal(json(response).operation_id)).state, 'succeeded')
  }
  const gap = json(await request('GET',
    '/v1/audit?limit=5&cursor=' + firstAudit.next_cursor, operatorToken))
  assert.equal(gap.gap, true)
  assert.ok(Number(gap.audit_overwritten_total) > 0)
  assert.ok(Number(gap.oldest_available_sequence) > 1)

  console.error('admin-stage=cursors')
  const firstPage = json(await request('GET', '/v1/sessions?limit=1', readerToken))
  assert.ok(firstPage.next_cursor)
  assert.equal((await request('GET', '/v1/sessions?limit=1&cursor=' +
    firstPage.next_cursor, operatorToken)).status, 403)
  const forged = firstPage.next_cursor.slice(0, -1) +
    (firstPage.next_cursor.endsWith('a') ? 'b' : 'a')
  assert.equal((await request('GET', '/v1/sessions?limit=1&cursor=' +
    forged, readerToken)).status, 410)

  if (process.env.MANAGEMENT_ADMIN_STRESS === '1') {
    for (let i = 0; i < 10000; i++) {
      const response = await request('GET', '/v1/operations/' + deleteId, operatorToken)
      assert.equal(response.status, 200, response.text)
    }
  }
  await end(observer)
  await end(publisher)
  console.log(JSON.stringify({ result: 'PASS', delete_operation: deleteId,
    kick_operation: kickId, wills: willCount,
    audit_overwritten: gap.audit_overwritten_total }))
} finally {
  for (const client of clients) client.end(true)
  clearTimeout(deadline)
}
