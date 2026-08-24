import net from 'node:net'
import mqtt from 'mqtt'
import { generate, parser as createParser } from 'mqtt-packet'

const [mode, url, arg] = process.argv.slice(2)
if (!mode || !url) throw new Error('usage: node stability.mjs quick|restart-seed|restart-verify|extended URL [round]')

const TIMEOUT = 30000
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const end = (client, force = false) => new Promise(resolve => client.end(force, {}, resolve))
const publish = (client, topic, payload, options = {}) => new Promise((resolve, reject) => {
  client.publish(topic, payload, options, error => error ? reject(error) : resolve())
})
const subscribe = (client, topic, qos = 1) => new Promise((resolve, reject) => {
  client.subscribe(topic, { qos }, (error, grants) => error ? reject(error) : resolve(grants))
})

const connect = (clientId, options = {}) => new Promise((resolve, reject) => {
  const messages = []
  const client = mqtt.connect(url, {
    clientId,
    clean: true,
    protocolVersion: 4,
    keepalive: 5,
    reconnectPeriod: 0,
    connectTimeout: 8000,
    queueQoSZero: false,
    ...options
  })
  client.on('message', (topic, payload, packet) => messages.push({ topic, payload: payload.toString(), packet }))
  const timer = setTimeout(() => {
    client.end(true)
    reject(new Error(`connect timeout: ${clientId}`))
  }, 10000)
  client.once('error', error => {
    clearTimeout(timer)
    reject(error)
  })
  client.once('connect', connack => {
    clearTimeout(timer)
    resolve({ client, connack, messages })
  })
})

const waitUntil = async (predicate, description, timeoutMs = TIMEOUT) => {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timeout: ${description}`)
    await delay(10)
  }
}

const rawPingCycle = async index => {
  const parsed = new URL(url)
  const socket = net.createConnection({ host: parsed.hostname, port: Number(parsed.port) })
  const packets = []
  const decoder = createParser()
  decoder.on('packet', packet => packets.push(packet))
  socket.on('data', chunk => decoder.parse(chunk))
  await new Promise((resolve, reject) => {
    socket.once('connect', resolve)
    socket.once('error', reject)
  })
  socket.write(generate({
    cmd: 'connect', protocolId: 'MQTT', protocolVersion: 4, clean: true,
    keepalive: 5, clientId: `release-concurrent-${index}`
  }))
  await waitUntil(() => packets.some(packet => packet.cmd === 'connack'), `CONNACK ${index}`, 10000)
  socket.write(generate({ cmd: 'pingreq' }))
  await waitUntil(() => packets.some(packet => packet.cmd === 'pingresp'), `PINGRESP ${index}`, 10000)
  socket.end(generate({ cmd: 'disconnect' }))
  await new Promise(resolve => {
    socket.once('close', resolve)
    setTimeout(() => { socket.destroy(); resolve() }, 3000).unref()
  })
}

const concurrentClients = async count => {
  await Promise.all(Array.from({ length: count }, (_, index) => rawPingCycle(index)))
  console.log(`RELEASE_CONCURRENT_CLIENTS=${count}`)
}

const qos0Sequence = async count => {
  const subscriber = await connect('release-stability-qos0-sub')
  const received = []
  subscriber.client.on('message', (_topic, payload) => {
    const sequence = Number(payload.subarray(0, 8).toString())
    received.push(sequence)
  })
  await subscribe(subscriber.client, 'release/stability/qos0', 0)
  const publisher = await connect('release-stability-qos0-pub')
  const padding = 'x'.repeat(1016)
  for (let base = 0; base < count; base += 32) {
    const batch = []
    for (let index = base; index < Math.min(base + 32, count); index += 1) {
      batch.push(publish(publisher.client, 'release/stability/qos0', `${String(index).padStart(8, '0')}${padding}`, { qos: 0 }))
    }
    await Promise.all(batch)
    await waitUntil(
      () => received.length >= Math.min(base + 32, count),
      `QoS0 batch ending at ${Math.min(base + 32, count)}`,
      10000
    )
  }
  await waitUntil(() => received.length === count, `${count} QoS0 deliveries`, 60000)
  for (let index = 0; index < count; index += 1) {
    if (received[index] !== index) throw new Error(`QoS0 sequence mismatch at ${index}: ${received[index]}`)
  }
  await Promise.all([subscriber.client, publisher.client].map(client => end(client)))
  console.log(`RELEASE_QOS0_MESSAGES=${count}`)
}

const offlineQos1 = async (sessionCount, perSession) => {
  for (let index = 0; index < sessionCount; index += 1) {
    const session = await connect(`release-offline-${index}`, { clean: false })
    await subscribe(session.client, `release/stability/offline/${index}`, 1)
    await end(session.client)
  }
  const publisher = await connect('release-offline-publisher')
  for (let sequence = 0; sequence < perSession; sequence += 1) {
    await Promise.all(Array.from({ length: sessionCount }, (_, index) =>
      publish(publisher.client, `release/stability/offline/${index}`, String(sequence), { qos: 1 })
    ))
  }
  await end(publisher.client)

  await Promise.all(Array.from({ length: sessionCount }, async (_, index) => {
    const session = await connect(`release-offline-${index}`, { clean: false })
    if (!session.connack.sessionPresent) throw new Error(`offline session ${index} is absent`)
    await waitUntil(() => session.messages.length === perSession, `offline session ${index}`, 60000)
    for (let sequence = 0; sequence < perSession; sequence += 1) {
      const received = Number(session.messages[sequence].payload)
      if (received !== sequence) throw new Error(`offline FIFO ${index}/${sequence}: ${received}`)
    }
    await end(session.client)
  }))
  console.log(`RELEASE_OFFLINE_QOS1=${sessionCount}x${perSession}`)
}

const slowConsumerIsolation = async () => {
  const parsed = new URL(url)
  const slow = net.createConnection({ host: parsed.hostname, port: Number(parsed.port) })
  const decoder = createParser()
  const packets = []
  decoder.on('packet', packet => packets.push(packet))
  slow.on('data', chunk => decoder.parse(chunk))
  await new Promise((resolve, reject) => {
    slow.once('connect', resolve)
    slow.once('error', reject)
  })
  slow.write(generate({ cmd: 'connect', protocolId: 'MQTT', protocolVersion: 4, clean: true, keepalive: 5, clientId: 'release-slow' }))
  await waitUntil(() => packets.some(packet => packet.cmd === 'connack'), 'slow CONNACK')
  slow.write(generate({ cmd: 'subscribe', messageId: 1, subscriptions: [{ topic: 'release/stability/slow', qos: 0 }] }))
  await waitUntil(() => packets.some(packet => packet.cmd === 'suback'), 'slow SUBACK')
  slow.pause()

  const healthy = await Promise.all(Array.from({ length: 20 }, (_, index) => connect(`release-healthy-${index}`)))
  const observer = healthy[0]
  let healthyMessages = 0
  observer.client.on('message', (_topic, payload) => {
    if (payload.toString().startsWith('healthy-')) healthyMessages += 1
  })
  await subscribe(observer.client, 'release/stability/healthy', 0)
  const publisher = healthy[1].client
  const payload = Buffer.alloc(1024, 0x73)
  for (let index = 0; index < 2500; index += 1) {
    publisher.publish('release/stability/slow', payload, { qos: 0 })
    if (index % 100 === 0) await publish(publisher, 'release/stability/healthy', `healthy-${index}`, { qos: 0 })
  }
  await waitUntil(() => healthyMessages === 25, 'healthy clients during slow consumer', 30000)
  await Promise.all(healthy.map(value => end(value.client)))
  slow.destroy()
  console.log('RELEASE_SLOW_CONSUMER_ISOLATED=1')
}

const quick = async () => {
  await concurrentClients(100)
  await qos0Sequence(10000)
  await offlineQos1(10, 100)
  await slowConsumerIsolation()
}

const restartSeed = async round => {
  const persistent = await connect('release-restart-session', { clean: false })
  if (round > 0 && !persistent.connack.sessionPresent) throw new Error(`restart session absent at round ${round}`)
  await subscribe(persistent.client, 'release/restart/offline', 1)
  await end(persistent.client)
  const publisher = await connect(`release-restart-publisher-${round}`)
  await publish(publisher.client, 'release/restart/retained', `round-${round}`, { qos: 1, retain: true })
  await publish(publisher.client, 'release/restart/offline', `offline-${round}`, { qos: 1 })
  await end(publisher.client)
  console.log(`RELEASE_RESTART_SEEDED=${round}`)
}

const restartVerify = async round => {
  const retained = await connect(`release-restart-verifier-${round}`)
  await subscribe(retained.client, 'release/restart/retained', 1)
  await waitUntil(() => retained.messages.length > 0, 'restart retained')
  const retainedValue = { payload: retained.messages[0].payload, retain: retained.messages[0].packet.retain }
  if (retainedValue.payload !== `round-${round}` || !retainedValue.retain) throw new Error(`retained mismatch round ${round}`)
  const persistent = await connect('release-restart-session', { clean: false })
  if (!persistent.connack.sessionPresent) throw new Error(`persistent restart session absent at ${round}`)
  await waitUntil(
    () => persistent.messages.some(message => message.payload === `offline-${round}`),
    `restart offline ${round}`
  )
  await Promise.all([retained.client, persistent.client].map(client => end(client)))
  console.log(`RELEASE_RESTART_VERIFIED=${round}`)
}

const extended = async () => {
  const count = Number(process.env.RELEASE_SOAK_PUBLICATIONS ?? '100000')
  const durationMs = Number(process.env.RELEASE_SOAK_SECONDS ?? '600') * 1000
  const started = Date.now()
  await concurrentClients(100)
  await qos0Sequence(count)
  const clients = await Promise.all(Array.from({ length: 100 }, (_, index) => connect(`release-soak-${index}`)))
  while (Date.now() - started < durationMs) {
    await Promise.all(clients.slice(0, 20).map((value, index) => publish(value.client, `release/soak/${index}`, 'pulse', { qos: index % 2 })))
    await delay(1000)
  }
  await Promise.all(clients.map(value => end(value.client)))
  console.log(`RELEASE_EXTENDED_PUBLICATIONS=${count}`)
  console.log(`RELEASE_EXTENDED_SECONDS=${Math.floor((Date.now() - started) / 1000)}`)
}

if (mode === 'quick') await quick()
else if (mode === 'restart-seed') await restartSeed(Number(arg))
else if (mode === 'restart-verify') await restartVerify(Number(arg))
else if (mode === 'extended') await extended()
else throw new Error(`unknown mode: ${mode}`)
