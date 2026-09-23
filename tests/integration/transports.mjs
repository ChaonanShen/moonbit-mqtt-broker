import assert from 'node:assert/strict'
import fs from 'node:fs'
import mqtt from 'mqtt'

const [tcpPort, tlsPort, wsPort, wssPort, cert] = process.argv.slice(2)
const urls = [
  `mqtt://127.0.0.1:${tcpPort}`,
  `mqtts://127.0.0.1:${tlsPort}`,
  `ws://127.0.0.1:${wsPort}/mqtt`,
  `wss://127.0.0.1:${wssPort}/mqtt`
]
const clients = new Set()
const timer = setTimeout(() => {
  console.error('transport matrix timed out')
  process.exit(1)
}, 30000)
const pause = ms => new Promise(resolve => setTimeout(resolve, ms))
function connect(url, clientId, clean = true) {
  return new Promise((resolve, reject) => {
    const options = {
      protocolVersion: 4, clientId, clean, reconnectPeriod: 0,
      connectTimeout: 3000,
      ...(url.startsWith('mqtts:') || url.startsWith('wss:')
        ? { ca: fs.readFileSync(cert), rejectUnauthorized: true }
        : {})
    }
    const client = mqtt.connect(url, options)
    clients.add(client)
    client.once('error', error => {
      client.end(true)
      clients.delete(client)
      reject(error)
    })
    client.once('connect', packet => resolve([client, packet]))
  })
}
async function subscribe(client, topic) {
  await new Promise((resolve, reject) =>
    client.subscribe(topic, { qos: 1 }, error => error ? reject(error) : resolve()))
}
async function publish(client, topic, payload) {
  await new Promise((resolve, reject) =>
    client.publish(topic, payload, { qos: 1 }, error => error ? reject(error) : resolve()))
}
async function end(client) {
  await new Promise(resolve => client.end(false, resolve))
  clients.delete(client)
}
try {
  let subscribers
  for (let attempt = 0; attempt < 40; attempt++) {
    try {
      subscribers = []
      for (let i = 0; i < urls.length; i++) {
        const [client] = await connect(urls[i], `transport-sub-${i}`)
        subscribers.push(client)
      }
      break
    } catch (error) {
      for (const client of clients) client.end(true)
      clients.clear()
      if (error.code !== 'ECONNREFUSED' || attempt === 39) throw error
      await pause(100)
    }
  }
  const topic = 'transport/matrix'
  const seen = subscribers.map(() => [])
  for (let i = 0; i < subscribers.length; i++) {
    subscribers[i].on('message', (receivedTopic, body) => {
      if (receivedTopic === topic) seen[i].push(body.toString())
    })
    await subscribe(subscribers[i], topic)
  }
  for (let i = 0; i < urls.length; i++) {
    const [publisher] = await connect(urls[i], `transport-pub-${i}`)
    await publish(publisher, topic, `from-${i}`)
    await end(publisher)
  }
  for (let attempt = 0; attempt < 100 && seen.some(rows => rows.length < 4); attempt++) {
    await pause(20)
  }
  for (const rows of seen) {
    assert.deepEqual(rows, ['from-0', 'from-1', 'from-2', 'from-3'])
  }
  for (const client of subscribers) await end(client)
  const [persistent] = await connect(urls[0], 'transport-resume', false)
  await subscribe(persistent, 'transport/resume')
  await end(persistent)
  const [resumed, connack] = await connect(urls[3], 'transport-resume', false)
  assert.equal(connack.sessionPresent, true)
  await end(resumed)
  console.log('TRANSPORTS_PASS four-entry QoS1 matrix and TCP-to-WSS session resume')
} finally {
  for (const client of clients) client.end(true)
  clearTimeout(timer)
}
