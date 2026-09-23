import assert from 'node:assert/strict'
import http from 'node:http'
import net from 'node:net'
import mqtt from 'mqtt'

const [adminPortText, mqttPortText, metricsToken, readToken, countText = '10000'] = process.argv.slice(2)
const adminPort = Number(adminPortText)
const mqttPort = Number(mqttPortText)
const count = Number(countText)
assert.ok(Number.isInteger(adminPort) && Number.isInteger(mqttPort))
assert.ok(Number.isInteger(count) && count >= 1)
const origin = '127.0.0.1'
const clients = new Set()
const pause = ms => new Promise(resolve => setTimeout(resolve, ms))
const deadline = setTimeout(() => {
  console.error('management process integration timed out')
  process.exit(1)
}, 120000)
function get(path, token) {
  return new Promise((resolve, reject) => {
    const req = http.get({
      host: origin, port: adminPort, path, agent: false, timeout: 3000,
      headers: token ? { Authorization: `Bearer ${token}` } : {}
    }, res => {
      const chunks = []
      res.on('data', chunk => chunks.push(chunk))
      res.on('end', () => resolve({
        status: res.statusCode,
        headers: res.headers,
        body: Buffer.concat(chunks).toString()
      }))
    })
    req.on('timeout', () => req.destroy(new Error('management request timeout')))
    req.on('error', reject)
  })
}
function raw(head) {
  return new Promise((resolve, reject) => {
    let output = Buffer.alloc(0)
    const socket = net.connect(adminPort, origin)
    socket.setTimeout(3000)
    socket.on('connect', () => socket.write(head))
    socket.on('data', chunk => { output = Buffer.concat([output, chunk]) })
    socket.on('timeout', () => socket.destroy(new Error('raw HTTP timeout')))
    socket.on('error', error => output.length ? resolve(output.toString()) : reject(error))
    socket.on('close', () => output.length ? resolve(output.toString()) : reject(new Error('no raw response')))
  })
}
function connect(suffix) {
  return new Promise((resolve, reject) => {
    const client = mqtt.connect(`mqtt://127.0.0.1:${mqttPort}`, {
      clientId: `management-${suffix}`, protocolVersion: 4,
      reconnectPeriod: 0, connectTimeout: 2000
    })
    clients.add(client)
    client.once('connect', () => resolve(client))
    client.once('error', reject)
  })
}
function publish(client, topic, payload, qos) {
  return new Promise((resolve, reject) => {
    client.publish(topic, payload, { qos }, error => error ? reject(error) : resolve())
  })
}
function metric(body, name) {
  const match = body.match(new RegExp(`^${name} ([0-9]+)(?:\\.[0-9]+)?$`, 'm'))
  assert.ok(match, `missing metric ${name}`)
  return Number(match[1])
}
try {
  const healthy = await get('/health/live')
  assert.equal(healthy.status, 200)
  assert.equal(healthy.body, '{"status":"live"}')
  assert.equal((await get('/health/ready')).status, 200)
  for (const [name, token, path, status] of [
    ['missing', undefined, '/metrics', 401],
    ['unknown-id', 'missing.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef', '/metrics', 401],
    ['bad-secret', 'metrics1.ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff', '/metrics', 401],
    ['metrics-status', metricsToken, '/v1/status', 403],
    ['read-metrics', readToken, '/metrics', 403],
    ['query-token', undefined, `/metrics?token=${metricsToken}`, 400],
    ['unknown-route', undefined, '/does-not-exist', 404]
  ]) {
    const result = await get(path, token)
    assert.equal(result.status, status, name)
    if (status === 401) assert.match(result.headers['www-authenticate'], /Bearer/)
  }
  for (const [name, head, status] of [
    ['duplicate-host', 'GET /health/live HTTP/1.1\r\nHost: localhost\r\nHost: localhost\r\n\r\n', 400],
    ['duplicate-auth', `GET /metrics HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ${metricsToken}\r\nAuthorization: Bearer ${metricsToken}\r\n\r\n`, 400],
    ['obs-fold', 'GET /health/live HTTP/1.1\r\nHost: localhost\r\n folded\r\n\r\n', 400],
    ['lf-only', 'GET /health/live HTTP/1.1\nHost: localhost\n\n', 400],
    ['transfer-encoding', 'GET /health/live HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n', 400],
    ['cookie-token', `GET /metrics HTTP/1.1\r\nHost: localhost\r\nCookie: token=${metricsToken}\r\n\r\n`, 401],
    ['body-token', `GET /metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: ${metricsToken.length}\r\n\r\n${metricsToken}`, 400],
    ['post', 'POST /health/live HTTP/1.1\r\nHost: localhost\r\n\r\n', 405],
    ['suffix', 'GET /health/live HTTP/1.1\r\nHost: localhost\r\n\r\nGET /health/live HTTP/1.1\r\nHost: localhost\r\n\r\n', 400]
  ]) {
    const response = await raw(head)
    assert.match(response, new RegExp(`^HTTP/1\\.1 ${status} `), name)
  }
  const before = await get('/metrics', metricsToken)
  assert.equal(before.status, 200)
  assert.match(before.headers['content-type'], /^text\/plain; version=0\.0\.4/)
  assert.ok(before.body.endsWith('\n'))
  const subscriber = await connect('subscriber')
  const publisher = await connect('publisher')
  await new Promise((resolve, reject) =>
    subscriber.subscribe('management/integration', { qos: 2 }, error => error ? reject(error) : resolve()))
  let arrivals = 0
  subscriber.on('message', () => { arrivals++ })
  for (const qos of [0, 1, 2]) await publish(publisher, 'management/integration', `qos-${qos}`, qos)
  for (let i = 0; i < 40 && arrivals < 3; i++) await pause(25)
  assert.equal(arrivals, 3, 'QoS0/1/2 arrived during management traffic')
  await pause(250)
  const after = await get('/metrics', metricsToken)
  assert.equal(after.status, 200)
  assert.ok(metric(after.body, 'moonbit_mqtt_broker_publish_packets_received_total') >=
    metric(before.body, 'moonbit_mqtt_broker_publish_packets_received_total') + 3)
  assert.ok(metric(after.body, 'moonbit_mqtt_broker_qos2_received_total') >=
    metric(before.body, 'moonbit_mqtt_broker_qos2_received_total') + 1)
  const receivedCount = metric(after.body, 'moonbit_mqtt_broker_publish_packets_received_total')
  await pause(200)
  const scrapeAgain = await get('/metrics', metricsToken)
  assert.equal(metric(scrapeAgain.body, 'moonbit_mqtt_broker_publish_packets_received_total'), receivedCount,
    'scrapes must not change MQTT received count')
  // Scrape and authenticate while MQTT replaces an active connection with
  // the same Client ID. The old transport must close and the new one must work.
  const oldClosed = new Promise(resolve => publisher.once('close', resolve))
  const [replacement, takeoverMetrics, takeoverStatus, takeoverDenied] = await Promise.all([
    connect('publisher'), get('/metrics', metricsToken),
    get('/v1/status', readToken),
    get('/metrics', 'metrics1.' + 'f'.repeat(64))
  ])
  await Promise.race([
    oldClosed,
    pause(2000).then(() => { throw new Error('old MQTT transport survived takeover') })
  ])
  assert.equal(takeoverMetrics.status, 200)
  assert.equal(takeoverStatus.status, 200)
  assert.equal(takeoverDenied.status, 401)
  await publish(replacement, 'management/integration', 'post-takeover', 1)
  for (let i = 0; i < 40 && arrivals < 4; i++) await pause(25)
  assert.equal(arrivals, 4)
  // Deterministic malformed and valid header values must stay within fixed
  // status and metric-label sets under repeated untrusted input.
  let seed = 0x5eed1234
  for (let i = 0; i < 256; i++) {
    let value = ''
    for (let j = 0; j < 20; j++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0
      value += String.fromCharCode(i % 7 === 0 && j === 3 ? 1 : 32 + (seed % 95))
    }
    const response = await raw(`GET /health/live HTTP/1.1\r\nHost: localhost\r\nX-Random: ${value}\r\n\r\n`)
    assert.match(response, /^HTTP\/1\.1 (200|400) /)
  }
  const authBefore = await get('/metrics', metricsToken)
  const rejectedBefore = Number(authBefore.body.match(
    /^moonbit_mqtt_broker_management_rejected_total\{reason="auth"\} ([0-9]+)$/m
  )[1])
  let badIssued = 0
  async function badWorker() {
    while (badIssued < 1000) {
      badIssued++
      assert.equal((await get('/metrics', 'metrics1.' + 'f'.repeat(64))).status, 401)
    }
  }
  await Promise.all(Array.from({ length: 8 }, badWorker))
  const authAfter = await get('/metrics', metricsToken)
  const rejectedAfter = Number(authAfter.body.match(
    /^moonbit_mqtt_broker_management_rejected_total\{reason="auth"\} ([0-9]+)$/m
  )[1])
  assert.ok(rejectedAfter >= rejectedBefore + 1000)
  const series = authAfter.body.split('\n').filter(line => line && !line.startsWith('#'))
  assert.ok(series.length <= 256)
  assert.equal(new Set(series.map(line => line.slice(0, line.lastIndexOf(' ')))).size, series.length)
  let completed = 0
  const started = performance.now()
  async function worker() {
    while (completed < count) {
      completed++
      const response = await get('/health/live')
      assert.equal(response.status, 200)
    }
  }
  await Promise.all(Array.from({ length: 8 }, worker))
  const elapsedMs = Math.round(performance.now() - started)
  const status = await get('/v1/status', readToken)
  assert.equal(status.status, 200)
  const parsed = JSON.parse(status.body)
  assert.equal(parsed.api_version, '1')
  assert.equal(parsed.lifecycle, 'serving')
  console.log(JSON.stringify({ result: 'PASS', requests: count, elapsed_ms: elapsedMs,
    qos_arrivals: arrivals, boot_id: parsed.boot_id }))
} finally {
  for (const client of clients) await new Promise(resolve => client.end(true, resolve))
  clearTimeout(deadline)
}
