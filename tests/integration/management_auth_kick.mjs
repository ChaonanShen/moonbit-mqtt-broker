import assert from 'node:assert/strict'
import http from 'node:http'
import net from 'node:net'

const [adminText, mqttText, token] = process.argv.slice(2)
const adminPort = Number(adminText), mqttPort = Number(mqttText)
const pause = ms => new Promise(resolve => setTimeout(resolve, ms))
const deadline = setTimeout(() => {
  console.error('management auth kick timed out')
  process.exit(1)
}, 30000)
function field(value) {
  const body = Buffer.from(value)
  return Buffer.concat([Buffer.from([body.length >> 8, body.length & 255]), body])
}
function remainingLength(number) {
  const bytes = []
  do {
    let byte = number % 128
    number = Math.floor(number / 128)
    if (number > 0) byte |= 128
    bytes.push(byte)
  } while (number > 0)
  return Buffer.from(bytes)
}
function connectPacket() {
  const variable = Buffer.concat([field('MQTT'), Buffer.from([4, 0xc2, 0, 30])])
  const payload = Buffer.concat([
    field('b-auth-held'), field('hold'), field('correct horse')
  ])
  return Buffer.concat([Buffer.from([0x10]),
    remainingLength(variable.length + payload.length), variable, payload])
}
function get(path) {
  return new Promise((resolve, reject) => {
    const req = http.get({ host: '127.0.0.1', port: adminPort, path,
      agent: false, timeout: 2500,
      headers: { Authorization: 'Bearer ' + token } }, res => {
      const chunks = []
      res.on('data', chunk => chunks.push(chunk))
      res.on('end', () => resolve({ status: res.statusCode,
        body: Buffer.concat(chunks).toString() }))
    })
    req.on('timeout', () => req.destroy(new Error('HTTP timeout')))
    req.on('error', reject)
  })
}
function post(path, headers) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port: adminPort,
      path, method: 'POST', agent: false, timeout: 2500,
      headers: { Authorization: 'Bearer ' + token,
        'Content-Length': 0, ...headers } }, res => {
      const chunks = []
      res.on('data', chunk => chunks.push(chunk))
      res.on('end', () => resolve({ status: res.statusCode,
        body: Buffer.concat(chunks).toString() }))
    })
    req.on('timeout', () => req.destroy(new Error('HTTP timeout')))
    req.on('error', reject)
    req.end()
  })
}
let socket
try {
  socket = net.connect(mqttPort, '127.0.0.1')
  let connack = false
  socket.on('data', data => {
    if (data[0] === 0x20 && data[3] === 0) connack = true
  })
  await new Promise((resolve, reject) => {
    socket.once('connect', resolve)
    socket.once('error', reject)
  })
  socket.write(connectPacket())
  let row
  for (let i = 0; i < 200; i++) {
    const response = await get('/v1/connections?phase=authenticating')
    assert.equal(response.status, 200, response.body)
    row = JSON.parse(response.body).items.find(value => value.phase === 'authenticating')
    if (row) break
    await pause(5)
  }
  assert.ok(row, 'never observed real authenticating phase')
  assert.equal(connack, false, 'authentication completed before kick barrier')
  const accepted = await post('/v1/connections/' + row.connection_id + '/disconnect',
    { 'If-Match': row.connection_etag,
      'Idempotency-Key': 'HeldAuthKick_01234567' })
  assert.equal(accepted.status, 202, accepted.body)
  const id = JSON.parse(accepted.body).operation_id
  let record
  let sawReapWait = false
  for (let i = 0; i < 500; i++) {
    const response = await get('/v1/operations/' + id)
    assert.equal(response.status, 200, response.body)
    record = JSON.parse(response.body)
    if (record.stage === 'waiting_auth_reap') sawReapWait = true
    if (record.state === 'succeeded' || record.state === 'failed') break
    await pause(10)
  }
  assert.equal(record.state, 'succeeded', JSON.stringify(record))
  assert.equal(record.transport_closed, true)
  assert.equal(record.effect_applied, true)
  assert.equal(connack, false, 'late hash activated a kicked connection')
  assert.equal(sawReapWait, true, 'kick did not wait for native auth reap')
  const sessions = await get('/v1/sessions?limit=50')
  assert.equal(sessions.status, 200)
  assert.ok(!JSON.parse(sessions.body).items.some(value => value.client_id === 'b-auth-held'))
  console.log(JSON.stringify({ result: 'PASS', operation_id: id, waited_for_reap: sawReapWait }))
} finally {
  if (socket) socket.destroy()
  clearTimeout(deadline)
}
