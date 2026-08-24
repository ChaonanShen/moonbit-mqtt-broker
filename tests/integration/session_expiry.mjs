import mqtt from 'mqtt'

const [mode, url] = process.argv.slice(2)
if (!mode || !url) throw new Error('usage: node session_expiry.mjs MODE URL')

const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const connect = (clientId, clean = false) => new Promise((resolve, reject) => {
  const client = mqtt.connect(url, {
    clientId,
    clean,
    protocolVersion: 4,
    keepalive: 2,
    reconnectPeriod: 0,
    connectTimeout: 3000
  })
  const onError = error => {
    client.end(true)
    reject(error)
  }
  client.once('error', onError)
  client.once('connect', connack => {
    client.off('error', onError)
    resolve({ client, connack })
  })
})
const end = client => new Promise(resolve => client.end(false, {}, resolve))
const publish = (client, topic, payload) => new Promise((resolve, reject) => {
  client.publish(topic, payload, { qos: 1 }, error => error ? reject(error) : resolve())
})

const never = async () => {
  const first = await connect('session_expiry-never')
  await end(first.client)
  await delay(450)
  const resumed = await connect('session_expiry-never')
  if (!resumed.connack.sessionPresent) throw new Error('default never-expire Session was removed')
  await end(resumed.client)
  console.log('SESSION_EXPIRY_NEVER_EXPIRES=1')
}

const timing = async () => {
  const active = await connect('session_expiry-active')
  await delay(450)
  await publish(active.client, 'session_expiry/active', 'still-alive')
  await end(active.client)

  const first = await connect('session_expiry-reset')
  await end(first.client)
  await delay(170)
  const resetOnce = await connect('session_expiry-reset')
  if (!resetOnce.connack.sessionPresent) throw new Error('Session expired before its deadline')
  await end(resetOnce.client)
  await delay(170)
  const resetTwice = await connect('session_expiry-reset')
  if (!resetTwice.connack.sessionPresent) throw new Error('reconnect did not reset expiry')
  await end(resetTwice.client)
  await delay(420)
  const expired = await connect('session_expiry-reset')
  if (expired.connack.sessionPresent) throw new Error('detached Session did not expire')
  await end(expired.client)
  console.log('SESSION_EXPIRY_TIMING_VERIFIED=1')
}

const seed = async () => {
  const session = await connect('session_expiry-persisted-expiry')
  await new Promise((resolve, reject) => {
    session.client.subscribe('session_expiry/offline', { qos: 1 }, error => error ? reject(error) : resolve())
  })
  await end(session.client)
  console.log('SESSION_EXPIRY_SEEDED=1')
}

const verifyAbsent = async () => {
  const session = await connect('session_expiry-persisted-expiry')
  if (session.connack.sessionPresent) throw new Error('expired Session revived after restart')
  await end(session.client)
  console.log('SESSION_EXPIRY_RESTART_VERIFIED=1')
}

if (mode === 'never') await never()
else if (mode === 'timing') await timing()
else if (mode === 'seed') await seed()
else if (mode === 'verify-absent') await verifyAbsent()
else throw new Error(`unknown mode: ${mode}`)
