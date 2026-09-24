import fs from 'node:fs'
import crypto from 'node:crypto'

const [port, configPath, manifestPath, brokerPid] = process.argv.slice(2)
if (!port || !configPath || !manifestPath || !brokerPid) {
  throw new Error('usage: node reload_lifecycle.mjs PORT CONFIG MANIFEST PID')
}
const token = 'spike-token.' +
  '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
const base = 'http://127.0.0.1:' + port
const headers = { Authorization: 'Bearer ' + token }
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
const request = async (path, options = {}) => {
  const response = await fetch(base + path, {
    ...options,
    headers: { ...headers, ...options.headers },
    signal: AbortSignal.timeout(3000)
  })
  const text = await response.text()
  let json
  try { json = JSON.parse(text) } catch { throw new Error('non-JSON ' + response.status) }
  return { response, json }
}
const assert = (condition, message) => { if (!condition) throw new Error(message) }
const waitOperation = async id => {
  for (let attempt = 0; attempt < 500; attempt++) {
    const { response, json } = await request('/v1/operations/' + id)
    if (response.status === 404) { await sleep(10); continue }
    assert(response.status === 200, 'operation lookup ' + response.status)
    if (json.state === 'succeeded' || json.state === 'failed') return json
    await sleep(10)
  }
  throw new Error('operation ' + id + ' did not finish')
}
const initial = await request('/v1/config')
assert(initial.response.status === 200, 'config admin GET failed')
assert(initial.json.config_epoch === '0', 'initial epoch')
const etag = initial.response.headers.get('etag')
assert(etag?.endsWith(':g:0"'), 'strong config ETag missing')
const updated = fs.readFileSync(configPath, 'utf8').replace(
  'log_level = "info"', 'log_level = "debug"'
)
assert(updated.includes('log_level = "debug"'), 'config fixture update')
fs.writeFileSync(configPath, updated)
const digest = crypto.createHash('sha256').update(updated).digest('hex')
const manifest = 'version = 1\n[[materials]]\nrole = "config"\n' +
  'path = "' + configPath + '"\nsha256 = "' + digest + '"\n'
fs.writeFileSync(manifestPath, manifest, { mode: 0o600 })
const idem = 'Reload-Key-0123456789'
const post = async (match, key, body) => request('/v1/config/reload', {
  method: 'POST',
  headers: {
    'If-Match': match,
    'Idempotency-Key': key,
    'Content-Type': 'application/json'
  },
  body: JSON.stringify(body)
})
const accepted = await post(etag, idem, { expected_generation: 0 })
assert(accepted.response.status === 202, 'reload HTTP ' + accepted.response.status)
const id = accepted.json.operation_id
assert(typeof id === 'string', 'operation id missing')
const repeated = await post(etag, idem, { expected_generation: 0 })
assert(repeated.response.status === 202, 'idempotent retry status')
assert(repeated.json.operation_id === id, 'idempotent retry identity')
const terminal = await waitOperation(id)
assert(terminal.state === 'succeeded', 'reload failed ' + terminal.error_code)
assert(terminal.effect_applied === true, 'hot update not applied')
const current = await request('/v1/config')
assert(current.json.config_epoch === '1', 'published epoch not visible')
const conflict = await post(current.response.headers.get('etag'), idem, { expected_generation: 1 })
assert(conflict.response.status === 409, 'same key changed request must conflict')
const stale = await post(etag, 'Reload-Key-9999999999', { expected_generation: 0 })
assert(stale.response.status === 412, 'stale config ETag must fail')
const malformed = await request('/v1/config/reload', {
  method: 'POST',
  headers: {
    'If-Match': current.response.headers.get('etag'),
    'Idempotency-Key': 'Reload-Key-2222222222',
    'Content-Type': 'application/json'
  },
  body: '{"expected_generation":1,"expected_generation":1}'
})
assert(malformed.response.status === 400, 'duplicate JSON field accepted')
process.kill(Number(brokerPid), 'SIGHUP')
const signalId = initial.json.boot_id + '.2'
const signal = await waitOperation(signalId)
assert(signal.state === 'succeeded', 'SIGHUP no-change operation failed')
assert(signal.effect_applied === false, 'no-change signal advanced generation')
const audit = await request('/v1/audit?limit=10')
assert(audit.response.status === 200, 'config admin audit unavailable')
assert(JSON.stringify(audit.json).includes(signalId), 'local signal audit missing')
console.log('reload lifecycle HTTP, idempotency, ETag, signal and audit passed')

