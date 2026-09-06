import assert from 'node:assert/strict'
import net from 'node:net'
import { spawn, execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import mqtt from 'mqtt'
import { generate, parser } from 'mqtt-packet'

const execute = promisify(execFile)
const binary = process.argv[2]
if (!binary) throw new Error('usage: node qos2.mjs /absolute/path/to/broker.exe')
const work = await mkdtemp(path.join(tmpdir(), 'moonbit-qos2-'))
const dataDir = path.join(work, 'data')
const pause = ms => new Promise(resolve => setTimeout(resolve, ms))
const deadline = async (fn, description, ms = 8000) => {
  const end = Date.now() + ms
  while (Date.now() < end) { if (await fn()) return; await pause(10) }
  throw new Error('timed out: ' + description)
}
const free = net.createServer()
await new Promise(resolve => free.listen(0, '127.0.0.1', resolve))
const port = free.address().port
await new Promise(resolve => free.close(resolve))
const url = 'mqtt://127.0.0.1:' + port
let child, output = '', serial = 0
const sockets = new Set(), mqttClients = new Set()
const start = async () => {
  output = ''
  child = spawn('stdbuf', ['-oL', binary, '--listen', '127.0.0.1:' + port,
    '--data-dir', dataDir, '--snapshot-debounce-ms', '30', '--snapshot-max-delay-ms', '100',
    '--snapshot-retry-ms', '20', '--max-inflight-per-session', '4',
    '--max-inflight-total', '128', '--max-pending-per-session', '16',
    '--max-pending-total', '256', '--max-inbound-qos2-per-session', '8',
    '--max-inbound-qos2-total', '128', '--max-sessions', '128',
    '--keep-alive-check-interval-ms', '20'], { stdio: ['ignore', 'pipe', 'pipe'] })
  child.stdout.on('data', chunk => { output = (output + chunk).slice(-1000000) })
  child.stderr.on('data', chunk => { output = (output + chunk).slice(-1000000) })
  await deadline(() => {
    if (child.exitCode !== null) throw new Error('broker exited: ' + output)
    return output.includes('MQTT broker listening')
  }, 'broker startup')
}
const stop = async (signal = 'SIGTERM') => {
  const current = child
  current.kill(signal)
  await deadline(() => current.exitCode !== null || current.signalCode !== null, 'broker exit')
  child = undefined
  if (signal === 'SIGTERM') assert.equal(current.exitCode, 0, output)
}

class Raw {
  constructor (socket) {
    this.socket = socket; sockets.add(socket)
    this.inbox = []; this.waiters = []; this.closed = false; this.buffer = Buffer.alloc(0)
    socket.on('error', () => {})
    socket.on('close', () => { sockets.delete(socket); this.closed = true; this.accept({ cmd: 'closed' }) })
    socket.on('data', chunk => {
      this.buffer = Buffer.concat([this.buffer, chunk])
      for (;;) {
        if (this.buffer.length < 2) return
        let length = 0, multiplier = 1, i = 1, digit
        do {
          if (i >= this.buffer.length) return
          digit = this.buffer[i++]; length += (digit & 127) * multiplier; multiplier *= 128
        } while (digit & 128)
        if (this.buffer.length < i + length) return
        const frame = this.buffer.subarray(0, i + length)
        this.buffer = this.buffer.subarray(i + length)
        const decode = parser({ protocolVersion: 4 })
        decode.once('packet', packet => this.accept({ ...packet, wire: Buffer.from(frame) }))
        decode.once('error', error => { throw error })
        decode.parse(frame)
      }
    })
  }
  accept (packet) {
    const index = this.waiters.findIndex(waiter => waiter.cmd === packet.cmd)
    if (index < 0) this.inbox.push(packet)
    else { const [waiter] = this.waiters.splice(index, 1); clearTimeout(waiter.timer); waiter.resolve(packet) }
  }
  send (packet) { this.socket.write(generate(packet, { protocolVersion: 4 })) }
  next (cmd) {
    const index = this.inbox.findIndex(packet => packet.cmd === cmd)
    if (index >= 0) return Promise.resolve(this.inbox.splice(index, 1)[0])
    return new Promise((resolve, reject) => {
      const waiter = { cmd, resolve }
      waiter.timer = setTimeout(() => {
        this.waiters = this.waiters.filter(item => item !== waiter)
        reject(new Error('raw timeout: ' + cmd + ', queued=' + this.inbox.map(p => p.cmd)))
      }, 5000)
      this.waiters.push(waiter)
    })
  }
  async ping () { this.send({ cmd: 'pingreq' }); await this.next('pingresp') }
  async disconnect () { this.send({ cmd: 'disconnect' }); await this.next('closed') }
}
const raw = async (id = 'raw-' + (++serial), clean = true, extra = {}) => {
  const socket = net.createConnection({ host: '127.0.0.1', port })
  const client = new Raw(socket)
  await new Promise((resolve, reject) => { socket.once('connect', resolve); socket.once('error', reject) })
  client.send({ cmd: 'connect', protocolId: 'MQTT', protocolVersion: 4, keepalive: 0, clientId: id, clean, ...extra })
  client.connack = await client.next('connack')
  assert.equal(client.connack.returnCode, 0)
  return client
}
const subscribeRaw = async (client, topic, qos = 2) => {
  client.send({ cmd: 'subscribe', messageId: 55, subscriptions: [{ topic, qos }] })
  assert.deepEqual((await client.next('suback')).granted, [qos])
}
const publishRaw = (client, id, payload = 'first', extra = {}) =>
  client.send({ cmd: 'publish', topic: 'qos2/state', qos: 2, messageId: id, payload: Buffer.from(payload), ...extra })
const ackId = async (client, cmd, id) => assert.equal((await client.next(cmd)).messageId, id)
const finishInbound = async (client, id) => { client.send({ cmd: 'pubrel', messageId: id }); await ackId(client, 'pubcomp', id) }
const pubrec = async (client, id) => {
  client.send({ cmd: 'pubrec', messageId: id })
  const response = await client.next('pubrel')
  assert.equal(response.messageId, id)
  assert.equal(response.wire.toString('hex'), '6202' + id.toString(16).padStart(4, '0'))
}
const finishOutbound = async (client, packet) => {
  if (packet.qos === 2) { await pubrec(client, packet.messageId); client.send({ cmd: 'pubcomp', messageId: packet.messageId }) }
  else if (packet.qos === 1) client.send({ cmd: 'puback', messageId: packet.messageId })
}

// Independent V3 reader: wait for exact committed phases, not an arbitrary delay.
const snapshot = async () => {
  const bytes = await readFile(path.join(dataDir, 'broker.snapshot'))
  assert.equal(bytes.subarray(0, 8).toString(), 'MBMQTT01')
  assert.equal(bytes.readUInt16BE(8), 3)
  assert.equal(Number(bytes.readBigUInt64BE(12)), bytes.length - 24)
  let at = 24
  const u8 = () => bytes[at++]
  const u16 = () => { const n = bytes.readUInt16BE(at); at += 2; return n }
  const u32 = () => { const n = bytes.readUInt32BE(at); at += 4; return n }
  const field = () => { const n = u32(); const b = bytes.subarray(at, at + n); at += n; return b }
  const string = () => field().toString()
  const message = () => ({ topic: string(), payload: field(), retain: u8(), qos: u8() })
  assert.equal(u32(), 3)
  const sessions = []
  for (let count = u32(); count > 0; count--) {
    const s = { id: string(), owner: string(), detach: string(), next: u16(), subscriptions: [], inbound: [], inflight: [], pending: [] }
    for (let n = u32(); n > 0; n--) s.subscriptions.push({ filter: string(), qos: u8() })
    for (let n = u32(); n > 0; n--) s.inbound.push(u16())
    for (let n = u32(); n > 0; n--) { const id = u16(), phase = u8(); s.inflight.push({ id, phase, message: phase === 3 ? null : message() }) }
    for (let n = u32(); n > 0; n--) s.pending.push(message())
    sessions.push(s)
  }
  const retained = []
  for (let n = u32(); n > 0; n--) retained.push({ topic: string(), payload: field(), qos: u8() })
  assert.equal(at, bytes.length)
  return { sessions, retained }
}
const waitSnapshot = predicate => deadline(async () => {
  try { return predicate(await snapshot()) } catch (error) { if (error.code === 'ENOENT') return false; throw error }
}, 'exact committed QoS 2 snapshot')
const connectMqtt = async (id, extra = {}) => {
  const client = mqtt.connect(url, { clientId: id, protocolVersion: 4, clean: true, reconnectPeriod: 0, connectTimeout: 5000, ...extra })
  mqttClients.add(client); client.on('error', () => {})
  await new Promise((resolve, reject) => { client.once('connect', resolve); client.once('error', reject) })
  return client
}
const subMqtt = (c, topic, qos) => new Promise((resolve, reject) => c.subscribe(topic, { qos }, (e, grants) => e ? reject(e) : resolve(grants)))
const pubMqtt = (c, topic, body, qos = 2, retain = false) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('MQTT.js publish timeout: ' + topic)), 5000)
  c.publish(topic, body, { qos, retain }, e => { clearTimeout(timer); if (e) reject(e); else resolve() })
})
const endMqtt = async c => { await new Promise(resolve => c.end(false, {}, resolve)); mqttClients.delete(c) }

try {
  await start()
  let sub = await raw('q2-subscriber', false), pub = await raw('q2-publisher', false)
  await subscribeRaw(sub, 'qos2/#')
  publishRaw(pub, 7, 'first', { retain: true }); await ackId(pub, 'pubrec', 7)
  const first = await sub.next('publish')
  assert.equal(first.qos, 2); assert.equal(first.payload.toString(), 'first')
  for (let i = 0; i < 100; i++) {
    publishRaw(pub, 7, 'must-not-replace', { dup: i % 2 === 0, retain: true })
    await ackId(pub, 'pubrec', 7)
  }
  await sub.ping(); assert.equal(sub.inbox.filter(p => p.cmd === 'publish').length, 0)
  await pubrec(sub, first.messageId); await pubrec(sub, first.messageId)
  publishRaw(pub, 8, 'second'); await ackId(pub, 'pubrec', 8)
  const second = await sub.next('publish')
  await finishInbound(pub, 8)
  await waitSnapshot(s => {
    const source = s.sessions.find(c => c.id === 'q2-publisher'), target = s.sessions.find(c => c.id === 'q2-subscriber')
    return source?.inbound.join() === '7' && target?.inflight.length === 2 &&
      target.inflight.some(i => i.id === first.messageId && i.phase === 3 && i.message === null) &&
      target.inflight.some(i => i.id === second.messageId && i.phase === 2) &&
      s.retained.some(r => r.payload.toString() === 'first')
  })
  await stop('SIGKILL'); await start()
  sub = await raw('q2-subscriber', false); assert.equal(sub.connack.sessionPresent, true)
  const replay = await sub.next('publish')
  assert.equal(replay.messageId, second.messageId); assert.equal(replay.dup, true)
  const release = await sub.next('pubrel')
  assert.equal(release.messageId, first.messageId); assert.equal(release.wire[0], 0x62)
  sub.send({ cmd: 'pubcomp', messageId: first.messageId }); await finishOutbound(sub, replay)
  pub = await raw('q2-publisher', false)
  publishRaw(pub, 7, 'recovered-duplicate', { dup: true, retain: true }); await ackId(pub, 'pubrec', 7)
  await sub.ping(); assert.equal(sub.inbox.filter(p => p.cmd === 'publish').length, 0)
  await finishInbound(pub, 7); await finishInbound(pub, 7)
  publishRaw(pub, 7, '', { retain: true }); await ackId(pub, 'pubrec', 7)
  const deletion = await sub.next('publish'); assert.equal(deletion.payload.length, 0)
  await finishOutbound(sub, deletion); await finishInbound(pub, 7)
  await waitSnapshot(s => s.sessions.every(c => c.inbound.length === 0 && c.inflight.length === 0) && s.retained.length === 0)
  await sub.disconnect()
  for (let i = 0; i < 4; i++) {
    const qos = i % 2 + 1
    publishRaw(pub, 20 + i, 'fifo-' + i, { qos }); await ackId(pub, qos === 2 ? 'pubrec' : 'puback', 20 + i)
    if (qos === 2) await finishInbound(pub, 20 + i)
  }
  sub = await raw('q2-subscriber', false)
  for (let i = 0; i < 4; i++) {
    const packet = await sub.next('publish')
    assert.equal(packet.payload.toString(), 'fifo-' + i); assert.equal(packet.qos, i % 2 + 1)
    await finishOutbound(sub, packet)
  }
  await sub.ping(); await sub.disconnect(); await pub.disconnect()
  await stop(); await start()
  sub = await raw('q2-subscriber', false); await sub.ping(); assert.equal(sub.inbox.length, 0); await sub.disconnect()
  const resetSubscriber = await raw('q2-subscriber', true); await resetSubscriber.disconnect()
  console.log('QOS2 exact committed SIGKILL recovery, deduplication, payload-free PUBREL and mixed FIFO passed')

  let limited = await raw('q2-limited', false)
  for (let id = 1; id <= 8; id++) { publishRaw(limited, id, 'limit', { topic: 'unused/limit' }); await ackId(limited, 'pubrec', id) }
  publishRaw(limited, 1, 'duplicate', { topic: 'unused/limit' }); await ackId(limited, 'pubrec', 1)
  await finishInbound(limited, 1)
  publishRaw(limited, 9, 'reuse', { topic: 'unused/limit' }); await ackId(limited, 'pubrec', 9)
  publishRaw(limited, 10, 'overflow', { topic: 'unused/limit' }); await limited.next('closed')
  limited = await raw('q2-limited', false)
  for (let id = 2; id <= 9; id++) await finishInbound(limited, id)
  await limited.disconnect()
  for (const bytes of [[0x6a, 2, 0, 1], [0x50, 2, 0, 0], [0x70, 1, 1]]) {
    const bad = await raw(); bad.socket.write(Buffer.from(bytes)); await bad.next('closed')
  }
  const observer = await raw(); await subscribeRaw(observer, 'qos2/will')
  const doomed = await raw('q2-will-source', true, { will: { topic: 'qos2/will', payload: Buffer.from('offline'), qos: 2, retain: true } })
  doomed.socket.destroy()
  const will = await observer.next('publish'); assert.equal(will.payload.toString(), 'offline')
  await finishOutbound(observer, will); await observer.disconnect()

  const jsSub = await connectMqtt('q2-js-sub'), received = []
  jsSub.on('message', (topic, body, packet) => {
    if (topic === 'qos2/load') { assert.equal(packet.qos, 2); received.push(body.toString()) }
  })
  assert.equal((await subMqtt(jsSub, 'qos2/load', 2))[0].qos, 2)
  const jsPub = await connectMqtt('q2-js-pub')
  for (let i = 0; i < 1000; i++) await pubMqtt(jsPub, 'qos2/load', String(i))
  await deadline(() => received.length === 1000, '1000 QoS 2 publications')
  assert.deepEqual(received, Array.from({ length: 1000 }, (_, i) => String(i)))
  const fromMosquitto = new Promise(resolve => jsSub.once('message', (topic, payload, packet) => resolve({ topic, payload, packet })))
  await subMqtt(jsSub, 'qos2/mosquitto', 2)
  await execute('mosquitto_pub', ['-h', '127.0.0.1', '-p', String(port), '-q', '2', '-t', 'qos2/mosquitto', '-m', 'mosquitto-to-js'], { timeout: 5000 })
  const observed = await fromMosquitto
  assert.equal(observed.payload.toString(), 'mosquitto-to-js'); assert.equal(observed.packet.qos, 2)
  await pubMqtt(jsPub, 'qos2/js-retained', 'js-to-mosquitto', 2, true)
  const retained = await execute('mosquitto_sub', ['-h', '127.0.0.1', '-p', String(port), '-q', '2', '-t', 'qos2/js-retained', '-C', '1', '-W', '5'], { timeout: 7000 })
  assert.equal(retained.stdout.trim(), 'js-to-mosquitto')
  await endMqtt(jsSub); await endMqtt(jsPub)

  let cycling = await raw('q2-cycles', false)
  await subscribeRaw(cycling, 'qos2/cycles')
  const producer = await raw()
  for (let i = 0; i < 100; i++) {
    publishRaw(producer, i + 1, String(i), { topic: 'qos2/cycles' })
    await ackId(producer, 'pubrec', i + 1); await finishInbound(producer, i + 1)
    const packet = await cycling.next('publish')
    if (i % 2 === 0) await pubrec(cycling, packet.messageId)
    await cycling.disconnect(); cycling = await raw('q2-cycles', false)
    assert.equal(cycling.connack.sessionPresent, true)
    if (i % 2 === 0) {
      const rel = await cycling.next('pubrel')
      assert.equal(rel.messageId, packet.messageId); assert.equal(rel.wire[0], 0x62)
      cycling.send({ cmd: 'pubcomp', messageId: rel.messageId })
    } else {
      const again = await cycling.next('publish')
      assert.equal(again.messageId, packet.messageId); assert.equal(again.dup, true)
      await finishOutbound(cycling, again)
    }
    await cycling.ping(); assert.equal(cycling.inbox.length, 0)
  }
  await cycling.disconnect(); await producer.disconnect()
  // The earlier offline persistent wildcard subscriber intentionally has pending
  // publications from load/Will tests. Clear it with Clean Session before auditing.
  const cleared = await raw('q2-subscriber', true); await cleared.disconnect()
  await waitSnapshot(s => s.sessions.every(c => c.inflight.length === 0 && c.inbound.length === 0 && c.pending.length === 0))
  await stop()
  console.log('QOS2 raw bounds/Will/flags, MQTT.js and Mosquitto, 1000 publications and 100 reconnects passed')
} catch (error) {
  console.error(output); throw error
} finally {
  for (const client of mqttClients) client.end(true)
  for (const socket of sockets) socket.destroy()
  if (child && child.exitCode === null && child.signalCode === null) {
    child.kill('SIGKILL')
    await deadline(() => child.exitCode !== null || child.signalCode !== null, 'cleanup broker')
  }
  await rm(work, { recursive: true, force: true })
}
