import assert from 'node:assert/strict'
import net from 'node:net'
import tls from 'node:tls'
import { spawn } from 'node:child_process'
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises'
import { readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { createHash } from 'node:crypto'
import { generate, parser } from 'mqtt-packet'

const binary = process.argv[2]
assert.ok(binary, 'broker executable argument is required')
const work = await mkdtemp(path.join(tmpdir(), 'mqtt-resource-tests-'))
const pause = ms => new Promise(resolve => setTimeout(resolve, ms))
const until = async (predicate, label, timeout = 8000) => {
  const end = performance.now() + timeout
  while (!predicate()) { if (performance.now() > end) throw Error('timeout: ' + label); await pause(5) }
}
const connectPacket = (id, clean = true) => ({ cmd: 'connect', protocolId: 'MQTT', protocolVersion: 4, clientId: id, clean, keepalive: 0 })
const reports = []
const processes = new Set()

class Raw {
  constructor (socket, server) {
    this.socket = socket; this.server = server; this.closed = false; this.inbox = []; this.waiters = []
    server.clients.add(this)
    const decode = parser({ protocolVersion: 4 })
    decode.on('packet', packet => {
      const index = this.waiters.findIndex(waiter => waiter.cmd === packet.cmd)
      if (index < 0) this.inbox.push(packet)
      else { const [waiter] = this.waiters.splice(index, 1); clearTimeout(waiter.timer); waiter.resolve(packet) }
    })
    decode.on('error', error => { this.error = error; socket.destroy() })
    socket.on('data', bytes => decode.parse(bytes))
    socket.on('error', error => { this.error = error })
    socket.on('close', () => {
      this.closed = true; server.clients.delete(this)
      for (const waiter of this.waiters) { clearTimeout(waiter.timer); waiter.reject(Error('closed while waiting for ' + waiter.cmd)) }
      this.waiters = []
    })
  }
  send (packet) { if (!this.closed) this.socket.write(generate(packet, { protocolVersion: 4 })) }
  next (cmd, timeout = 5000) {
    const index = this.inbox.findIndex(packet => packet.cmd === cmd)
    if (index >= 0) return Promise.resolve(this.inbox.splice(index, 1)[0])
    if (this.closed) return Promise.reject(Error('already closed: ' + cmd))
    return new Promise((resolve, reject) => {
      const waiter = { cmd, resolve, reject }
      waiter.timer = setTimeout(() => { this.waiters = this.waiters.filter(item => item !== waiter); reject(Error('packet timeout: ' + cmd)) }, timeout)
      this.waiters.push(waiter)
    })
  }
  async subscribe (topic, qos = 0) {
    this.send({ cmd: 'subscribe', messageId: 123, subscriptions: [{ topic, qos }] })
    const ack = await this.next('suback'); assert.equal(ack.granted[0], qos)
  }
  async qos2 (topic, payload, id = 1, retain = false) {
    this.send({ cmd: 'publish', topic, payload, qos: 2, messageId: id, retain })
    assert.equal((await this.next('pubrec')).messageId, id)
    this.send({ cmd: 'pubrel', messageId: id, qos: 1 })
    assert.equal((await this.next('pubcomp')).messageId, id)
  }
  async ping () { const t = performance.now(); this.send({ cmd: 'pingreq' }); await this.next('pingresp'); return performance.now() - t }
  async disconnect () { this.send({ cmd: 'disconnect' }); await until(() => this.closed, 'disconnect') }
  destroy () { this.socket.destroy() }
}

async function launch (options = []) {
  const probe = net.createServer(); await new Promise(resolve => probe.listen(0, '127.0.0.1', resolve))
  const port = probe.address().port; await new Promise(resolve => probe.close(resolve))
  const args = ['--listen', `127.0.0.1:${port}`, '--keep-alive-check-interval-ms', '20', '--system-metrics-interval-ms', '50', ...options]
  const child = spawn('stdbuf', ['-oL', binary, ...args], { stdio: ['ignore', 'pipe', 'pipe'] })
  const server = { child, port, clients: new Set(), output: '', rss: 0, args }
  processes.add(server)
  child.stdout.on('data', bytes => { server.output = (server.output + bytes).slice(-1000000) })
  child.stderr.on('data', bytes => { server.output = (server.output + bytes).slice(-1000000) })
  server.sample = setInterval(() => {
    try { const match = readFileSync(`/proc/${child.pid}/status`, 'utf8').match(/^VmRSS:\s+(\d+)/m); if (match) server.rss = Math.max(server.rss, +match[1]) } catch {}
  }, 10)
  server.finished = () => child.exitCode !== null || child.signalCode !== null
  server.stop = async (expected = 0) => {
    for (const client of [...server.clients]) client.destroy()
    if (!server.finished()) { child.kill('SIGTERM'); await until(server.finished, 'server shutdown', 10000) }
    clearInterval(server.sample); processes.delete(server)
    if (expected === 'failure') assert.notEqual(child.exitCode, 0, server.output)
    else if (expected !== null) assert.equal(child.exitCode, expected, server.output)
  }
  server.raw = async (id, { clean = true, mqtt = true } = {}) => {
    const socket = net.createConnection({ host: '127.0.0.1', port })
    const client = new Raw(socket, server)
    await new Promise((resolve, reject) => { socket.once('connect', resolve); socket.once('error', reject) })
    if (mqtt) { client.send(connectPacket(id, clean)); assert.equal((await client.next('connack')).returnCode, 0) }
    return client
  }
  return server
}

async function scenario (name, options, test, expectedExit = 0) {
  const server = await launch(options)
  try {
    await until(() => server.output.includes('MQTT broker listening') || server.finished(), name + ' startup')
    assert.ok(!server.finished(), server.output)
    await test(server)
    await server.stop(expectedExit)
    reports.push({ name, rss_peak_kib: server.rss, passed: true })
    console.log('RESOURCE scenario passed: ' + name)
  } catch (error) { await server.stop(null); throw Error(name + ': ' + error.message + '\n' + server.output, { cause: error }) }
}

try {
  await scenario('retained exact cap and atomic replacement', ['--max-retained-bytes-total', '100'], async server => {
    const publisher = await server.raw('retained-publisher')
    await publisher.qos2('t', Buffer.from('123'), 1, true)
    publisher.send({ cmd: 'publish', topic: 't', payload: Buffer.from('1234'), qos: 2, messageId: 2, retain: true })
    await until(() => publisher.closed, 'over-budget publisher closes')
    assert.ok(!publisher.inbox.some(packet => packet.cmd === 'pubrec' && packet.messageId === 2))
    const reader = await server.raw('retained-reader'); await reader.subscribe('t')
    const retained = await reader.next('publish'); assert.equal(retained.payload.toString(), '123'); assert.equal(retained.retain, true)
    assert.ok(await reader.ping() < 1000)
  })

  await scenario('fanout rollback and managed-byte observation', ['--max-inflight-per-session', '0', '--max-pending-bytes-total', '199'], async server => {
    for (const id of ['offline-a', 'offline-b']) { const client = await server.raw(id, { clean: false }); await client.subscribe('t', 1); await client.disconnect() }
    const observer = await server.raw('resource-observer'); await observer.subscribe('$SYS/broker/resources/usage')
    const publisher = await server.raw('fanout-publisher')
    publisher.send({ cmd: 'publish', topic: 't', payload: Buffer.from('123'), qos: 2, messageId: 1, retain: true })
    await until(() => publisher.closed, 'fanout rejected')
    const usage = JSON.parse((await observer.next('publish')).payload.toString())
    assert.equal(usage.pending.used, 0); assert.equal(usage.retained.used, 0)
    assert.ok(Object.values(usage).reduce((sum, row) => sum + row.used + row.reserved, 0) <= 268435456)
    assert.ok(await observer.ping() < 1000)
  })

  await scenario('QoS2 duplicate handshake and persistent rate debt', ['--publish-messages-per-session', '0', '--publish-messages-burst-per-session', '1'], async server => {
    const subscriber = await server.raw('rate-subscriber'); await subscriber.subscribe('t')
    let publisher = await server.raw('rate-publisher', { clean: false })
    const first = { cmd: 'publish', topic: 't', payload: Buffer.from('once'), qos: 2, messageId: 1 }
    publisher.send(first); await publisher.next('pubrec'); await subscriber.next('publish')
    publisher.send({ ...first, dup: true }); await publisher.next('pubrec')
    publisher.send({ cmd: 'pubrel', messageId: 1, qos: 1 }); await publisher.next('pubcomp')
    assert.ok(!subscriber.inbox.some(packet => packet.cmd === 'publish'))
    publisher.send({ ...first, messageId: 2 }); await until(() => publisher.closed, 'fresh publication over rate')
    publisher = await server.raw('rate-publisher', { clean: false })
    publisher.send({ ...first, messageId: 3 }); await until(() => publisher.closed, 'persistent bucket survives reconnect')
    const qos1 = await server.raw('qos1-dup-publisher')
    qos1.send({ ...first, qos: 1 }); await qos1.next('puback')
    qos1.send({ ...first, qos: 1, dup: true }); await until(() => qos1.closed, 'QoS1 DUP consumes business token')
    assert.ok(await subscriber.ping() < 1000)
  })

  await scenario('IP cap includes pre-CONNECT transports and recovers', ['--rate-limits-enabled', 'false', '--max-connections-per-ip', '2'], async server => {
    const a = await server.raw('a', { mqtt: false }); const b = await server.raw('b', { mqtt: false })
    const refused = await server.raw('refused', { mqtt: false }); await until(() => refused.closed, 'IP preauth cap')
    a.destroy(); b.destroy(); await until(() => a.closed && b.closed, 'preauth sockets close'); await pause(50)
    const healthy = await server.raw('recovered'); assert.ok(await healthy.ping() < 1000)
  })

  const certificate = path.join(work, 'tls.crt')
  const privateKey = path.join(work, 'tls.key')
  await new Promise((resolve, reject) => {
    const cert = spawn('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', privateKey, '-out', certificate, '-subj', '/CN=localhost', '-days', '1'], { stdio: 'ignore' })
    cert.once('error', reject); cert.once('close', code => code === 0 ? resolve() : reject(Error('TLS test fixture generation failed')))
  })
  await scenario('IP gate precedes TLS handshake and releases failed handshakes', ['--tls-cert', certificate, '--tls-key', privateKey, '--max-connections-per-ip', '1', '--rate-limits-enabled', 'false'], async server => {
    const incomplete = await server.raw('incomplete-tls', { mqtt: false })
    const rejected = await server.raw('rejected-tls', { mqtt: false })
    await until(() => rejected.closed, 'TLS gate must reject before handshake timeout', 1000)
    incomplete.destroy(); await until(() => incomplete.closed, 'incomplete TLS close'); await pause(50)
    const socket = tls.connect({ host: '127.0.0.1', port: server.port, rejectUnauthorized: false })
    const healthy = new Raw(socket, server)
    await new Promise((resolve, reject) => { socket.once('secureConnect', resolve); socket.once('error', reject) })
    healthy.send(connectPacket('tls-recovered'))
    assert.equal((await healthy.next('connack')).returnCode, 0)
    assert.ok(await healthy.ping() < 1000)
  })

  const passwordFile = path.join(work, 'passwords')
  const encodedHash = await new Promise((resolve, reject) => {
    const hash = spawn('argon2', ['resource-test-salt', '-id', '-t', '1', '-m', '10', '-p', '1', '-e'], { stdio: ['pipe', 'pipe', 'pipe'] })
    let encoded = ''
    hash.stdout.on('data', bytes => { encoded += bytes })
    hash.stderr.resume()
    hash.once('error', reject)
    hash.once('close', code => code === 0 ? resolve(encoded.trim()) : reject(Error('Argon2 test fixture generation failed')))
    hash.stdin.end('resource-test-password')
  })
  await writeFile(passwordFile, 'alice:' + encodedHash + '\n', { mode: 0o600 })
  await scenario('real authentication attempts are charged once', ['--password-file', passwordFile, '--auth-rate-total', '0', '--auth-burst-total', '1'], async server => {
    const bad = await server.raw('bad-auth', { mqtt: false })
    bad.send({ ...connectPacket('bad-auth'), username: 'alice', password: Buffer.from('incorrect') })
    assert.equal((await bad.next('connack')).returnCode, 4)
    const limited = await server.raw('limited-auth', { mqtt: false })
    limited.send({ ...connectPacket('limited-auth'), username: 'alice', password: Buffer.from('resource-test-password') })
    assert.equal((await limited.next('connack')).returnCode, 3)
    const healthy = await server.raw('anonymous-healthy'); assert.ok(await healthy.ping() < 1000)
  })

  const ingressPacket = generate(connectPacket('ingress'), { protocolVersion: 4 })
  await scenario('actual ingress charged exactly once', ['--ingress-bytes-total', '0', '--ingress-bytes-burst-total', String(ingressPacket.length)], async server => {
    const client = await server.raw('ingress')
    client.send({ cmd: 'pingreq' }); await until(() => client.closed, 'raw next bytes exceed cap')
    assert.ok(!client.inbox.some(packet => packet.cmd === 'pingresp'))
  })

  await scenario('oversized outbound isolates recipient', ['--max-outbound-bytes-per-connection', '300'], async server => {
    const recipient = await server.raw('small-outbound', { clean: false }); await recipient.subscribe('large', 1)
    const publisher = await server.raw('large-publisher')
    const healthy = await server.raw('healthy-pinger')
    publisher.send({ cmd: 'publish', topic: 'large', payload: Buffer.alloc(1024, 65), qos: 1, messageId: 1 })
    await publisher.next('puback'); await until(() => recipient.closed, 'large recipient closed')
    assert.ok(await healthy.ping() < 1000); assert.ok(await publisher.ping() < 1000)
  })

  const dataDir = path.join(work, 'restore')
  await scenario('committed snapshot seed', ['--data-dir', dataDir, '--snapshot-debounce-ms', '10', '--snapshot-max-delay-ms', '20'], async server => {
    const publisher = await server.raw('snapshot-seed'); await publisher.qos2('persist', Buffer.alloc(512, 65), 1, true)
    await until(() => server.output.includes('snapshot committed revision='), 'snapshot committed')
  })
  const original = await readFile(path.join(dataDir, 'broker.snapshot'))
  const hash = buffer => createHash('sha256').update(buffer).digest('hex')
  const failed = await launch(['--data-dir', dataDir, '--max-retained-bytes-total', '100'])
  await until(failed.finished, 'low-budget restore exits'); assert.ok(!failed.output.includes('MQTT broker listening'))
  await failed.stop('failure')
  assert.equal(hash(await readFile(path.join(dataDir, 'broker.snapshot'))), hash(original))
  reports.push({ name: 'low-budget restore preserves committed file', passed: true })

  await scenario('deferred snapshot reports failed final commit', ['--data-dir', path.join(work, 'deferred'), '--max-snapshot-work-bytes', '0', '--snapshot-debounce-ms', '10', '--snapshot-max-delay-ms', '20'], async server => {
    const publisher = await server.raw('deferred-publisher'); await publisher.qos2('persist', Buffer.from('body'), 1, true)
    await until(() => server.output.includes('snapshot_budget_deferred'), 'snapshot budget diagnosis')
  }, 'failure')

  await scenario('slow consumer load preserves healthy PING progress', ['--rate-limits-enabled', 'false', '--per-ip-limits-enabled', 'false', '--max-packet-size', '131072', '--max-receive-buffer-size', '131072', '--max-outbound-queue', '8'], async server => {
    const slow = await server.raw('slow-reader'); await slow.subscribe('load'); slow.socket.pause()
    const publisher = await server.raw('load-publisher'); const pinger = await server.raw('load-pinger')
    const frame = generate({ cmd: 'publish', topic: 'load', payload: Buffer.alloc(65536, 65), qos: 1, messageId: 1 }, { protocolVersion: 4 })
    let done = false; const pings = []
    const progress = (async () => { while (!done) { pings.push(await pinger.ping()); await pause(5) } })()
    try {
      for (let i = 0; i < 512 && !server.output.includes('reason=slow_consumer'); i++) {
        publisher.socket.write(frame)
        assert.equal((await publisher.next('puback')).messageId, 1)
        if (i % 8 === 0) await pause(1)
      }
      await until(() => server.output.includes('slow_consumer'), 'slow-consumer rejection')
    } finally { done = true; slow.destroy(); await progress }
    assert.ok(pings.length >= 2, 'multiple healthy requests must advance during load')
    pings.sort((a, b) => a - b)
    const p99 = pings[Math.min(pings.length - 1, Math.floor(pings.length * 0.99))]
    assert.ok(p99 < 100, `PING stalled: ${p99}ms`)
    reports.push({ name: 'load measurements', ping_samples: pings.length, ping_p99_ms: p99, ping_max_ms: pings.at(-1) })
  })

  console.log('RESOURCE_RESULTS=' + JSON.stringify(reports))
  console.log('RESOURCE byte admission, rate semantics, lifecycle, restore and isolation passed')
} finally {
  for (const server of [...processes]) await server.stop(null)
  await rm(work, { recursive: true, force: true })
}
