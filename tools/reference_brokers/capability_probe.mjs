import mqtt from 'mqtt'

const url = process.argv[2]
const label = process.argv[3] ?? 'reference'
if (!url) throw new Error('usage: node capability_probe.mjs mqtt://HOST:PORT [label]')

const connect = (clientId, options = {}) => new Promise((resolve, reject) => {
  const client = mqtt.connect(url, {
    clientId,
    clean: true,
    protocolVersion: 4,
    reconnectPeriod: 0,
    connectTimeout: 5000,
    ...options
  })
  const timer = setTimeout(() => {
    client.end(true)
    reject(new Error(`${label} connect timeout`))
  }, 6000)
  client.once('error', error => {
    clearTimeout(timer)
    reject(error)
  })
  client.once('connect', connack => {
    clearTimeout(timer)
    resolve({ client, connack })
  })
})

const subscribe = (client, topic, qos) => new Promise((resolve, reject) => {
  client.subscribe(topic, { qos }, (error, grants) => error ? reject(error) : resolve(grants))
})
const publish = (client, topic, payload, options) => new Promise((resolve, reject) => {
  client.publish(topic, payload, options, error => error ? reject(error) : resolve())
})
const end = (client, force = false) => new Promise(resolve => client.end(force, {}, resolve))
const message = (client, topic, timeoutMs = 6000) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error(`${label} message timeout: ${topic}`)), timeoutMs)
  client.on('message', (actualTopic, payload, packet) => {
    if (actualTopic !== topic) return
    clearTimeout(timer)
    resolve({ payload: payload.toString(), packet })
  })
})

const subscriber = await connect(`release-${label}-subscriber`)
const grants = await subscribe(subscriber.client, 'release/reference/#', 1)
if (grants.length !== 1 || grants[0].qos !== 1) throw new Error(`${label} invalid SUBACK`)
const publisher = await connect(`release-${label}-publisher`)
const live = message(subscriber.client, 'release/reference/live')
await publish(publisher.client, 'release/reference/live', 'qos1', { qos: 1 })
if ((await live).payload !== 'qos1') throw new Error(`${label} QoS1 payload mismatch`)
await publish(publisher.client, 'release/reference/retained', 'retained', { qos: 1, retain: true })
const retainedClient = await connect(`release-${label}-retained`)
const retained = message(retainedClient.client, 'release/reference/retained')
await subscribe(retainedClient.client, 'release/reference/retained', 1)
const retainedPacket = await retained
if (retainedPacket.payload !== 'retained' || !retainedPacket.packet.retain) {
  throw new Error(`${label} retained replay mismatch`)
}
const will = message(subscriber.client, 'release/reference/will')
const doomed = await connect(`release-${label}-will`, {
  will: { topic: 'release/reference/will', payload: 'will', qos: 1, retain: false }
})
doomed.client.end(true)
if ((await will).payload !== 'will') throw new Error(`${label} Will mismatch`)
await Promise.all([subscriber.client, publisher.client, retainedClient.client].map(client => end(client)))
console.log(`${label} CONNECT SUBSCRIBE QoS0/1 retained and Will capability passed`)
