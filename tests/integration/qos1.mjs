import mqtt from 'mqtt'

const url = process.argv[2]
if (!url) throw new Error('usage: node qos1.mjs mqtt://HOST:PORT')

const connectClient = (clientId, options = {}) => new Promise((resolve, reject) => {
  const inbox = []
  const waiters = []
  const client = mqtt.connect(url, {
    clientId,
    protocolVersion: 4,
    clean: true,
    keepalive: 3,
    reconnectPeriod: 0,
    connectTimeout: 3000,
    ...options
  })
  client.on('message', (topic, payload, packet) => {
    const message = { topic, payload: payload.toString(), packet }
    const index = waiters.findIndex(waiter => waiter.topic === topic)
    if (index >= 0) {
      const [waiter] = waiters.splice(index, 1)
      clearTimeout(waiter.timer)
      waiter.resolve(message)
    } else {
      inbox.push(message)
    }
  })
  const nextMessage = topic => {
    const index = inbox.findIndex(message => message.topic === topic)
    if (index >= 0) return Promise.resolve(inbox.splice(index, 1)[0])
    return new Promise((resolveMessage, rejectMessage) => {
      const waiter = { topic, resolve: resolveMessage }
      waiter.timer = setTimeout(() => {
        const waiterIndex = waiters.indexOf(waiter)
        if (waiterIndex >= 0) waiters.splice(waiterIndex, 1)
        rejectMessage(new Error(`message timed out: ${topic}`))
      }, 5000)
      waiters.push(waiter)
    })
  }
  const timer = setTimeout(() => {
    client.end(true)
    reject(new Error(`connect timed out: ${clientId}`))
  }, 5000)
  client.once('error', error => {
    clearTimeout(timer)
    reject(error)
  })
  client.once('connect', connack => {
    clearTimeout(timer)
    resolve({ client, connack, nextMessage })
  })
})

const subscribe = (client, topic, qos = 1) => new Promise((resolve, reject) => {
  client.subscribe(topic, { qos }, (error, grants) => error ? reject(error) : resolve(grants))
})

const publish = (client, topic, payload, options = {}) => new Promise((resolve, reject) => {
  client.publish(topic, payload, { qos: 1, ...options }, error => error ? reject(error) : resolve())
})

const end = client => new Promise(resolve => client.end(false, {}, resolve))

const live = await connectClient('qos1-mqttjs-live')
const publisher = await connectClient('qos1-mqttjs-publisher')
const grants = await subscribe(live.client, 'qos1/mqttjs/live', 1)
if (grants.length !== 1 || grants[0].qos !== 1) throw new Error('unexpected QoS1 SUBACK')
const liveMessage = live.nextMessage('qos1/mqttjs/live')
await publish(publisher.client, 'qos1/mqttjs/live', 'qos1-live')
if ((await liveMessage).payload !== 'qos1-live') throw new Error('QoS1 live payload mismatch')

const persistent = await connectClient('qos1-mqttjs-persistent', { clean: false })
if (persistent.connack.sessionPresent) throw new Error('new persistent session must not be present')
await subscribe(persistent.client, 'qos1/mqttjs/offline', 1)
await end(persistent.client)
await publish(publisher.client, 'qos1/mqttjs/offline', 'offline-qos1')
const resumed = await connectClient('qos1-mqttjs-persistent', { clean: false })
if (!resumed.connack.sessionPresent) throw new Error('persistent reconnect must set sessionPresent')
const offline = await resumed.nextMessage('qos1/mqttjs/offline')
if (offline.payload !== 'offline-qos1' || offline.packet.qos !== 1) {
  throw new Error('offline persistent QoS1 delivery mismatch')
}

const willObserver = await connectClient('qos1-mqttjs-will-observer')
await subscribe(willObserver.client, 'qos1/mqttjs/will', 1)
const willMessage = willObserver.nextMessage('qos1/mqttjs/will')
const doomed = await connectClient('qos1-mqttjs-doomed', {
  will: { topic: 'qos1/mqttjs/will', payload: 'qos1-will', qos: 1, retain: true }
})
doomed.client.end(true)
const observedWill = await willMessage
if (observedWill.payload !== 'qos1-will' || observedWill.packet.qos !== 1) {
  throw new Error('QoS1 Will mismatch')
}

await Promise.all([
  live.client,
  publisher.client,
  resumed.client,
  willObserver.client
].map(end))
console.log('MQTT.js QOS1 QoS 1, persistent session, and Will interoperability passed')
