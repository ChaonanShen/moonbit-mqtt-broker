// Run in a separate client container; never install client libraries in the broker.
import assert from 'node:assert/strict'
import fs from 'node:fs'
import mqtt from 'mqtt'

const [url, authMode] = process.argv.slice(2)
assert.ok(url && ['anonymous', 'password'].includes(authMode))
const authenticated = authMode === 'password'
const tls = url.startsWith('mqtts:')
const clients = new Set()
const deadline = setTimeout(() => { console.error('distribution MQTT smoke timed out'); process.exit(1) }, 30000)
const pause = ms => new Promise(resolve => setTimeout(resolve, ms))
function connect(suffix, credentials = authenticated ? { username: 'sensor01', password: 'correct horse' } : {}) {
  return new Promise((resolve, reject) => {
    const client = mqtt.connect(url, {
      protocolVersion: 4, reconnectPeriod: 0, connectTimeout: 1000,
      clientId: `distribution-${suffix}`, clean: true,
      ...(tls ? { ca: fs.readFileSync('/artifact/server.crt'), rejectUnauthorized: true } : {}),
      ...credentials
    })
    clients.add(client)
    client.once('error', error => { client.end(true); clients.delete(client); reject(error) })
    client.once('connect', () => resolve(client))
  })
}
try {
  let subscriber
  for (let attempt = 0; attempt < 40; attempt++) {
    try { subscriber = await connect('subscriber'); break } catch (error) {
      if (error.code !== 'ECONNREFUSED' || attempt === 39) throw error
      await pause(100)
    }
  }
  assert.ok(subscriber)
  await new Promise((resolve, reject) => subscriber.subscribe('distribution/smoke', { qos: 1 }, (error, grants) => {
    if (error) return reject(error)
    assert.equal(grants[0].qos, 1)
    resolve()
  }))
  const received = new Promise(resolve => subscriber.once('message', (topic, payload) => resolve([topic, payload.toString()])))
  const publisher = await connect('publisher')
  await new Promise((resolve, reject) => publisher.publish('distribution/smoke', 'packaged-runtime-ok', { qos: 1 }, error => error ? reject(error) : resolve()))
  assert.deepEqual(await received, ['distribution/smoke', 'packaged-runtime-ok'])
  if (authenticated) {
    for (const [name, credentials, expected] of [
      ['bad-password', { username: 'sensor01', password: 'wrong' }, 4],
      ['missing-password', {}, 5]
    ]) {
      await assert.rejects(connect(name, credentials), error => error.code === expected)
    }
  }
  console.log(`DISTRIBUTION MQTT QoS1 smoke passed: ${tls ? 'TLS' : 'plaintext'}, ${authMode}`)
} finally {
  for (const client of clients) await new Promise(resolve => client.end(true, resolve))
  clearTimeout(deadline)
}
