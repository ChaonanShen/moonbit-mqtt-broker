import fs from 'node:fs'
import crypto from 'node:crypto'
import { execFileSync } from 'node:child_process'
import mqtt from 'mqtt'

const [port, configPath, manifestPath, passwordPath, aclPath, logPath, pid, mode, dataPath] =
  process.argv.slice(2)
if (!pid || !mode || !dataPath) throw new Error('usage: node reload_security.mjs PORT CONFIG MANIFEST PASSWORD ACL LOG PID MODE DATA')
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
const assert = (value, message) => { if (!value) throw new Error(message) }
const url = 'mqtt://127.0.0.1:' + port
const options = (clientId, username, password) => ({
  clientId, username, password, clean: false, protocolVersion: 4,
  reconnectPeriod: 0, connectTimeout: 3000, keepalive: 5
})
const connect = (clientId, username, password) => new Promise((resolve, reject) => {
  const client = mqtt.connect(url, options(clientId, username, password))
  const error = err => { client.end(true); reject(err) }
  client.once('error', error)
  client.once('connect', () => {
    client.off('error', error)
    resolve(client)
  })
})
const rejected = async (id, user, password) => {
  try {
    const client = await connect(id, user, password)
    client.end(true)
    throw new Error('connection unexpectedly accepted')
  } catch (error) {
    if (String(error).includes('unexpectedly accepted')) throw error
  }
}
const closed = client => new Promise(resolve => {
  if (!client.connected) return resolve()
  client.once('close', resolve)
})
const subscribe = client => new Promise((resolve, reject) => {
  client.subscribe('safe/#', { qos: 1 }, error =>
    error ? reject(error) : resolve())
})
const publish = (client, message) => new Promise((resolve, reject) => {
  client.publish('safe/one', message, { qos: 1 }, error =>
    error ? reject(error) : resolve())
})
const end = client => new Promise(resolve => client.end(false, {}, resolve))
const hash = password => execFileSync('argon2', [
  'reload-salt-0001', '-id', '-e', '-t', '2', '-m', '12', '-p', '1'
], { input: password }).toString().trim()
const config = (allowAnonymous, usePassword, useAcl) => {
  let text = '[server]\nlisten = "127.0.0.1:' + port + '"\n'
  if (mode !== 'off') text += '[persistence]\nmode = "' + mode + '"\ndata_dir = "' + dataPath + '"\n'
  text += '[security]\nallow_anonymous = ' + allowAnonymous + '\n'
  if (usePassword) text += 'password_file = "' + passwordPath + '"\n'
  if (useAcl) text += 'acl_file = "' + aclPath + '"\n'
  text += '[reload]\nenabled = true\nmanifest_file = "' + manifestPath + '"\n'
  fs.writeFileSync(configPath, text)
  let manifest = 'version = 1\n'
  const materials = [['config', configPath]]
  if (usePassword) materials.push(['passwords', passwordPath])
  if (useAcl) materials.push(['acl', aclPath])
  for (const [role, path] of materials) {
    const digest = crypto.createHash('sha256').update(fs.readFileSync(path)).digest('hex')
    manifest += '[[materials]]\nrole = "' + role + '"\npath = "' + path +
      '"\nsha256 = "' + digest + '"\n'
  }
  fs.writeFileSync(manifestPath, manifest, { mode: 0o600 })
}
const waitReload = async epoch => {
  for (let attempt = 0; attempt < 800; attempt++) {
    if (fs.readFileSync(logPath, 'utf8').includes('reload_completed message=reload request=' +
        epoch + ' config_epoch=' + epoch)) return
    await sleep(10)
  }
  throw new Error('reload epoch ' + epoch + ' did not complete; ' +
    fs.readFileSync(logPath, 'utf8').slice(-800))
}
const anonymous = await connect('reload-anonymous')
const anonymousClosed = closed(anonymous)
fs.writeFileSync(passwordPath, 'alice:' + hash('first-secret') + '\n', { mode: 0o600 })
fs.writeFileSync(aclPath, 'user alice\ntopic read safe/#\ntopic write safe/#\n')
config(false, true, true)
process.kill(Number(pid), 'SIGHUP')
await waitReload(1)
await Promise.race([anonymousClosed, sleep(3000).then(() => {
  throw new Error('anonymous connection not revoked')
})])
await rejected('reload-denied-anonymous')
const alice = await connect('reload-alice', 'alice', 'first-secret')
const aliceClosed = closed(alice)
fs.writeFileSync(passwordPath, 'alice:' + hash('second-secret') + '\n', { mode: 0o600 })
config(false, true, true)
process.kill(Number(pid), 'SIGHUP')
await waitReload(2)
await Promise.race([aliceClosed, sleep(3000).then(() => {
  throw new Error('old credential connection not revoked')
})])
await rejected('reload-old-password', 'alice', 'first-secret')
const current = await connect('reload-current', 'alice', 'second-secret')
const publisher = await connect('reload-publisher', 'alice', 'second-secret')
await subscribe(current)
let deliveries = 0
current.on('message', () => { deliveries++ })
await publish(publisher, 'before-acl')
for (let attempt = 0; attempt < 200 && deliveries === 0; attempt++) await sleep(10)
assert(deliveries === 1, 'initial subscription did not deliver')
fs.writeFileSync(aclPath, 'user alice\ntopic read other/#\ntopic write safe/#\n')
config(false, true, true)
process.kill(Number(pid), 'SIGHUP')
await waitReload(3)
assert(current.connected, 'unchanged credential connection closed')
await publish(publisher, 'after-acl')
await sleep(200)
assert(deliveries === 1, 'revoked subscription delivered a message')
await end(current)
await end(publisher)
console.log('anonymous, credential and ACL revocation passed')
