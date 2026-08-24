import mqtt from 'mqtt'

const [mode, url, caseName] = process.argv.slice(2)
if (!['seed', 'verify'].includes(mode) || !url || !caseName) {
  throw new Error('usage: node m6_shutdown.mjs seed|verify mqtt://HOST:PORT CASE')
}

const retainedTopic = `m6/${caseName}/retained`
const offlineTopic = `m6/${caseName}/offline`
const willTopic = `m6/${caseName}/shutdown-will`
const persistentClientId = `m6-${caseName}-persistent`

const delay = ms => new Promise(resolve => setTimeout(resolve, ms))

const connect = (clientId, options = {}) => new Promise((resolve, reject) => {
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
    const waiterIndex = waiters.findIndex(waiter => waiter.topic === topic)
    if (waiterIndex >= 0) {
      const [waiter] = waiters.splice(waiterIndex, 1)
      clearTimeout(waiter.timer)
      waiter.resolve(message)
    } else {
      inbox.push(message)
    }
  })
  const nextMessage = (topic, timeoutMs = 5000) => {
    const inboxIndex = inbox.findIndex(message => message.topic === topic)
    if (inboxIndex >= 0) return Promise.resolve(inbox.splice(inboxIndex, 1)[0])
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
  }, 6000)
  client.once('error', error => {
    clearTimeout(timer)
    reject(error)
  })
  client.once('connect', connack => {
    clearTimeout(timer)
    resolve({ client, connack, inbox, nextMessage })
  })
})

const subscribe = (client, topic, qos = 1) => new Promise((resolve, reject) => {
  client.subscribe(topic, { qos }, (error, grants) => error ? reject(error) : resolve(grants))
})

const publish = (client, topic, payload, options = {}) => new Promise((resolve, reject) => {
  client.publish(topic, payload, { qos: 1, ...options }, error => error ? reject(error) : resolve())
})

const end = client => new Promise(resolve => client.end(false, {}, resolve))

const seed = async () => {
  const persistent = await connect(persistentClientId, { clean: false })
  if (persistent.connack.sessionPresent) throw new Error('new persistent session unexpectedly present')
  await subscribe(persistent.client, offlineTopic)
  await end(persistent.client)

  const publisher = await connect(`m6-${caseName}-publisher`)
  await publish(publisher.client, retainedTopic, `retained-${caseName}`, { retain: true })
  await publish(publisher.client, offlineTopic, `offline-${caseName}`)
  await end(publisher.client)

  const willClient = await connect(`m6-${caseName}-will-source`, {
    will: {
      topic: willTopic,
      payload: `must-not-fire-${caseName}`,
      qos: 1,
      retain: true
    }
  })
  console.log(`M6_SEED_READY=${caseName}`)
  await new Promise(resolve => willClient.client.once('close', resolve))
}

const verify = async () => {
  const verifier = await connect(`m6-${caseName}-verifier`)
  const retainedPromise = verifier.nextMessage(retainedTopic)
  await subscribe(verifier.client, retainedTopic)
  const retained = await retainedPromise
  if (retained.payload !== `retained-${caseName}` || !retained.packet.retain) {
    throw new Error(`retained shutdown recovery mismatch for ${caseName}`)
  }

  await subscribe(verifier.client, willTopic)
  await delay(500)
  if (verifier.inbox.some(message => message.topic === willTopic)) {
    throw new Error(`server shutdown published retained Will for ${caseName}`)
  }

  const persistent = await connect(persistentClientId, { clean: false })
  if (!persistent.connack.sessionPresent) {
    throw new Error(`persistent session missing after ${caseName}`)
  }
  const offline = await persistent.nextMessage(offlineTopic)
  if (offline.payload !== `offline-${caseName}` || offline.packet.qos !== 1) {
    throw new Error(`offline QoS1 shutdown recovery mismatch for ${caseName}`)
  }
  await Promise.all([end(verifier.client), end(persistent.client)])
  console.log(`M6_SHUTDOWN_VERIFIED=${caseName}`)
}

if (mode === 'seed') {
  await seed()
} else {
  await verify()
}
