import assert from 'node:assert/strict'
import fs from 'node:fs'
import mqtt from 'mqtt'

const [mode, primaryUrl, secondaryUrl, authMode] = process.argv.slice(2)
assert.ok(['seed', 'verify'].includes(mode))
assert.ok(['anonymous', 'password'].includes(authMode))
const credentials = authMode === 'password'
  ? { username: 'sensor01', password: 'correct horse' } : {}
const cert = fs.readFileSync('/artifact/server.crt')
const clients = new Set()
const deadline = setTimeout(() => {
  console.error(`DISTRIBUTION_STRICT_TIMEOUT ${mode}`)
  process.exit(1)
}, 30000)
const pause = ms => new Promise(resolve => setTimeout(resolve, ms))
function connect(url, clientId, clean = true, onMessage = () => {}) {
  return new Promise((resolve, reject) => {
    const client = mqtt.connect(url, {
      clientId, clean, protocolVersion: 4, reconnectPeriod: 0,
      connectTimeout: 1500, ...credentials,
      ...(url.startsWith('mqtts:') || url.startsWith('wss:')
        ? { ca: cert, rejectUnauthorized: true } : {})
    })
    clients.add(client)
    client.on('message', onMessage)
    client.once('error', error => {
      client.end(true)
      clients.delete(client)
      reject(error)
    })
    client.once('connect', packet => resolve({ client, connack: packet }))
  })
}
async function waitForBroker(url, id, clean, onMessage = () => {}) {
  for (let attempt = 0; attempt < 40; attempt++) {
    try { return await connect(url, id, clean, onMessage) } catch (error) {
      if (error.code !== 'ECONNREFUSED' || attempt === 39) throw error
      await pause(100)
    }
  }
}
function subscribe(client, topic, qos) {
  return new Promise((resolve, reject) =>
    client.subscribe(topic, { qos }, error => error ? reject(error) : resolve()))
}
function publish(client, topic, body, qos, retain) {
  return new Promise((resolve, reject) =>
    client.publish(topic, body, { qos, retain }, error => error ? reject(error) : resolve()))
}
function end(client) {
  return new Promise(resolve => client.end(false, {}, () => {
    clients.delete(client)
    resolve()
  }))
}
try {
  if (mode === 'seed') {
    const durable = await waitForBroker(primaryUrl, 'dist-strict-session', false)
    assert.equal(durable.connack.sessionPresent, false)
    console.log('STRICT_STAGE durable connected')
    await subscribe(durable.client, 'dist/strict/qos2', 2)
    console.log('STRICT_STAGE durable subscribed')
    await end(durable.client)
    console.log('STRICT_STAGE durable detached')
    const publisher = await connect(secondaryUrl, 'dist-strict-publisher')
    console.log('STRICT_STAGE publisher connected')
    await publish(publisher.client, 'dist/strict/qos2', 'strict-durable-payload', 2, true)
    console.log('STRICT_STAGE QoS2 PUBCOMP observed')
    await end(publisher.client)
    console.log(`DISTRIBUTION_STRICT_SEED_PASS ${authMode}`)
  } else {
    let queuedResolve, queuedReject
    const queued = new Promise((resolve, reject) => {
      queuedResolve = resolve
      queuedReject = reject
    })
    const queuedTimer = setTimeout(() => queuedReject(new Error('QoS2 queue timeout')), 5000)
    const durable = await waitForBroker(secondaryUrl, 'dist-strict-session', false,
      (topic, payload) => {
        if (topic === 'dist/strict/qos2') {
          try {
            assert.equal(payload.toString(), 'strict-durable-payload')
            clearTimeout(queuedTimer)
            queuedResolve()
          } catch (error) { queuedReject(error) }
        }
      })
    assert.equal(durable.connack.sessionPresent, true)
    await queued
    const fresh = await connect(primaryUrl, 'dist-strict-retained-reader')
    const retained = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('retained timeout')), 5000)
      fresh.client.once('message', (topic, payload) => {
        clearTimeout(timer)
        try {
          assert.equal(topic, 'dist/strict/qos2')
          assert.equal(payload.toString(), 'strict-durable-payload')
          resolve()
        } catch (error) { reject(error) }
      })
    })
    await subscribe(fresh.client, 'dist/strict/qos2', 2)
    await retained
    await end(fresh.client)
    await end(durable.client)
    console.log(`DISTRIBUTION_STRICT_VERIFY_PASS ${authMode}`)
  }
} finally {
  clearTimeout(deadline)
  for (const client of clients) client.end(true)
}
