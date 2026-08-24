import net from 'node:net'
import mqtt from 'mqtt'
import { generate, parser as createParser } from 'mqtt-packet'

const [mode, url, expectedPacketIdArg] = process.argv.slice(2)
if (!mode || !url) {
  throw new Error('usage: node m4_restart.mjs seed|verify|verify-cleared mqtt://HOST:PORT [packet-id]')
}

const connectClient = (clientId, options = {}) => new Promise((resolve, reject) => {
  const inbox = []
  const waiters = []
  const client = mqtt.connect(url, {
    clientId,
    protocolVersion: 4,
    clean: true,
    keepalive: 3,
    reconnectPeriod: 0,
    connectTimeout: 5000,
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
  const nextMessage = (topic, timeoutMs = 8000) => {
    const index = inbox.findIndex(message => message.topic === topic)
    if (index >= 0) return Promise.resolve(inbox.splice(index, 1)[0])
    return new Promise((resolveMessage, rejectMessage) => {
      const waiter = { topic, resolve: resolveMessage }
      waiter.timer = setTimeout(() => {
        const waiterIndex = waiters.indexOf(waiter)
        if (waiterIndex >= 0) waiters.splice(waiterIndex, 1)
        rejectMessage(new Error(`message timed out: ${topic}`))
      }, timeoutMs)
      waiters.push(waiter)
    })
  }
  const timer = setTimeout(() => {
    client.end(true)
    reject(new Error(`connect timed out: ${clientId}`))
  }, 8000)
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

const rawConnect = async clientId => {
  const parsedUrl = new URL(url)
  const socket = net.createConnection({ host: parsedUrl.hostname, port: Number(parsedUrl.port) })
  await new Promise((resolve, reject) => {
    socket.once('connect', resolve)
    socket.once('error', reject)
  })
  const decoder = createParser()
  const inbox = []
  const waiters = []
  decoder.on('packet', packet => {
    const index = waiters.findIndex(waiter => waiter.predicate(packet))
    if (index >= 0) {
      const [waiter] = waiters.splice(index, 1)
      clearTimeout(waiter.timer)
      waiter.resolve(packet)
    } else {
      inbox.push(packet)
    }
  })
  decoder.on('error', error => {
    for (const waiter of waiters.splice(0)) waiter.reject(error)
  })
  socket.on('data', chunk => decoder.parse(chunk))
  const nextPacket = (predicate, label) => {
    const index = inbox.findIndex(predicate)
    if (index >= 0) return Promise.resolve(inbox.splice(index, 1)[0])
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve, reject }
      waiter.timer = setTimeout(() => {
        const waiterIndex = waiters.indexOf(waiter)
        if (waiterIndex >= 0) waiters.splice(waiterIndex, 1)
        reject(new Error(`raw packet timed out: ${label}`))
      }, 8000)
      waiters.push(waiter)
    })
  }
  const send = packet => socket.write(generate(packet))
  send({
    cmd: 'connect',
    protocolId: 'MQTT',
    protocolVersion: 4,
    clean: false,
    keepalive: 3,
    clientId
  })
  const connack = await nextPacket(packet => packet.cmd === 'connack', 'CONNACK')
  return { socket, send, nextPacket, connack }
}

const seed = async () => {
  const persistent = await connectClient('m4-persistent', { clean: false })
  if (persistent.connack.sessionPresent) throw new Error('new persistent session unexpectedly present')
  await subscribe(persistent.client, 'm4/offline', 1)
  await end(persistent.client)

  const clean = await connectClient('m4-clean', { clean: true })
  await subscribe(clean.client, 'm4/clean', 1)
  await end(clean.client)

  for (let index = 0; index < 20; index += 1) {
    const session = await connectClient(`m4-capacity-${index}`, { clean: false })
    await subscribe(session.client, `m4/capacity/${index}`, 1)
    await end(session.client)
  }

  const publisher = await connectClient('m4-seed-publisher')
  await publish(publisher.client, 'm4/retained', 'retained-v1', { retain: true })
  await publish(publisher.client, 'm4/offline', 'offline-qos1')
  await publish(publisher.client, 'm4/offline', 'qos0-not-stored', { qos: 0 })
  for (let index = 0; index < 20; index += 1) {
    await publish(publisher.client, `m4/capacity/${index}`, `capacity-${index}`)
  }

  const willObserver = await connectClient('m4-will-observer')
  await subscribe(willObserver.client, 'm4/will', 1)
  const willMessage = willObserver.nextMessage('m4/will')
  const doomed = await connectClient('m4-will-source', {
    will: { topic: 'm4/will', payload: 'will-retained', qos: 1, retain: true }
  })
  doomed.client.end(true)
  if ((await willMessage).payload !== 'will-retained') throw new Error('QoS1 Will was not routed')
  await end(willObserver.client)

  const raw = await rawConnect('m4-inflight')
  raw.send({
    cmd: 'subscribe',
    messageId: 1,
    subscriptions: [{ topic: 'm4/inflight', qos: 1 }]
  })
  await raw.nextPacket(packet => packet.cmd === 'suback' && packet.messageId === 1, 'SUBACK')
  await publish(publisher.client, 'm4/inflight', 'unacked-qos1')
  const unacked = await raw.nextPacket(packet => packet.cmd === 'publish', 'unacknowledged PUBLISH')
  if (unacked.dup || unacked.qos !== 1) throw new Error('initial inflight PUBLISH flags are invalid')
  raw.socket.destroy()
  await end(publisher.client)
  console.log(`M4_SEED_PACKET_ID=${unacked.messageId}`)
}

const verify = async expectedPacketId => {
  const retained = await connectClient('m4-retained-verifier')
  const retainedMessage = retained.nextMessage('m4/retained')
  await subscribe(retained.client, 'm4/retained', 1)
  const retainedValue = await retainedMessage
  if (retainedValue.payload !== 'retained-v1' || !retainedValue.packet.retain) {
    throw new Error('retained state did not survive restart')
  }
  const willMessage = retained.nextMessage('m4/will')
  await subscribe(retained.client, 'm4/will', 1)
  const willValue = await willMessage
  if (willValue.payload !== 'will-retained' || !willValue.packet.retain) {
    throw new Error('retained QoS1 Will did not survive restart')
  }

  const persistent = await connectClient('m4-persistent', { clean: false })
  if (!persistent.connack.sessionPresent) throw new Error('persistent session missing after restart')
  const offline = await persistent.nextMessage('m4/offline')
  if (offline.payload !== 'offline-qos1' || offline.packet.qos !== 1) {
    throw new Error('offline QoS1 did not survive restart')
  }

  const clean = await connectClient('m4-clean', { clean: false })
  if (clean.connack.sessionPresent) throw new Error('clean session was persisted')
  await end(clean.client)

  for (let index = 0; index < 20; index += 1) {
    const session = await connectClient(`m4-capacity-${index}`, { clean: false })
    if (!session.connack.sessionPresent) throw new Error(`capacity session ${index} missing`)
    const message = await session.nextMessage(`m4/capacity/${index}`)
    if (message.payload !== `capacity-${index}`) throw new Error(`capacity payload ${index} mismatch`)
    await end(session.client)
  }

  const raw = await rawConnect('m4-inflight')
  if (!raw.connack.sessionPresent) throw new Error('inflight session missing after restart')
  const replay = await raw.nextPacket(packet => packet.cmd === 'publish', 'DUP replay')
  if (!replay.dup || replay.messageId !== expectedPacketId || replay.payload.toString() !== 'unacked-qos1') {
    throw new Error(`inflight replay mismatch dup=${replay.dup} id=${replay.messageId}`)
  }
  raw.send({ cmd: 'puback', messageId: replay.messageId })
  const publisher = await connectClient('m4-verify-publisher')
  await publish(publisher.client, 'm4/inflight', 'next-packet-id')
  const next = await raw.nextPacket(packet => packet.cmd === 'publish', 'next PUBLISH')
  if (next.messageId === expectedPacketId) throw new Error('next packet id reused restored inflight id')
  raw.send({ cmd: 'puback', messageId: next.messageId })
  raw.socket.end(generate({ cmd: 'disconnect' }))

  // A clean reconnect must delete the old persistent state before the next restart.
  await end(persistent.client)
  const cleaner = await connectClient('m4-persistent', { clean: true })
  await end(cleaner.client)
  await Promise.all([retained.client, publisher.client].map(end))
  console.log('M4 restart recovery verified')
}

const verifyCleared = async () => {
  const client = await connectClient('m4-persistent', { clean: false })
  if (client.connack.sessionPresent) throw new Error('clean reconnect state resurrected after restart')
  await end(client.client)
  console.log('M4 clean-session deletion survived restart')
}

if (mode === 'seed') {
  await seed()
} else if (mode === 'verify') {
  const expectedPacketId = Number(expectedPacketIdArg)
  if (!Number.isInteger(expectedPacketId) || expectedPacketId < 1) throw new Error('invalid expected packet id')
  await verify(expectedPacketId)
} else if (mode === 'verify-cleared') {
  await verifyCleared()
} else {
  throw new Error(`unknown mode: ${mode}`)
}
