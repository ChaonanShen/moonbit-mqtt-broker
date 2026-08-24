import fs from 'node:fs'
import mqtt from 'mqtt'

const [mode, url, caPath] = process.argv.slice(2)
if (!mode || !url || !caPath) throw new Error('usage: node m8_security.mjs exercise|seed|verify URL CA')

const ca = fs.readFileSync(caPath)
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const options = (clientId, username, password, overrides = {}) => ({
  clientId,
  username,
  password,
  clean: true,
  protocolVersion: 4,
  keepalive: 5,
  reconnectPeriod: 0,
  connectTimeout: 5000,
  ca,
  rejectUnauthorized: true,
  ...overrides
})

const connect = (clientId, username, password, overrides = {}) => new Promise((resolve, reject) => {
  const client = mqtt.connect(url, options(clientId, username, password, overrides))
  const messages = []
  client.on('message', (topic, payload, packet) => messages.push({ topic, payload: payload.toString(), packet }))
  const onError = error => {
    client.end(true)
    reject(error)
  }
  client.once('error', onError)
  client.once('connect', connack => {
    client.off('error', onError)
    resolve({ client, connack, messages })
  })
})

const rejected = async (clientId, username, password, expectedCode, overrides = {}) => {
  try {
    const connected = await connect(clientId, username, password, overrides)
    connected.client.end(true)
    throw new Error(`connection unexpectedly accepted: ${clientId}`)
  } catch (error) {
    if (String(error).includes('unexpectedly accepted')) throw error
    const code = error.code ?? error.reasonCode ?? error.returnCode
    if (code !== expectedCode && !String(error).includes(`code: ${expectedCode}`)) {
      throw new Error(`expected CONNACK ${expectedCode}, got ${code}: ${error}`)
    }
  }
}

const end = client => new Promise(resolve => client.end(false, {}, resolve))
const publish = (client, topic, payload, publishOptions = {}) => new Promise((resolve, reject) => {
  client.publish(topic, payload, publishOptions, error => error ? reject(error) : resolve())
})
const subscribe = (client, subscriptions) => new Promise((resolve, reject) => {
  const topics = Object.fromEntries(
    subscriptions.map(subscription => [subscription.topic, { qos: subscription.qos }])
  )
  client.subscribe(topics, (error, grants) => {
    if (error?.packet?.granted) {
      resolve(error.packet.granted.map(qos => ({ qos })))
    } else if (error) {
      reject(error)
    } else {
      resolve(grants)
    }
  })
})
const waitUntil = async (predicate, description, timeoutMs = 8000) => {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timeout: ${description}`)
    await delay(10)
  }
}

const exercise = async () => {
  await rejected('m8-missing', undefined, undefined, 5)
  await rejected('m8-wrong', 'alice', 'wrong-secret', 4)
  await rejected('m8-unknown', 'unknown', 'alice-secret', 4)
  await rejected('m8-will-denied', 'alice', 'alice-secret', 5, {
    will: { topic: 'denied/will', payload: 'must-not-fire', qos: 1, retain: true }
  })

  const alice = await connect('m8-alice', 'alice', 'alice-secret')
  const grants = await subscribe(alice.client, [
    { topic: 'allowed/+', qos: 1 },
    { topic: 'denied/#', qos: 1 },
    { topic: '#', qos: 0 }
  ])
  if (grants.map(grant => grant.qos).join(',') !== '1,128,128') {
    throw new Error(`partial ACL SUBACK mismatch: ${grants.map(grant => grant.qos)}`)
  }
  const bob = await connect('m8-bob-observer', 'bob', 'bob-secret')
  const bobGrants = await subscribe(bob.client, [{ topic: 'denied/#', qos: 1 }])
  if (bobGrants[0].qos !== 1) throw new Error('Bob read ACL was not granted')

  await publish(alice.client, 'allowed/live', 'allowed-value', { qos: 1 })
  await waitUntil(() => alice.messages.some(message => message.payload === 'allowed-value'), 'allowed delivery')
  await publish(alice.client, 'denied/qos0', 'blocked-qos0', { qos: 0, retain: true })
  await publish(alice.client, 'denied/qos1', 'blocked-qos1', { qos: 1, retain: true })
  await publish(alice.client, '$SYS/broker/forged', 'blocked-system', { qos: 1, retain: true })
  await delay(300)
  if (bob.messages.some(message => message.payload.startsWith('blocked-'))) {
    throw new Error('denied publication was routed')
  }
  await end(bob.client)
  const bobReplay = await connect('m8-bob-replay', 'bob', 'bob-secret')
  await subscribe(bobReplay.client, [{ topic: 'denied/#', qos: 1 }])
  await delay(300)
  if (bobReplay.messages.length !== 0) throw new Error('denied retained publication was stored')
  await Promise.all([alice.client, bobReplay.client].map(end))
  console.log('M8_AUTH_ACL_EXERCISE=1')
}

const seed = async () => {
  const session = await connect('m8-owned-session', 'alice', 'alice-secret', { clean: false })
  await subscribe(session.client, [{ topic: 'allowed/offline', qos: 1 }])
  await end(session.client)
  await rejected('m8-owned-session', 'bob', 'bob-secret', 5, { clean: false })
  const publisher = await connect('m8-seed-publisher', 'alice', 'alice-secret')
  await publish(publisher.client, 'allowed/offline', 'owner-offline', { qos: 1 })
  await end(publisher.client)
  console.log('M8_OWNER_SEEDED=1')
}

const verify = async () => {
  await rejected('m8-owned-session', 'bob', 'bob-secret', 5, { clean: false })
  await rejected('m8-owned-session', 'bob', 'bob-secret', 5, { clean: true })
  const session = await connect('m8-owned-session', 'alice', 'alice-secret', { clean: false })
  if (!session.connack.sessionPresent) throw new Error('owned Session did not survive restart')
  await waitUntil(
    () => session.messages.some(message => message.payload === 'owner-offline'),
    'owned offline QoS1 after restart'
  )
  await end(session.client)
  console.log('M8_OWNER_RESTART_VERIFIED=1')
}

if (mode === 'exercise') await exercise()
else if (mode === 'seed') await seed()
else if (mode === 'verify') await verify()
else throw new Error(`unknown mode: ${mode}`)
