import assert from 'node:assert/strict'
import fs from 'node:fs'
import mqtt from 'mqtt'

const [url, scenario, resultPath, quickText] = process.argv.slice(2)
const quick = quickText === 'quick'
const counts = quick
  ? { low: 8, concurrent: 24, large: 6, fanout: 8, qos2: 8, offline: 8, checkpoint: 3 }
  : { low: 120, concurrent: 800, large: 80, fanout: 120, qos2: 120, offline: 120, checkpoint: 70 }
assert.ok(url && resultPath && Object.hasOwn(counts, scenario))
const clients = new Set()
const samples = []
const pubrecSamples = []
const pubcompSamples = []
const beganAt = Date.now()
const timeout = setTimeout(() => {
  console.error('PERFORMANCE_SCENARIO_TIMEOUT ' + scenario)
  process.exit(124)
}, quick ? 30000 : 180000)
function client(id, clean = true, onMessage = () => {}) {
  return new Promise((resolve, reject) => {
    const c = mqtt.connect(url, {
      clientId: id, clean, protocolVersion: 4,
      reconnectPeriod: 0, connectTimeout: 5000
    })
    clients.add(c)
    c.on('message', onMessage)
    c.once('error', reject)
    c.once('connect', () => resolve(c))
  })
}
function subscribe(c, topic, qos = 1) {
  return new Promise((resolve, reject) =>
    c.subscribe(topic, { qos }, error => error ? reject(error) : resolve()))
}
function publish(c, topic, payload, qos = 1) {
  const started = process.hrtime.bigint()
  return new Promise((resolve, reject) =>
    c.publish(topic, payload, { qos }, error => {
      if (error) reject(error)
      else {
        samples.push(Number(process.hrtime.bigint() - started) / 1e6)
        resolve()
      }
    }))
}
function end(c) {
  return new Promise(resolve =>
    c.end(false, {}, () => { clients.delete(c); resolve() }))
}
const wait = ms => new Promise(resolve => setTimeout(resolve, ms))
async function waitFor(predicate, label) {
  for (let i = 0; i < 100; i++) {
    if (predicate()) return
    await wait(50)
  }
  throw new Error(label + ' delivery timeout')
}
function percentile(sorted, p) {
  return sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))]
}
const topic = 'durability/performance/' + scenario
let logicalBytes = 0
try {
  const n = counts[scenario]
  if (scenario === 'concurrent') {
    const publishers = await Promise.all(
      Array.from({ length: 8 }, (_, i) => client('perf-concurrent-' + i)))
    const payload = Buffer.alloc(128, 120)
    await Promise.all(publishers.map(async c => {
      for (let i = 0; i < n / publishers.length; i++)
        await publish(c, topic, payload)
    }))
    logicalBytes = n * payload.length
    await Promise.all(publishers.map(end))
  } else if (scenario === 'fanout' || scenario === 'offline') {
    const received = new Set()
    const subscribers = []
    const subscriberCount = scenario === 'offline' ? 2 : 8
    for (let i = 0; i < subscriberCount; i++) {
      const c = await client('perf-' + scenario + '-subscriber-' + i, false,
        (_, payload) => received.add(i + ':' + payload.toString()))
      await subscribe(c, topic, 1)
      subscribers.push(c)
    }
    if (scenario === 'offline') await Promise.all(subscribers.map(end))
    const publisher = await client('perf-' + scenario + '-publisher')
    if (scenario === 'qos2') {
      const sent = new Map()
      publisher.on('packetsend', packet => {
        if (packet.cmd === 'publish' && packet.qos === 2)
          sent.set(packet.messageId, process.hrtime.bigint())
      })
      publisher.on('packetreceive', packet => {
        const began = sent.get(packet.messageId)
        if (began === undefined) return
        const elapsed = Number(process.hrtime.bigint() - began) / 1e6
        if (packet.cmd === 'pubrec') pubrecSamples.push(elapsed)
        if (packet.cmd === 'pubcomp') {
          pubcompSamples.push(elapsed)
          sent.delete(packet.messageId)
        }
      })
    }
    const payloads = Array.from({ length: n },
      (_, i) => Buffer.from(String(i).padStart(8, '0') + 'x'.repeat(120)))
    for (const payload of payloads) await publish(publisher, topic, payload)
    logicalBytes = n * payloads[0].length
    if (scenario === 'offline') {
      for (let i = 0; i < subscriberCount; i++) {
        const c = await client('perf-' + scenario + '-subscriber-' + i, false,
          (_, payload) => received.add(i + ':' + payload.toString()))
        subscribers[i] = c
      }
    }
    await waitFor(() => received.size === n * subscriberCount, scenario)
    assert.equal(received.size, n * subscriberCount)
    await end(publisher)
    await Promise.all(subscribers.map(end))
  } else {
    const publisher = await client('perf-' + scenario + '-publisher')
    if (scenario === 'qos2') {
      const sent = new Map()
      publisher.on('packetsend', packet => {
        if (packet.cmd === 'publish' && packet.qos === 2)
          sent.set(packet.messageId, process.hrtime.bigint())
      })
      publisher.on('packetreceive', packet => {
        const began = sent.get(packet.messageId)
        if (began === undefined) return
        const elapsed = Number(process.hrtime.bigint() - began) / 1e6
        if (packet.cmd === 'pubrec') pubrecSamples.push(elapsed)
        if (packet.cmd === 'pubcomp') {
          pubcompSamples.push(elapsed)
          sent.delete(packet.messageId)
        }
      })
    }
    const payload = Buffer.alloc(scenario === 'large' ? 262144 : 128, 120)
    for (let i = 0; i < n; i++) {
      if (scenario === 'checkpoint') await wait(quick ? 100 : 1000)
      await publish(publisher, topic, payload, scenario === 'qos2' ? 2 : 1)
    }
    logicalBytes = n * payload.length
    await end(publisher)
  }
  assert.equal(samples.length, n)
  samples.sort((a, b) => a - b)
  pubrecSamples.sort((a, b) => a - b)
  pubcompSamples.sort((a, b) => a - b)
  if (scenario === 'qos2') {
    assert.equal(pubrecSamples.length, n)
    assert.equal(pubcompSamples.length, n)
  }
  const elapsedMs = Date.now() - beganAt
  const result = {
    scenario, quick, qos: scenario === 'qos2' ? 2 : 1,
    messages: n, payload_bytes: logicalBytes, elapsed_ms: elapsedMs,
    throughput_per_second: n * 1000 / elapsedMs,
    ack_ms_p50: percentile(samples, 0.50),
    ack_ms_p95: percentile(samples, 0.95),
    ack_ms_p99: percentile(samples, 0.99),
    ack_ms_max: samples.at(-1),
    ack_ms_samples: samples,
    pubrec_ms_p50: pubrecSamples.length ? percentile(pubrecSamples, 0.50) : null,
    pubrec_ms_p95: pubrecSamples.length ? percentile(pubrecSamples, 0.95) : null,
    pubrec_ms_p99: pubrecSamples.length ? percentile(pubrecSamples, 0.99) : null,
    pubrec_ms_max: pubrecSamples.at(-1) ?? null,
    pubcomp_ms_p50: pubcompSamples.length ? percentile(pubcompSamples, 0.50) : null,
    pubcomp_ms_p95: pubcompSamples.length ? percentile(pubcompSamples, 0.95) : null,
    pubcomp_ms_p99: pubcompSamples.length ? percentile(pubcompSamples, 0.99) : null,
    pubcomp_ms_max: pubcompSamples.at(-1) ?? null,
    status: 'PASS'
  }
  fs.writeFileSync(resultPath, JSON.stringify(result, null, 2) + '\n')
  console.log('PERFORMANCE_SCENARIO_PASS ' + scenario + ' n=' + n)
} finally {
  clearTimeout(timeout)
  for (const c of clients) c.end(true)
}
