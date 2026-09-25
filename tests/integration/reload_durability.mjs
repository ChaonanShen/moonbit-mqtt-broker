import mqtt from 'mqtt'

const [stage, port] = process.argv.slice(2)
const mqtt5Reload = process.env.MQTT5_RELOAD === '1'
if (!['seed', 'verify'].includes(stage) || !port) {
  throw new Error('usage: node reload_durability.mjs seed|verify PORT')
}
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
const connect = clientId => new Promise((resolve, reject) => {
  const client = mqtt.connect('mqtt://127.0.0.1:' + port, {
    clientId, clean: false, protocolVersion: mqtt5Reload ? 5 : 4,
    ...(mqtt5Reload ? { properties: { sessionExpiryInterval: 30 } } : {}),
    reconnectPeriod: 0, connectTimeout: 3000
  })
  client.once('error', reject)
  client.once('connect', () => {
    client.off('error', reject)
    resolve(client)
  })
})
const end = client => new Promise(resolve => client.end(false, {}, resolve))
const publish = client => new Promise((resolve, reject) => {
  client.publish('private/one', 'queued-before-reload', { qos: 1 }, error =>
    error ? reject(error) : resolve())
})
if (stage === 'seed') {
  const subscriber = await connect('reload-durable-subscriber')
  await new Promise((resolve, reject) => {
    subscriber.subscribe('private/#', { qos: 1 }, error =>
      error ? reject(error) : resolve())
  })
  await end(subscriber)
  const publisher = await connect('reload-durable-publisher')
  await publish(publisher)
  await end(publisher)
  console.log('durable revoked subscription and pending message seeded')
} else {
  const subscriber = await connect('reload-durable-subscriber')
  let deliveries = 0
  subscriber.on('message', () => { deliveries++ })
  await sleep(300)
  if (deliveries !== 0) throw new Error('revoked queued message returned')
  const publisher = await connect('reload-durable-publisher')
  await publish(publisher)
  await sleep(300)
  if (deliveries !== 0) throw new Error('revoked subscription returned')
  await end(publisher)
  await end(subscriber)
  console.log('durable revocation survived crash and policy reallow')
}
