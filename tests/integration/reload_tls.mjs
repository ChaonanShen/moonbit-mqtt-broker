import fs from 'node:fs'
import crypto from 'node:crypto'
import tls from 'node:tls'
import { execFileSync, spawnSync } from 'node:child_process'
import mqtt from 'mqtt'

const [tlsPort, wssPort, configPath, manifestPath, certPath, keyPath, root, logPath, pid, brokerPath] =
  process.argv.slice(2)
if (!pid || !logPath || !brokerPath) throw new Error('usage: node reload_tls.mjs TLS_PORT WSS_PORT CONFIG MANIFEST CERT KEY ROOT LOG PID BROKER')
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
const connect = (url, ca, clientId) => new Promise((resolve, reject) => {
  const client = mqtt.connect(url, {
    clientId, clean: true, protocolVersion: 4,
    ca, rejectUnauthorized: true, reconnectPeriod: 0, connectTimeout: 3000
  })
  client.once('error', reject)
  client.once('connect', () => {
    client.off('error', reject)
    resolve(client)
  })
})
const end = client => new Promise(resolve => client.end(false, {}, resolve))
const publish = (client, topic) => new Promise((resolve, reject) => {
  client.publish(topic, 'still-connected', { qos: 1 }, error =>
    error ? reject(error) : resolve())
})
const fingerprint = ca => new Promise((resolve, reject) => {
  const socket = tls.connect({
    host: '127.0.0.1', port: Number(tlsPort),
    servername: 'localhost', ca, rejectUnauthorized: true
  })
  socket.once('error', reject)
  socket.once('secureConnect', () => {
    const value = socket.getPeerCertificate().fingerprint256
    socket.end()
    resolve(value)
  })
})
const digest = path =>
  crypto.createHash('sha256').update(fs.readFileSync(path)).digest('hex')
const manifest = () => {
  let text = 'version = 1\n'
  const entries = [
    ['config', null, configPath],
    ['mqtt_cert', 'edge', certPath], ['mqtt_key', 'edge', keyPath],
    ['mqtt_cert', 'browser', certPath], ['mqtt_key', 'browser', keyPath]
  ]
  if (fs.readFileSync(configPath, 'utf8').includes('password_file =')) {
    entries.push(['passwords', null, passwordPath])
  }
  for (const [role, id, path] of entries) {
    text += '[[materials]]\nrole = "' + role + '"\n'
    if (id) text += 'listener_id = "' + id + '"\n'
    text += 'path = "' + path + '"\nsha256 = "' + digest(path) + '"\n'
  }
  fs.writeFileSync(manifestPath, text, { mode: 0o600 })
}
const passwordPath = certPath + '.passwords'
const originalConfig = fs.readFileSync(configPath, 'utf8')
const originalCA = fs.readFileSync(certPath)
const originalFinger = await fingerprint(originalCA)
const old = await connect('mqtts://localhost:' + tlsPort, originalCA, 'reload-old-tls')
const firstWss = await connect(
  'wss://localhost:' + wssPort + '/mqtt', originalCA, 'reload-first-wss'
)
await end(firstWss)
const nextCert = certPath + '.next'
const nextKey = keyPath + '.next'
execFileSync('openssl', [
  'req', '-x509', '-newkey', 'rsa:2048', '-sha256', '-nodes', '-days', '1',
  '-subj', '/CN=localhost',
  '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
  '-keyout', nextKey, '-out', nextCert
], { stdio: 'ignore' })
fs.chmodSync(nextKey, 0o600)
const hash = execFileSync('argon2', [
  'reload-salt-0001', '-id', '-e', '-t', '2', '-m', '12', '-p', '1'
], { input: 'secret' }).toString().trim()
fs.writeFileSync(passwordPath, 'alice:' + hash + '\n', { mode: 0o600 })
fs.writeFileSync(configPath, originalConfig +
  '[security]\nallow_anonymous = false\npassword_file = "' +
  passwordPath + '"\n[observability]\nlog_level = "debug"\n')
fs.writeFileSync(keyPath, fs.readFileSync(nextKey), { mode: 0o600 })
manifest()
const invalid = spawnSync(brokerPath, ['--check-config', '--config', configPath], {
  encoding: 'utf8'
})
if (invalid.status === 0 ||
    !invalid.stdout.includes('reload TLS material validation failed')) {
  throw new Error('bad TLS fixture failed for the wrong reason: ' +
    invalid.status + ' ' + invalid.stdout.slice(-200))
}
process.kill(Number(pid), 'SIGHUP')
for (let attempt = 0; attempt < 800; attempt++) {
  if (fs.readFileSync(logPath, 'utf8').includes('event=reload_failed')) break
  if (attempt === 799) throw new Error('bad TLS candidate did not fail')
  await sleep(10)
}
if (await fingerprint(originalCA) !== originalFinger) {
  throw new Error('failed candidate replaced TLS certificate')
}
const unchanged = await connect(
  'mqtts://localhost:' + tlsPort, originalCA, 'reload-failed-unchanged-anon'
)
await end(unchanged)
fs.rmSync(passwordPath)
fs.writeFileSync(configPath, originalConfig)
fs.renameSync(nextKey, keyPath)
fs.renameSync(nextCert, certPath)
manifest()
const nextCA = fs.readFileSync(certPath)
process.kill(Number(pid), 'SIGHUP')
let rotated = false
for (let attempt = 0; attempt < 500; attempt++) {
  try {
    const current = await fingerprint(nextCA)
    if (current !== originalFinger) {
      rotated = true
      break
    }
  } catch {}
  await sleep(10)
}
if (!rotated) throw new Error('new TLS certificate was not published')
const nextTls = await connect(
  'mqtts://localhost:' + tlsPort, nextCA, 'reload-new-tls'
)
const nextWss = await connect(
  'wss://localhost:' + wssPort + '/mqtt', nextCA, 'reload-new-wss'
)
await publish(old, 'safe/old-connection')
await end(nextTls)
await end(nextWss)
fs.rmSync(certPath)
fs.rmSync(keyPath)
const captured = await connect(
  'mqtts://localhost:' + tlsPort, nextCA, 'reload-captured-tls'
)
await end(captured)
await end(old)
for (let attempt = 0; attempt < 500; attempt++) {
  const directories = fs.readdirSync(root).filter(name =>
    name.startsWith('moonbit-mqtt-tls-'))
  if (directories.length === 2) break
  if (attempt === 499) throw new Error('old TLS lease did not retire')
  await sleep(10)
}
console.log('atomic TLS failure and TLS/WSS captured material rotation passed')
