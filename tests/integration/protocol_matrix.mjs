import net from 'node:net'
import mqtt from 'mqtt'
import { generate, parser as createParser } from 'mqtt-packet'

const [url, profile = 'full', label = 'broker'] = process.argv.slice(2)
if (!url || !['common', 'full'].includes(profile)) {
  throw new Error('usage: node protocol_matrix.mjs mqtt://HOST:PORT common|full [label]')
}

const result = {}
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const end = (client, force = false) => new Promise(resolve => client.end(force, {}, resolve))
const subscribe = (client, subscriptions) => new Promise((resolve, reject) => {
  if (typeof subscriptions === 'string') {
    client.subscribe(subscriptions, { qos: 1 }, (error, grants) => error ? reject(error) : resolve(grants))
    return
  }
  const subscriptionMap = Object.fromEntries(
    subscriptions.map(subscription => [subscription.topic, { qos: subscription.qos }])
  )
  client.subscribe(subscriptionMap, (error, grants) => error ? reject(error) : resolve(grants))
})
const unsubscribe = (client, topic) => new Promise((resolve, reject) => {
  client.unsubscribe(topic, error => error ? reject(error) : resolve())
})
const publish = (client, topic, payload, options = {}) => new Promise((resolve, reject) => {
  client.publish(topic, payload, options, error => error ? reject(error) : resolve())
})

const connect = (clientId, options = {}) => new Promise((resolve, reject) => {
  const inbox = []
  const waiters = []
  const client = mqtt.connect(url, {
    clientId,
    clean: true,
    protocolVersion: 4,
    keepalive: 3,
    reconnectPeriod: 0,
    connectTimeout: 5000,
    ...options
  })
  client.on('message', (topic, payload, packet) => {
    const value = { topic, payload: payload.toString(), qos: packet.qos, retain: packet.retain, dup: packet.dup }
    const index = waiters.findIndex(waiter => waiter.predicate(value))
    if (index >= 0) {
      const [waiter] = waiters.splice(index, 1)
      clearTimeout(waiter.timer)
      waiter.resolve(value)
    } else {
      inbox.push(value)
    }
  })
  const next = (predicate, description, timeoutMs = 6000) => {
    const index = inbox.findIndex(predicate)
    if (index >= 0) return Promise.resolve(inbox.splice(index, 1)[0])
    return new Promise((resolveMessage, rejectMessage) => {
      const waiter = { predicate, resolve: resolveMessage }
      waiter.timer = setTimeout(() => {
        const waiterIndex = waiters.indexOf(waiter)
        if (waiterIndex >= 0) waiters.splice(waiterIndex, 1)
        rejectMessage(new Error(`${label} message timeout: ${description}`))
      }, timeoutMs)
      waiters.push(waiter)
    })
  }
  const timer = setTimeout(() => {
    client.end(true)
    reject(new Error(`${label} connect timeout: ${clientId}`))
  }, 6000)
  client.once('error', error => {
    clearTimeout(timer)
    reject(error)
  })
  client.once('connect', connack => {
    clearTimeout(timer)
    resolve({ client, connack, next, inbox })
  })
})

class RawClient {
  constructor (socket) {
    this.socket = socket
    this.inbox = []
    this.waiters = []
    this.closed = false
    const decoder = createParser()
    decoder.on('packet', packet => this.#accept(packet))
    decoder.on('error', () => {})
    socket.on('data', chunk => decoder.parse(chunk))
    socket.on('close', () => {
      this.closed = true
      this.#accept({ cmd: 'closed' })
    })
  }

  #accept (packet) {
    const index = this.waiters.findIndex(waiter => waiter.predicate(packet))
    if (index >= 0) {
      const [waiter] = this.waiters.splice(index, 1)
      clearTimeout(waiter.timer)
      waiter.resolve(packet)
    } else {
      this.inbox.push(packet)
    }
  }

  send (packet) { this.socket.write(generate(packet)) }
  bytes (bytes) { this.socket.write(Buffer.from(bytes)) }
  next (predicate, description, timeoutMs = 5000) {
    const index = this.inbox.findIndex(predicate)
    if (index >= 0) return Promise.resolve(this.inbox.splice(index, 1)[0])
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve }
      waiter.timer = setTimeout(() => {
        const waiterIndex = this.waiters.indexOf(waiter)
        if (waiterIndex >= 0) this.waiters.splice(waiterIndex, 1)
        reject(new Error(`${label} raw timeout: ${description}`))
      }, timeoutMs)
      this.waiters.push(waiter)
    })
  }
  close () { this.socket.destroy() }
}

const raw = async () => {
  const parsed = new URL(url)
  const socket = net.createConnection({ host: parsed.hostname, port: Number(parsed.port) })
  await new Promise((resolve, reject) => {
    socket.once('connect', resolve)
    socket.once('error', reject)
  })
  return new RawClient(socket)
}

const rawConnect = async (clientId, clean = true, keepalive = 3) => {
  const client = await raw()
  client.send({ cmd: 'connect', protocolId: 'MQTT', protocolVersion: 4, clean, keepalive, clientId })
  const connack = await client.next(packet => packet.cmd === 'connack', 'CONNACK')
  return { client, connack }
}

const commonMatrix = async () => {
  const subscriber = await connect(`release-${label}-common-sub`)
  result.cleanSessionPresent = subscriber.connack.sessionPresent
  const grants = await subscribe(subscriber.client, [
    { topic: 'release/common/+/value', qos: 0 },
    { topic: 'release/common/#', qos: 1 },
    { topic: 'release/empty/+/tail', qos: 1 }
  ])
  result.suback = grants.map(grant => grant.qos)

  const publisher = await connect(`release-${label}-common-pub`)
  const overlap = subscriber.next(message => message.topic === 'release/common/a/value', 'overlap')
  await publish(publisher.client, 'release/common/a/value', 'overlap', { qos: 1 })
  const overlapMessage = await overlap
  if (profile === 'full' && overlapMessage.qos !== 1) throw new Error('overlapping filters did not use maximum QoS')
  result.overlap = profile === 'full'
    ? { count: 1, qos: overlapMessage.qos, payload: overlapMessage.payload }
    : { count: 1, payload: overlapMessage.payload }

  const empty = subscriber.next(message => message.topic === 'release/empty//tail', 'empty level')
  await publish(publisher.client, 'release/empty//tail', 'empty-level', { qos: 1 })
  result.emptyLevel = (await empty).payload

  await publish(publisher.client, 'release/common/retained', 'retained-value', { qos: 1, retain: true })
  const retainedClient = await connect(`release-${label}-retained`)
  const retained = retainedClient.next(message => message.topic === 'release/common/retained', 'retained replay')
  await subscribe(retainedClient.client, 'release/common/retained')
  const retainedMessage = await retained
  result.retained = { payload: retainedMessage.payload, retain: retainedMessage.retain }
  await publish(publisher.client, 'release/common/retained', '', { qos: 1, retain: true })
  await end(retainedClient.client)

  await unsubscribe(subscriber.client, 'release/common/#')
  result.unsubscribe = true
  await Promise.all([subscriber.client, publisher.client].map(client => end(client)))
}

const expectClosed = async (client, description, timeoutMs = 4000) => {
  await client.next(packet => packet.cmd === 'closed', description, timeoutMs)
}

const fullMatrix = async () => {
  const persistent = await connect('release-full-persistent', { clean: false })
  if (persistent.connack.sessionPresent) throw new Error('new persistent session is present')
  await subscribe(persistent.client, 'release/full/offline')
  await end(persistent.client)
  const publisher = await connect('release-full-publisher')
  for (let index = 0; index < 3; index += 1) {
    await publish(publisher.client, 'release/full/offline', `offline-${index}`, { qos: 1 })
  }
  const resumed = await connect('release-full-persistent', { clean: false })
  if (!resumed.connack.sessionPresent) throw new Error('persistent session is absent')
  const offline = []
  for (let index = 0; index < 3; index += 1) {
    offline.push((await resumed.next(message => message.topic === 'release/full/offline', `offline ${index}`)).payload)
  }
  if (offline.join(',') !== 'offline-0,offline-1,offline-2') throw new Error(`offline FIFO mismatch: ${offline}`)
  result.persistentOfflineFifo = offline

  const observer = await connect('release-full-will-observer')
  await subscribe(observer.client, 'release/full/will')
  const forcedWill = observer.next(message => message.topic === 'release/full/will', 'forced Will')
  const doomed = await connect('release-full-will-forced', {
    will: { topic: 'release/full/will', payload: 'forced', qos: 1, retain: false }
  })
  doomed.client.end(true)
  result.forcedWill = (await forcedWill).payload
  const graceful = await connect('release-full-will-graceful', {
    will: { topic: 'release/full/will', payload: 'must-not-fire', qos: 1, retain: false }
  })
  await end(graceful.client)
  await delay(250)
  if (observer.inbox.some(message => message.payload === 'must-not-fire')) throw new Error('DISCONNECT emitted Will')
  result.disconnectSuppressesWill = true

  const duplicate = await rawConnect('release-full-duplicate-connect')
  duplicate.client.send({ cmd: 'connect', protocolId: 'MQTT', protocolVersion: 4, clean: true, keepalive: 3, clientId: 'again' })
  await expectClosed(duplicate.client, 'duplicate CONNECT close')
  result.duplicateConnectCloses = true

  const badFlags = await rawConnect('release-full-bad-flags')
  badFlags.client.bytes([0xc1, 0x00])
  await expectClosed(badFlags.client, 'bad flags close')
  result.badFlagsClose = true

  const qos2 = await rawConnect('release-full-qos2')
  qos2.client.send({ cmd: 'publish', topic: 'release/full/qos2', payload: Buffer.from('x'), qos: 2, messageId: 7 })
  await expectClosed(qos2.client, 'QoS2 close')
  result.qos2Closes = true

  const ping = await rawConnect('release-full-ping', true, 0)
  ping.client.send({ cmd: 'pingreq' })
  await ping.client.next(packet => packet.cmd === 'pingresp', 'PINGRESP')
  ping.client.send({ cmd: 'disconnect' })
  result.ping = true

  const idle = await rawConnect('release-full-keepalive', true, 1)
  await expectClosed(idle.client, 'keep alive close', 3500)
  result.keepAliveTimeout = true

  await Promise.all([publisher.client, resumed.client, observer.client].map(client => end(client)))
}

await commonMatrix()
if (profile === 'full') await fullMatrix()
console.log(`RELEASE_MATRIX_RESULT=${JSON.stringify(result)}`)
