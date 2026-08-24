import mqtt from 'mqtt'

const [mode, url, cycle] = process.argv.slice(2)
if (!mode || !url || !cycle) throw new Error('usage: node shutdown_cycle.mjs seed|verify URL CYCLE')
const clientId = `release-shutdown-${cycle}`
const topic = `release/shutdown/${cycle}`
const connect = () => new Promise((resolve, reject) => {
  const messages = []
  const client = mqtt.connect(url, {
    clientId, clean: false, protocolVersion: 4, reconnectPeriod: 0,
    connectTimeout: 3000, keepalive: 2
  })
  client.on('message', (_topic, payload) => messages.push(payload.toString()))
  client.once('error', reject)
  client.once('connect', connack => resolve({ client, connack, messages }))
})
const end = client => new Promise(resolve => client.end(false, {}, resolve))
if (mode === 'seed') {
  const session = await connect()
  await new Promise((resolve, reject) => session.client.subscribe(topic, { qos: 1 }, error => error ? reject(error) : resolve()))
  await end(session.client)
  const publisher = mqtt.connect(url, { clientId: `release-publisher-${cycle}`, protocolVersion: 4, reconnectPeriod: 0 })
  await new Promise((resolve, reject) => { publisher.once('connect', resolve); publisher.once('error', reject) })
  await new Promise((resolve, reject) => publisher.publish(topic, `cycle-${cycle}`, { qos: 1 }, error => error ? reject(error) : resolve()))
  await end(publisher)
} else if (mode === 'verify') {
  const session = await connect()
  if (!session.connack.sessionPresent) throw new Error(`cycle ${cycle} Session missing`)
  const deadline = Date.now() + 3000
  while (!session.messages.includes(`cycle-${cycle}`)) {
    if (Date.now() >= deadline) throw new Error(`cycle ${cycle} offline message missing`)
    await new Promise(resolve => setTimeout(resolve, 10))
  }
  await end(session.client)
} else throw new Error(`unknown mode ${mode}`)
