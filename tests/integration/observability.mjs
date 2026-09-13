import fs from 'node:fs'
import mqtt from 'mqtt'

const [url, caPath, wrongCaPath] = process.argv.slice(2)
if (!url || !caPath || !wrongCaPath) throw new Error('usage: node observability.mjs URL CA WRONG_CA')
const ca = fs.readFileSync(caPath)
const wrongCa = fs.readFileSync(wrongCaPath)
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const base = (clientId, password = 'observer-secret', certificate = ca) => ({
  clientId,
  username: 'observer',
  password,
  clean: true,
  protocolVersion: 4,
  keepalive: 2,
  reconnectPeriod: 0,
  connectTimeout: 3000,
  ca: certificate,
  rejectUnauthorized: true
})
const connect = (clientId, overrides = {}) => new Promise((resolve, reject) => {
  const client = mqtt.connect(url, { ...base(clientId), ...overrides })
  const messages = [], metricCycles = []
  let currentMetrics = {}
  client.on('message', (topic, payload, packet) => {
    const value = payload.toString()
    messages.push({ topic, value, packet })
    if (!topic.startsWith('$SYS/broker/')) return
    if (topic === '$SYS/broker/version') currentMetrics = {}
    currentMetrics[topic] = value
    // Runtime emits persistence/state last. MQTT preserves this connection's
    // packet order, so only this boundary represents a complete metric cycle.
    if (topic === '$SYS/broker/persistence/state') metricCycles.push({ ...currentMetrics })
  })
  const onError = error => {
    client.end(true)
    reject(error)
  }
  client.once('error', onError)
  client.once('connect', () => {
    client.off('error', onError)
    resolve({ client, messages, metricCycles })
  })
})
const expectRejected = async (options, description) => {
  try {
    const result = await connect(`observability-rejected-${description}`, options)
    result.client.end(true)
    throw new Error(`${description} unexpectedly connected`)
  } catch (error) {
    if (String(error).includes('unexpectedly connected')) throw error
  }
}
const end = client => new Promise(resolve => client.end(false, {}, resolve))
const subscribe = (client, filter) => new Promise((resolve, reject) => {
  client.subscribe(filter, { qos: 1 }, (error, grants) => error ? reject(error) : resolve(grants))
})
const publish = (client, topic, payload, options = {}) => new Promise((resolve, reject) => {
  client.publish(topic, payload, options, error => error ? reject(error) : resolve())
})
const waitUntil = async (predicate, description, timeout = 8000) => {
  const deadline = Date.now() + timeout
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timeout: ${description}`)
    await delay(20)
  }
}

await expectRejected({ password: 'wrong-secret' }, 'password')
await expectRejected({ ca: wrongCa }, 'ca')

const observer = await connect('observability-observer', { clean: false })
const grants = await subscribe(observer.client, '$SYS/broker/#')
if (grants[0].qos !== 1) throw new Error('explicit system ACL was not granted')
const ordinary = await connect('observability-ordinary', {
  username: 'ordinary',
  password: 'ordinary-secret'
})
await subscribe(ordinary.client, '#')
// Ensure the test contains a stale pre-publication cycle, even on a fast host.
await waitUntil(() => observer.metricCycles.length > 0, 'pre-publication metric cycle')
await publish(observer.client, 'allowed/application', 'OBSERVABILITY_PAYLOAD_SECRET_MARKER', { qos: 1 })
await publish(observer.client, '$SYS/broker/forged', 'OBSERVABILITY_FORGED_SECRET_MARKER', { qos: 1, retain: true })

const required = [
  'version', 'uptime_seconds', 'clients/connected', 'sessions/count',
  'subscriptions/count', 'retained/count', 'qos1/inflight', 'qos1/pending',
  'messages/received', 'messages/sent', 'messages/dropped', 'auth/failures',
  'acl/denials', 'tls/handshake_failures', 'persistence/state',
  'qos/inflight', 'qos/pending', 'qos2/inbound', 'qos2/await_pubrec',
  'qos2/await_pubcomp', 'qos2/received', 'qos2/duplicates', 'qos2/rejected'
].map(name => `$SYS/broker/${name}`)
await waitUntil(
  () => observer.metricCycles.some(cycle => required.every(topic => topic in cycle) && Number(cycle['$SYS/broker/messages/received']) >= 2),
  'complete post-publication system metric set'
)
if (ordinary.messages.some(message => message.topic.startsWith('$SYS/'))) {
  throw new Error('ordinary # subscription received a system metric')
}
if (observer.messages.some(message => message.topic === '$SYS/broker/forged')) {
  throw new Error('client forged a system metric')
}
const values = () => observer.metricCycles.at(-1)
const first = values()
if (first['$SYS/broker/version'] !== '0.2.0') throw new Error('version metric mismatch')
if (first['$SYS/broker/persistence/state'] !== 'healthy') throw new Error('persistence metric mismatch')
if (Number(first['$SYS/broker/messages/received']) < 2) throw new Error('received counter too small')
if (Number(first['$SYS/broker/messages/dropped']) < 1) throw new Error('dropped counter too small')
if (Number(first['$SYS/broker/auth/failures']) < 1) throw new Error('auth counter too small')
if (Number(first['$SYS/broker/acl/denials']) < 1) throw new Error('ACL counter too small')
if (Number(first['$SYS/broker/tls/handshake_failures']) < 1) throw new Error('TLS counter too small')
if (first['$SYS/broker/retained/count'] !== '0') throw new Error('system/denied publish polluted retained state')
const cycleCount = observer.metricCycles.length
await waitUntil(
  () => observer.metricCycles.length > cycleCount,
  'second system metric cycle'
)
const second = values()
if (second['$SYS/broker/messages/received'] !== first['$SYS/broker/messages/received']) {
  throw new Error('system metrics counted themselves as received')
}
if (second['$SYS/broker/messages/sent'] !== first['$SYS/broker/messages/sent']) {
  throw new Error('system metrics counted themselves as sent')
}
if (observer.messages.some(message => message.packet.qos !== 0 || message.packet.retain)) {
  throw new Error('system metric was not non-retained QoS 0')
}
await Promise.all([observer.client, ordinary.client].map(end))
console.log('OBSERVABILITY_METRICS_VERIFIED=1')
