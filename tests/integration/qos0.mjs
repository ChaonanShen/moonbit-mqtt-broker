import mqtt from 'mqtt'

const url = process.argv[2]
if (!url) throw new Error('usage: node qos0.mjs mqtt://HOST:PORT')

const connect = (clientId, options = {}) => new Promise((resolve, reject) => {
  const client = mqtt.connect(url, {
    clientId,
    protocolVersion: 4,
    clean: true,
    keepalive: 3,
    reconnectPeriod: 0,
    connectTimeout: 3000,
    ...options
  })
  const timer = setTimeout(() => {
    client.end(true)
    reject(new Error(`connect timed out: ${clientId}`))
  }, 5000)
  client.once('error', error => {
    clearTimeout(timer)
    reject(error)
  })
  client.once('connect', () => {
    clearTimeout(timer)
    resolve(client)
  })
})

const subscribe = (client, topic, qos = 0) => new Promise((resolve, reject) => {
  client.subscribe(topic, { qos }, (error, grants) => error ? reject(error) : resolve(grants))
})

const publish = (client, topic, payload, options = {}) => new Promise((resolve, reject) => {
  client.publish(topic, payload, { qos: 0, ...options }, error => error ? reject(error) : resolve())
})

const nextMessage = (client, expectedTopic) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error(`message timed out: ${expectedTopic}`)), 5000)
  const handler = (topic, payload, packet) => {
    if (topic !== expectedTopic) return
    clearTimeout(timer)
    client.off('message', handler)
    resolve({ payload: payload.toString(), packet })
  }
  client.on('message', handler)
})

const end = client => new Promise(resolve => client.end(false, {}, resolve))

const subscriber = await connect('network-mqttjs-subscriber')
const publisher = await connect('network-mqttjs-publisher')
const grants = await subscribe(subscriber, 'network/live/+', 1)
if (grants.length !== 1 || grants[0].qos !== 1) throw new Error('unexpected SUBACK grant')
const liveMessage = nextMessage(subscriber, 'network/live/value')
await publish(publisher, 'network/live/value', 'hello')
if ((await liveMessage).payload !== 'hello') throw new Error('unexpected live payload')

await subscribe(subscriber, 'network/retained/#')
const retainedLive = nextMessage(subscriber, 'network/retained/value')
await publish(publisher, 'network/retained/value', 'saved', { retain: true })
if ((await retainedLive).packet.retain !== false) {
  throw new Error('live delivery of retained publish must clear RETAIN')
}
const replay = await connect('network-mqttjs-replay')
const retainedMessage = nextMessage(replay, 'network/retained/value')
await subscribe(replay, 'network/retained/#')
const retained = await retainedMessage
if (retained.payload !== 'saved' || retained.packet.retain !== true) {
  throw new Error(`retained replay mismatch: payload=${retained.payload} retain=${retained.packet.retain}`)
}

const observer = await connect('network-mqttjs-will-observer')
await subscribe(observer, 'network/will')
const willMessage = nextMessage(observer, 'network/will')
const doomed = await connect('network-mqttjs-doomed', {
  will: { topic: 'network/will', payload: 'bye', qos: 0, retain: false }
})
doomed.end(true)
if ((await willMessage).payload !== 'bye') throw new Error('unexpected will payload')

const old = await connect('network-mqttjs-takeover', {
  will: { topic: 'network/takeover', payload: 'old', qos: 0, retain: false }
})
await subscribe(observer, 'network/takeover')
const takeoverWill = nextMessage(observer, 'network/takeover')
const replacement = await connect('network-mqttjs-takeover')
if ((await takeoverWill).payload !== 'old') throw new Error('takeover will missing')

await publish(publisher, 'network/retained/value', '', { retain: true })
await Promise.all([subscriber, publisher, replay, observer, replacement].map(end))
old.end(true)
console.log('MQTT.js NETWORK QoS 0, retained, will, and takeover interoperability passed')
