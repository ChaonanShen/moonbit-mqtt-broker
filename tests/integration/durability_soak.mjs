import assert from 'node:assert/strict'
import fs from 'node:fs'
import mqtt from 'mqtt'

const [url, durationText, publicationText, output] = process.argv.slice(2)
const durationSeconds = Number(durationText)
const publications = Number(publicationText)
assert.ok(url && output && Number.isInteger(durationSeconds) && durationSeconds >= 1)
assert.ok(Number.isInteger(publications) && publications >= 1 && publications <= 100000)
const durationMs = durationSeconds * 1000
const startedAt = Date.now()
const deadline = setTimeout(() => {
  console.error('DURABILITY_SOAK_TIMEOUT')
  process.exit(1)
}, durationMs + 30000)
const pause = ms => new Promise(resolve => setTimeout(resolve, ms))
function connect(clientId, clean) {
  return new Promise((resolve, reject) => {
    const client = mqtt.connect(url, {
      protocolVersion: 4, clientId, clean,
      reconnectPeriod: 0, connectTimeout: 3000
    })
    client.once('error', reject)
    client.once('connect', packet => resolve({ client, connack: packet }))
  })
}
const percentile = (values, fraction) => {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.min(sorted.length - 1, Math.floor(fraction * sorted.length))]
}
let subscriber, publisher
try {
  subscriber = (await connect('durability-soak-subscriber', false)).client
  const received = new Set()
  let duplicates = 0
  subscriber.on('message', (topic, body) => {
    if (topic !== 'durability/soak') return
    const id = Number(body.toString().slice(0, 8))
    if (received.has(id)) duplicates++
    received.add(id)
  })
  await new Promise((resolve, reject) => subscriber.subscribe(
    'durability/soak', { qos: 2 }, error => error ? reject(error) : resolve()))
  publisher = (await connect('durability-soak-publisher', true)).client
  const ackMs = []
  for (let i = 0; i < publications; i++) {
    const target = startedAt + (i + 1) * durationMs / publications
    const wait = target - Date.now()
    if (wait > 0) await pause(wait)
    const payload = `${String(i).padStart(8, '0')}${'x'.repeat(4088)}`
    const qos = i % 4 === 0 ? 2 : 1
    const sentAt = Date.now()
    await new Promise((resolve, reject) => publisher.publish(
      'durability/soak', payload, { qos },
      error => error ? reject(error) : resolve()))
    ackMs.push(Date.now() - sentAt)
    if ((i + 1) % 100 === 0) {
      console.log('DURABILITY_SOAK_PROGRESS sent=' + (i + 1) +
        ' received=' + received.size + ' elapsed_ms=' +
        (Date.now() - startedAt))
    }
  }
  for (let i = 0; i < 100 && received.size < publications; i++) await pause(100)
  assert.equal(received.size, publications, 'confirmed publications must arrive')
  const elapsedMs = Date.now() - startedAt
  const result = {
    status: 'PASS',
    duration_seconds: durationSeconds,
    elapsed_ms: elapsedMs,
    published: publications,
    unique_received: received.size,
    duplicates,
    ack_ms_p50: percentile(ackMs, 0.50),
    ack_ms_p95: percentile(ackMs, 0.95),
    ack_ms_p99: percentile(ackMs, 0.99),
    ack_ms_max: Math.max(...ackMs)
  }
  fs.writeFileSync(output, JSON.stringify(result, null, 2) + '\n')
  console.log(`DURABILITY_SOAK_PASS publications=${publications} unique=${received.size} duplicates=${duplicates}`)
} finally {
  clearTimeout(deadline)
  if (publisher) publisher.end(true)
  if (subscriber) subscriber.end(true)
}
