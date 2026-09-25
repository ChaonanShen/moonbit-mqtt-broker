import assert from 'node:assert/strict'
import fs from 'node:fs'
import net from 'node:net'
import mqtt from 'mqtt'

const [mode, url, armPath, markerPath, releasePath, outputPath] = process.argv.slice(2)
assert.ok(mode === 'barrier' || mode === 'verify')
const port = Number(new URL(url).port)
const mqtt5Case = process.env.MQTT5_CASE === '1'
const clients = new Set()
const overall = setTimeout(() => {
  console.error(`DURABILITY_COMMIT_TIMEOUT mode=${mode}`)
  process.exit(1)
}, 20000)
const pause = ms => new Promise(resolve => setTimeout(resolve, ms))
function connect(clientId, clean, onMessage = () => {}) {
  return new Promise((resolve, reject) => {
    const client = mqtt.connect(url, {
      protocolVersion: mqtt5Case ? 5 : 4, clientId, clean, reconnectPeriod: 0,
      ...(mqtt5Case && !clean
        ? { properties: { sessionExpiryInterval: 30 } } : {}),
      connectTimeout: 3000
    })
    clients.add(client)
    client.on('message', onMessage)
    client.once('error', reject)
    client.once('connect', packet => resolve({ client, connack: packet }))
  })
}
function end(client) {
  return new Promise(resolve => client.end(false, {}, () => {
    clients.delete(client)
    resolve()
  }))
}
function readBytes(socket, count, state) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      state.waiter = null
      reject(new Error(`raw MQTT read timeout ${count}`))
    }, 2000)
    const take = () => {
      if (state.buffer.length < count) return
      const packet = state.buffer.subarray(0, count)
      state.buffer = state.buffer.subarray(count)
      state.waiter = null
      clearTimeout(timer)
      resolve(packet)
    }
    state.waiter = take
    take()
  })
}
async function openPingConnection() {
  const socket = net.createConnection({ host: '127.0.0.1', port })
  const state = { buffer: Buffer.alloc(0), waiter: null }
  socket.on('data', chunk => {
    state.buffer = Buffer.concat([state.buffer, chunk])
    state.waiter?.()
  })
  await new Promise((resolve, reject) => {
    socket.once('connect', resolve)
    socket.once('error', reject)
  })
  const id = Buffer.from('durability-ping')
  const header = Buffer.from([0, 4, 77, 81, 84, 84, 4, 2, 0, 10])
  const payload = Buffer.concat([Buffer.from([0, id.length]), id])
  socket.write(Buffer.concat([Buffer.from([0x10, header.length + payload.length]),
    header, payload]))
  assert.deepEqual(await readBytes(socket, 4, state), Buffer.from([0x20, 2, 0, 0]))
  return { socket, state }
}
function waitForMessage(client, topic, expected) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`message timeout ${topic}`)), 5000)
    const handler = (name, body) => {
      if (name !== topic) return
      clearTimeout(timer)
      client.off('message', handler)
      try { assert.equal(body.toString(), expected); resolve() }
      catch (error) { reject(error) }
    }
    client.on('message', handler)
  })
}
try {
  if (mode === 'barrier') {
    const persistent = await connect('durability-crash-subscriber', false)
    assert.equal(persistent.connack.sessionPresent, false)
    await new Promise((resolve, reject) => persistent.client.subscribe(
      'durability/barrier', { qos: 1 }, error => error ? reject(error) : resolve()))
    await end(persistent.client)
    const publisher = (await connect('durability-crash-publisher', true)).client
    const ping = await openPingConnection()
    fs.writeFileSync(armPath, 'arm\n')
    let acked = false
    const publishAck = new Promise((resolve, reject) => publisher.publish(
      'durability/barrier', 'barrier-committed', {
        qos: 1, retain: true,
        ...(mqtt5Case ? { properties: { contentType: 'text/plain' } } : {})
      },
      error => {
        if (error) reject(error)
        else { acked = true; resolve() }
      }))
    for (let i = 0; i < 500 && !fs.existsSync(markerPath); i++) await pause(10)
    assert.ok(fs.existsSync(markerPath), 'WAL fsync hook was not reached')
    assert.equal(acked, false, 'PUBACK preceded WAL fsync')
    const pingStarted = Date.now()
    ping.socket.write(Buffer.from([0xc0, 0]))
    assert.deepEqual(await readBytes(ping.socket, 2, ping.state), Buffer.from([0xd0, 0]))
    const pingMs = Date.now() - pingStarted
    await pause(200)
    assert.equal(acked, false, 'PUBACK was released while fsync remained held')
    fs.writeFileSync(releasePath, 'release\n')
    await Promise.race([publishAck, pause(5000).then(() => {
      throw new Error('PUBACK missing after fsync release')
    })])
    ping.socket.end()
    await end(publisher)
    const evidence = { status: 'PASS', ack_after_release: true,
      other_connection_ping_ms: pingMs, held_no_ack_ms: 200 }
    fs.writeFileSync(outputPath, JSON.stringify(evidence, null, 2) + '\n')
    console.log(`DURABILITY_BARRIER_PASS ping_ms=${pingMs}`)
  } else {
    let queuedResolve, queuedReject
    const queued = new Promise((resolve, reject) => {
      queuedResolve = resolve; queuedReject = reject
    })
    const queuedTimer = setTimeout(() => queuedReject(new Error('queued message timeout')), 5000)
    const resumed = await connect('durability-crash-subscriber', false,
      (topic, body) => {
        if (topic === 'durability/barrier') {
          try {
            assert.equal(body.toString(), 'barrier-committed')
            clearTimeout(queuedTimer)
            queuedResolve()
          } catch (error) { queuedReject(error) }
        }
      })
    assert.equal(resumed.connack.sessionPresent, true)
    await queued
    await end(resumed.client)
    const fresh = await connect('durability-crash-retained', true)
    const retained = waitForMessage(fresh.client, 'durability/barrier', 'barrier-committed')
    await new Promise((resolve, reject) => fresh.client.subscribe(
      'durability/barrier', { qos: 1 }, error => error ? reject(error) : resolve()))
    await retained
    await end(fresh.client)
    console.log('DURABILITY_CRASH_RECOVERY_PASS confirmed queue and retained result')
  }
} finally {
  clearTimeout(overall)
  for (const client of clients) client.end(true)
}
