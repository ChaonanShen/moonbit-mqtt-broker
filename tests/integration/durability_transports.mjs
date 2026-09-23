import assert from 'node:assert/strict'
import fs from 'node:fs'
import mqtt from 'mqtt'

const [mode, tcpPort, tlsPort, wsPort, wssPort, certPath] = process.argv.slice(2)
assert.ok(mode === 'seed' || mode === 'verify')
const certificate = fs.readFileSync(certPath)
const urls = {
  tcp: `mqtt://127.0.0.1:${tcpPort}`,
  tls: `mqtts://127.0.0.1:${tlsPort}`,
  ws: `ws://127.0.0.1:${wsPort}/mqtt`,
  wss: `wss://127.0.0.1:${wssPort}/mqtt`
}
const clients = new Set()
const overall = setTimeout(() => {
  console.error(`DURABILITY_TRANSPORT_TIMEOUT mode=${mode}`)
  process.exit(1)
}, 30000)

function connect(url, clientId, clean = true, onMessage = () => {}) {
  return new Promise((resolve, reject) => {
    const client = mqtt.connect(url, {
      protocolVersion: 4,
      clientId,
      clean,
      reconnectPeriod: 0,
      connectTimeout: 3000,
      ...(url.startsWith('mqtts:') || url.startsWith('wss:')
        ? { ca: certificate, rejectUnauthorized: true }
        : {})
    })
    clients.add(client)
    client.on('message', onMessage)
    client.once('error', reject)
    client.once('connect', packet => resolve({ client, connack: packet }))
  })
}
function subscribe(client, topic, qos = 2) {
  return new Promise((resolve, reject) =>
    client.subscribe(topic, { qos }, error => error ? reject(error) : resolve()))
}
function publish(client, topic, body, qos, retain = true) {
  return new Promise((resolve, reject) =>
    client.publish(topic, body, { qos, retain }, error => error ? reject(error) : resolve()))
}
function waitForMessage(client, topic, expected) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      client.off('message', onMessage)
      reject(new Error(`message timeout topic=${topic}`))
    }, 5000)
    const onMessage = (receivedTopic, body) => {
      if (receivedTopic !== topic) return
      clearTimeout(timeout)
      client.off('message', onMessage)
      try {
        assert.equal(body.toString(), expected)
        resolve()
      } catch (error) { reject(error) }
    }
    client.on('message', onMessage)
  })
}
function end(client) {
  return new Promise(resolve => {
    client.end(false, {}, () => {
      clients.delete(client)
      resolve()
    })
  })
}

try {
  if (mode === 'seed') {
    const durable = await connect(urls.tcp, 'durable-transport-session', false)
    assert.equal(durable.connack.sessionPresent, false)
    await subscribe(durable.client, 'durability/transport', 2)
    await end(durable.client)
    const tls = await connect(urls.tls, 'durability-tls-publisher')
    await publish(tls.client, 'durability/transport', 'durable-qos2', 2)
    await end(tls.client)
    const ws = await connect(urls.ws, 'durability-ws-publisher')
    await publish(ws.client, 'durability/ws', 'ws-value', 1)
    await end(ws.client)
    const wss = await connect(urls.wss, 'durability-wss-publisher')
    await publish(wss.client, 'durability/wss', 'wss-value', 1)
    await end(wss.client)
    console.log('DURABILITY_TRANSPORT_SEED_PASS four-entry ACK and persistent queue')
  } else {
    let queuedResolve, queuedReject
    const queued = new Promise((resolve, reject) => {
      queuedResolve = resolve
      queuedReject = reject
    })
    const queuedTimeout = setTimeout(() => queuedReject(new Error('queued QoS2 timeout')), 5000)
    const resumed = await connect(urls.wss, 'durable-transport-session', false,
      (topic, body) => {
        if (topic === 'durability/transport') {
          try {
            assert.equal(body.toString(), 'durable-qos2')
            clearTimeout(queuedTimeout)
            queuedResolve()
          } catch (error) { queuedReject(error) }
        }
      })
    assert.equal(resumed.connack.sessionPresent, true)
    await queued
    const freshWs = await connect(urls.ws, 'durability-ws-reader')
    const retainedQos2 = waitForMessage(freshWs.client, 'durability/transport', 'durable-qos2')
    await subscribe(freshWs.client, 'durability/transport', 2)
    await retainedQos2
    await end(freshWs.client)
    const freshTcp = await connect(urls.tcp, 'durability-tcp-reader')
    const retainedWs = waitForMessage(freshTcp.client, 'durability/ws', 'ws-value')
    await subscribe(freshTcp.client, 'durability/ws', 1)
    await retainedWs
    await end(freshTcp.client)
    const freshTls = await connect(urls.tls, 'durability-tls-reader')
    const retainedWss = waitForMessage(freshTls.client, 'durability/wss', 'wss-value')
    await subscribe(freshTls.client, 'durability/wss', 1)
    await retainedWss
    await end(freshTls.client)
    const takeover = await connect(urls.tcp, 'durable-transport-session', false)
    assert.equal(takeover.connack.sessionPresent, true)
    await end(takeover.client)
    resumed.client.end(true)
    clients.delete(resumed.client)
    console.log('DURABILITY_TRANSPORT_VERIFY_PASS QoS2 recovery retained and TCP-WSS takeover')
  }
} finally {
  clearTimeout(overall)
  for (const client of clients) client.end(true)
}
