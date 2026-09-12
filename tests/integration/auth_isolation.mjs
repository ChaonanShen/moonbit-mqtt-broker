import fs from 'node:fs'
import mqtt from 'mqtt'

const [url, caPath, username, password] = process.argv.slice(2)
if (!url || !caPath || !username || !password) {
  throw new Error('usage: node auth_isolation.mjs URL CA USERNAME PASSWORD')
}
const ca = fs.readFileSync(caPath)
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const options = (clientId, secret) => ({
  clientId,
  username,
  password: secret,
  clean: true,
  protocolVersion: 4,
  keepalive: 1,
  reconnectPeriod: 0,
  connectTimeout: 30000,
  ca,
  rejectUnauthorized: true
})

const connect = (clientId, secret) => new Promise((resolve, reject) => {
  const client = mqtt.connect(url, options(clientId, secret))
  const fail = error => {
    client.end(true)
    reject(error)
  }
  client.once('error', fail)
  client.once('connect', () => {
    client.off('error', fail)
    resolve(client)
  })
})

const rejected = (clientId, secret) => new Promise(resolve => {
  const started = performance.now()
  const client = mqtt.connect(url, options(clientId, secret))
  let done = false
  const finish = (accepted, error) => {
    if (done) return
    done = true
    const durationMs = performance.now() - started
    const code = error?.code ?? error?.reasonCode ?? error?.returnCode
    client.end(true)
    resolve({ accepted, code, durationMs, message: String(error ?? '') })
  }
  client.once('connect', () => finish(true))
  client.once('error', error => finish(false, error))
  client.once('close', () => {
    if (!done) finish(false, new Error('closed without CONNACK error'))
  })
})

const publish = (client, sequence) => new Promise((resolve, reject) => {
  const started = performance.now()
  client.publish(
    'allowed/isolation',
    `progress-${sequence}`,
    { qos: 1 },
    error => error ? reject(error) : resolve(performance.now() - started)
  )
})

const stable = await connect('auth-isolation-stable', password)
let verificationFinished = false
const slowFailure = rejected('auth-isolation-slow-failure', 'wrong-password')
  .then(result => {
    verificationFinished = true
    return result
  })
await delay(10)
const ackLatencies = []
for (let sequence = 0; sequence < 100 && !verificationFinished; sequence++) {
  ackLatencies.push(await publish(stable, sequence))
}
const slowResult = await slowFailure
if (slowResult.accepted || slowResult.code !== 4) {
  throw new Error(`expected bad-credentials CONNACK 4: ${JSON.stringify(slowResult)}`)
}
if (ackLatencies.length < 3) {
  throw new Error(
    `routing did not make independent progress during ${slowResult.durationMs.toFixed(1)}ms hash; acks=${ackLatencies.length}`
  )
}

const saturated = await Promise.all(
  Array.from({ length: 6 }, (_, index) =>
    rejected(`auth-isolation-saturation-${index}`, 'wrong-password')
  )
)
if (saturated.some(result => result.accepted)) {
  throw new Error(`wrong password accepted during saturation: ${JSON.stringify(saturated)}`)
}
const unavailable = saturated.filter(result => result.code === 3).length
const badCredentials = saturated.filter(result => result.code === 4).length
if (unavailable < 1 || badCredentials < 1) {
  throw new Error(
    `expected bounded queue rejection and completed hashes: ${JSON.stringify(saturated)}`
  )
}
const recoveryLatency = await publish(stable, 1000)
await new Promise(resolve => stable.end(false, {}, resolve))

ackLatencies.sort((left, right) => left - right)
const p99 = ackLatencies[Math.min(ackLatencies.length - 1, Math.floor(ackLatencies.length * 0.99))]
console.log(JSON.stringify({
  authVerifyWindowMs: Number(slowResult.durationMs.toFixed(3)),
  pubacksDuringHash: ackLatencies.length,
  pubackP99Ms: Number(p99.toFixed(3)),
  saturationUnavailable: unavailable,
  saturationBadCredentials: badCredentials,
  recoveryPubackMs: Number(recoveryLatency.toFixed(3))
}))
