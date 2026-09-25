import assert from 'node:assert/strict'
import fs from 'node:fs'
import mqtt from 'mqtt'

const [url, versionText, warmText, measureText, output] = process.argv.slice(2)
const version = Number(versionText)
const warmSeconds = Number(warmText)
const measureSeconds = Number(measureText)
const publishers = Number(process.env.MQTT5_PERF_PUBLISHERS ?? '8')
assert.ok(url && output)
assert.ok([4, 5].includes(version))
assert.ok(Number.isInteger(warmSeconds) && warmSeconds >= 0)
assert.ok(Number.isInteger(measureSeconds) && measureSeconds >= 1)
assert.ok(Number.isInteger(publishers) && publishers >= 1 && publishers <= 64)
const deadline = setTimeout(() => {
  console.error('MQTT5_PERFORMANCE_TIMEOUT')
  process.exit(1)
}, (warmSeconds + measureSeconds + 30) * 1000)
const samples = []
const clients = []
let fatal = null
async function connect(index) {
  return new Promise((resolve, reject) => {
    const client = mqtt.connect(url, {
      protocolVersion: version,
      clientId: 'mqtt5-perf-' + version + '-' + index,
      clean: true,
      reconnectPeriod: 0,
      connectTimeout: 5000
    })
    client.on('error', error => { fatal = error })
    client.once('connect', () => resolve(client))
    client.once('close', () => {
      if (!client.connected) reject(new Error('performance CONNECT closed'))
    })
  })
}
function publish(client, index, sequence) {
  const started = process.hrtime.bigint()
  return new Promise((resolve, reject) => {
    client.publish(
      'mqtt5/perf/' + index,
      String(sequence).padStart(8, '0') + 'x'.repeat(120),
      { qos: 1 },
      error => {
        if (error) reject(error)
        else resolve(Number(process.hrtime.bigint() - started) / 1e6)
      }
    )
  })
}
const percentile = (sorted, p) =>
  sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))]
try {
  for (let index = 0; index < publishers; index++) {
    clients.push(await connect(index))
  }
  const startedAt = Date.now()
  const warmUntil = startedAt + warmSeconds * 1000
  const endAt = warmUntil + measureSeconds * 1000
  await Promise.all(clients.map(async (client, index) => {
    let sequence = 0
    while (Date.now() < endAt) {
      if (fatal) throw fatal
      const measured = Date.now() >= warmUntil
      const latency = await publish(client, index, sequence++)
      if (measured) samples.push(latency)
    }
  }))
  assert.ok(samples.length > 0)
  const rawSamples = [...samples]
  samples.sort((a, b) => a - b)
  const summary = {
    status: 'PASS',
    protocol_version: version,
    publishers,
    warm_seconds: warmSeconds,
    measure_seconds: measureSeconds,
    accepted: samples.length,
    throughput_per_second: samples.length / measureSeconds,
    ack_ms_p50: percentile(samples, 0.50),
    ack_ms_p95: percentile(samples, 0.95),
    ack_ms_p99: percentile(samples, 0.99),
    ack_ms_max: samples.at(-1)
  }
  fs.writeFileSync(output, JSON.stringify(summary, null, 2) + '\n')
  fs.writeFileSync(output + '.samples.tsv',
    'sample\tack_ms\n' +
    rawSamples.map((value, index) => index + '\t' + value.toFixed(3)).join('\n') +
    '\n')
  console.log('MQTT5_PERFORMANCE_PASS accepted=' + samples.length +
    ' throughput=' + summary.throughput_per_second.toFixed(1) +
    ' p99_ms=' + summary.ack_ms_p99.toFixed(2))
} finally {
  clearTimeout(deadline)
  for (const client of clients) client.end(true)
}
