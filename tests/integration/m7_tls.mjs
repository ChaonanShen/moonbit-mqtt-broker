import fs from 'node:fs'
import net from 'node:net'
import mqtt from 'mqtt'

const [mode, url, caPath] = process.argv.slice(2)
if (!mode || !url) throw new Error('usage: node m7_tls.mjs functional|restart-seed|restart-verify|concurrency|reject-ca|plaintext|stall URL [CA]')

const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const ca = caPath ? fs.readFileSync(caPath) : undefined
const mqttOptions = (clientId, overrides = {}) => ({
  clientId,
  clean: true,
  protocolVersion: 4,
  keepalive: 5,
  reconnectPeriod: 0,
  connectTimeout: 4000,
  ca,
  rejectUnauthorized: true,
  ...overrides
})

const connect = (clientId, overrides = {}) => new Promise((resolve, reject) => {
  const client = mqtt.connect(url, mqttOptions(clientId, overrides))
  const messages = []
  client.on('message', (topic, payload, packet) => {
    messages.push({ topic, payload: payload.toString(), packet })
  })
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

const end = client => new Promise(resolve => client.end(false, {}, resolve))
const publish = (client, topic, payload, options = {}) => new Promise((resolve, reject) => {
  client.publish(topic, payload, options, error => error ? reject(error) : resolve())
})
const subscribe = (client, topic, qos = 1) => new Promise((resolve, reject) => {
  client.subscribe(topic, { qos }, error => error ? reject(error) : resolve())
})

const waitForMessage = (client, predicate, timeoutMs = 8000) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => {
    client.off('message', onMessage)
    reject(new Error('message timeout'))
  }, timeoutMs)
  const onMessage = (topic, payload, packet) => {
    if (!predicate(topic, payload.toString(), packet)) return
    clearTimeout(timer)
    client.off('message', onMessage)
    resolve({ topic, payload: payload.toString(), packet })
  }
  client.on('message', onMessage)
})

const waitUntil = async (predicate, description, timeoutMs = 8000) => {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timeout: ${description}`)
    await delay(10)
  }
}

const functional = async () => {
  const subscriber = await connect('m7-tls-subscriber')
  await subscribe(subscriber.client, 'm7/tls/live', 1)
  const liveMessage = waitForMessage(subscriber.client, (_topic, payload) => payload === 'encrypted-qos1')
  const publisher = await connect('m7-tls-publisher')
  await publish(publisher.client, 'm7/tls/live', 'encrypted-qos1', { qos: 1 })
  await liveMessage
  await publish(publisher.client, 'm7/tls/retained', 'encrypted-retained', { qos: 1, retain: true })
  const retained = await connect('m7-tls-retained')
  const retainedMessage = waitForMessage(
    retained.client,
    (topic, payload, packet) => topic === 'm7/tls/retained' && payload === 'encrypted-retained' && packet.retain
  )
  await subscribe(retained.client, 'm7/tls/retained', 1)
  await retainedMessage
  await Promise.all([subscriber.client, publisher.client, retained.client].map(end))
  console.log('M7_TLS_FUNCTIONAL=1')
}

const concurrency = async () => {
  const clients = await Promise.all(Array.from({ length: 100 }, (_, index) => connect(`m7-tls-concurrent-${index}`)))
  await Promise.all(clients.map((entry, index) => publish(entry.client, `m7/tls/concurrent/${index}`, 'ok', { qos: 1 })))
  await Promise.all(clients.map(entry => end(entry.client)))
  console.log(`M7_TLS_CONCURRENT=${clients.length}`)
}

const restartSeed = async () => {
  const session = await connect('m7-tls-persistent', { clean: false })
  await subscribe(session.client, 'm7/tls/offline', 1)
  await end(session.client)
  const publisher = await connect('m7-tls-restart-publisher')
  await publish(publisher.client, 'm7/tls/offline', 'encrypted-offline', { qos: 1 })
  await publish(publisher.client, 'm7/tls/restart-retained', 'encrypted-restart-retained', { qos: 1, retain: true })
  await end(publisher.client)
  console.log('M7_TLS_RESTART_SEEDED=1')
}

const restartVerify = async () => {
  const session = await connect('m7-tls-persistent', { clean: false })
  if (!session.connack.sessionPresent) throw new Error('TLS persistent Session was not restored')
  await waitUntil(
    () => session.messages.some(message => message.payload === 'encrypted-offline'),
    'TLS offline QoS 1 replay'
  )
  const retained = await connect('m7-tls-restart-verifier')
  const replay = waitForMessage(
    retained.client,
    (topic, payload, packet) => topic === 'm7/tls/restart-retained' && payload === 'encrypted-restart-retained' && packet.retain
  )
  await subscribe(retained.client, 'm7/tls/restart-retained', 1)
  await replay
  await Promise.all([session.client, retained.client].map(end))
  console.log('M7_TLS_RESTART_VERIFIED=1')
}

const rejectCa = async () => {
  try {
    const value = await connect('m7-wrong-ca')
    await end(value.client)
    throw new Error('connection unexpectedly trusted the wrong CA')
  } catch (error) {
    if (String(error).includes('unexpectedly trusted')) throw error
  }
  console.log('M7_TLS_WRONG_CA_REJECTED=1')
}

const rawSocket = () => {
  const parsed = new URL(url)
  return net.createConnection({ host: parsed.hostname, port: Number(parsed.port) })
}

const plaintext = async () => {
  const socket = rawSocket()
  await new Promise((resolve, reject) => {
    socket.once('connect', resolve)
    socket.once('error', reject)
  })
  socket.write(Buffer.from([0x10, 0x0f, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x05, 0x00, 0x03, 0x72, 0x61, 0x77]))
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('plaintext client was not closed')), 3000)
    socket.once('close', () => {
      clearTimeout(timer)
      resolve()
    })
    socket.once('error', () => {})
  })
  console.log('M7_TLS_PLAINTEXT_REJECTED=1')
}

const stall = async () => {
  const socket = rawSocket()
  await new Promise((resolve, reject) => {
    socket.once('connect', resolve)
    socket.once('error', reject)
  })
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('stalled TLS handshake was not closed')), 3000)
    socket.once('close', () => {
      clearTimeout(timer)
      resolve()
    })
    socket.once('error', () => {})
  })
  await delay(20)
  console.log('M7_TLS_HANDSHAKE_TIMEOUT=1')
}

if (mode === 'functional') await functional()
else if (mode === 'restart-seed') await restartSeed()
else if (mode === 'restart-verify') await restartVerify()
else if (mode === 'concurrency') await concurrency()
else if (mode === 'reject-ca') await rejectCa()
else if (mode === 'plaintext') await plaintext()
else if (mode === 'stall') await stall()
else throw new Error(`unknown mode: ${mode}`)
