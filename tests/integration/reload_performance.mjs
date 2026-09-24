import fs from 'node:fs'
import crypto from 'node:crypto'
import { performance } from 'node:perf_hooks'
import mqtt from 'mqtt'

const [port, adminPort, mode, scenario, fixture, warmText, measureText] = process.argv.slice(2)
const warmMs = Number(warmText) * 1000
const measureMs = Number(measureText) * 1000
if (!port || !adminPort || !['off', 'snapshot', 'strict'].includes(mode) ||
    !['baseline', 'idle', 'active'].includes(scenario) ||
    !fixture || warmMs < 0 || measureMs < 1000) {
  throw new Error('usage: node reload_performance.mjs PORT ADMIN_PORT MODE baseline|idle|active FIXTURE WARM_S MEASURE_S')
}
const client = mqtt.connect('mqtts://localhost:' + port, {
  clientId: 'reload-perf-load', username: 'load', password: 'load-secret',
  ca: fs.readFileSync(fixture + '/cert.pem'), rejectUnauthorized: true,
  clean: true, protocolVersion: 4, reconnectPeriod: 0,
  connectTimeout: 3000, keepalive: 2
})
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
let fatal
client.on('error', error => { fatal = error })
await new Promise((resolve, reject) => {
  client.once('connect', resolve)
  client.once('error', reject)
})
const pings = []
let pingStarted
client.on('packetsend', packet => {
  if (packet.cmd === 'pingreq') pingStarted = performance.now()
})
client.on('packetreceive', packet => {
  if (packet.cmd === 'pingresp' && pingStarted !== undefined) {
    pings.push(performance.now() - pingStarted)
    pingStarted = undefined
  }
})
const publish = () => new Promise((resolve, reject) => {
  const started = performance.now()
  client.publish('bench/one', 'reload-performance', { qos: 1 }, error =>
    error ? reject(error) : resolve(performance.now() - started))
})
const digest = path => crypto.createHash('sha256')
  .update(fs.readFileSync(path)).digest('hex')
const updateManifest = () => {
  let value = 'version = 1\n'
  for (const [role, path] of [
    ['config', fixture + '/config.toml'],
    ['passwords', fixture + '/passwords'],
    ['mqtt_cert', fixture + '/cert.pem'],
    ['mqtt_key', fixture + '/key.pem']
  ]) {
    value += '[[materials]]\nrole = "' + role + '"\n'
    if (role.startsWith('mqtt_')) value += 'listener_id = "mqtt"\n'
    value += 'path = "' + path + '"\nsha256 = "' + digest(path) + '"\n'
  }
  fs.writeFileSync(fixture + '/manifest.toml', value, { mode: 0o600 })
}
const token = 'reloadperf.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
const base = 'http://127.0.0.1:' + adminPort
const request = async (path, options = {}) => {
  const response = await fetch(base + path, {
    ...options,
    headers: { Authorization: 'Bearer ' + token, ...options.headers },
    signal: AbortSignal.timeout(5000)
  })
  const body = await response.json()
  return { response, body }
}
let etag
if (scenario === 'active') {
  const current = await request('/v1/config')
  if (current.response.status !== 200) throw new Error('config GET failed')
  etag = current.response.headers.get('etag')
}
let reloadPromise
let reloadMs
const reload = async () => {
  const started = performance.now()
  fs.renameSync(fixture + '/passwords.next', fixture + '/passwords')
  fs.renameSync(fixture + '/cert.next', fixture + '/cert.pem')
  fs.renameSync(fixture + '/key.next', fixture + '/key.pem')
  updateManifest()
  const accepted = await request('/v1/config/reload', {
    method: 'POST',
    headers: {
      'If-Match': etag,
      'Idempotency-Key': 'reload-perf-0000000001',
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ expected_generation: 0 })
  })
  if (accepted.response.status !== 202) {
    throw new Error('reload POST failed ' + accepted.response.status)
  }
  for (let attempt = 0; attempt < 1500; attempt++) {
    const operation = await request('/v1/operations/' +
      accepted.body.operation_id)
    if (operation.response.status === 200 &&
        ['succeeded', 'failed'].includes(operation.body.state)) {
      if (operation.body.state !== 'succeeded' ||
          operation.body.effect_applied !== true) {
        throw new Error('reload operation failed')
      }
      reloadMs = performance.now() - started
      return
    }
    await sleep(20)
  }
  throw new Error('reload operation timed out')
}
const warmEnd = performance.now() + warmMs
while (performance.now() < warmEnd) {
  if (fatal) throw fatal
  await publish()
}
const samples = []
const started = performance.now()
const endAt = started + measureMs
while (performance.now() < endAt) {
  if (fatal) throw fatal
  if (scenario === 'active' && reloadPromise === undefined &&
      performance.now() >= started + measureMs / 3) {
    reloadPromise = reload()
  }
  samples.push(await publish())
}
if (reloadPromise) await reloadPromise
await new Promise(resolve => client.end(false, {}, resolve))
if (samples.length < 10) throw new Error('too few QoS1 samples')
samples.sort((a, b) => a - b)
pings.sort((a, b) => a - b)
const percentile = (values, fraction) =>
  values.length ? values[Math.min(values.length - 1,
    Math.floor(values.length * fraction))] : null
console.log(JSON.stringify({
  mode, scenario, samples: samples.length,
  throughput_per_sec: samples.length / (measureMs / 1000),
  ack_p95_ms: percentile(samples, 0.95),
  ack_p99_ms: percentile(samples, 0.99),
  ack_max_ms: samples.at(-1),
  ping_p99_ms: percentile(pings, 0.99),
  reload_ms: reloadMs ?? null
}))
