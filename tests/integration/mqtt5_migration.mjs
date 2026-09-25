import assert from 'node:assert/strict'
import mqtt from 'mqtt'

const [stage, port] = process.argv.slice(2)
assert.ok(['seed', 'migrated', 'restarted', 'rollback'].includes(stage))
const url = 'mqtt://127.0.0.1:' + port
const open = (id, version, clean = true, onMessage = () => {}) => new Promise((resolve, reject) => {
  const client = mqtt.connect(url, {
    protocolVersion: version,
    clientId: id, clean,
    reconnectPeriod: 0, connectTimeout: 5000,
    ...(version === 5 && !clean
      ? { properties: { sessionExpiryInterval: 30 } } : {})
  })
  client.on('message', onMessage)
  client.once('error', reject)
  client.once('connect', packet => resolve({ client, packet }))
})
const end = client => new Promise(resolve => client.end(false, {}, resolve))
const subscribe = client => new Promise((resolve, reject) => client.subscribe(
  'mqtt5/migration', { qos: 1 }, error => error ? reject(error) : resolve()
))
const publish = (client, payload, properties = {}) =>
  new Promise((resolve, reject) => client.publish(
    'mqtt5/migration', payload, { qos: 1, retain: true, properties },
    error => error ? reject(error) : resolve()
  ))
const message = client => Promise.race([
  new Promise(resolve => client.once('message',
    (topic, payload, packet) => resolve({
      topic, payload: payload.toString(), packet
    }))),
  new Promise((_, reject) => setTimeout(
    () => reject(new Error('migration retained timeout')), 5000
  ))
])
if (stage === 'seed') {
  const subscriber = await open('migration-persistent', 4, false)
  assert.equal(subscriber.packet.sessionPresent, false)
  await subscribe(subscriber.client)
  await end(subscriber.client)
  const publisher = await open('migration-v311-publisher', 4)
  await publish(publisher.client, 'legacy')
  await end(publisher.client)
} else if (stage === 'migrated') {
  const old = await open('migration-old-retained', 5)
  const oldMessage = message(old.client)
  await subscribe(old.client)
  const retained = await oldMessage
  assert.equal(retained.payload, 'legacy')
  assert.equal(retained.packet.properties?.contentType, undefined)
  await end(old.client)
  let queuedResolve
  const queued = new Promise(resolve => { queuedResolve = resolve })
  const resumed = await open('migration-persistent', 5, false,
    (topic, payload) => {
      if (topic === 'mqtt5/migration' && payload.toString() === 'legacy') {
        queuedResolve()
      }
    })
  assert.equal(resumed.packet.sessionPresent, true)
  await Promise.race([
    queued,
    new Promise((_, reject) => setTimeout(
      () => reject(new Error('legacy pending migration timeout')), 5000
    ))
  ])
  const delivered = message(resumed.client)
  const publisher = await open('migration-v5-publisher', 5)
  await publish(publisher.client, 'v5', { contentType: 'text/plain' })
  const live = await delivered
  assert.equal(live.payload, 'v5')
  assert.equal(live.packet.properties?.contentType, 'text/plain')
  await end(publisher.client)
  await end(resumed.client)
} else {
  const version = stage === 'rollback' ? 4 : 5
  const reader = await open('migration-reader-' + stage, version)
  const retained = message(reader.client)
  await subscribe(reader.client)
  const got = await retained
  assert.equal(got.payload, stage === 'rollback' ? 'legacy' : 'v5')
  if (version === 5) {
    assert.equal(got.packet.properties?.contentType, 'text/plain')
  }
  await end(reader.client)
}
console.log('M-T13/X-T07 MQTT5 migration stage passed: ' + stage)
