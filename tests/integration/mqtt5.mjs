import assert from 'node:assert/strict'
import fs from 'node:fs'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import { spawn, spawnSync } from 'node:child_process'
import mqtt from 'mqtt'
import mqttPacket from 'mqtt-packet'

const brokerPath = process.argv[2]
if (!brokerPath) throw new Error('usage: node mqtt5.mjs BROKER')
const evidenceRoot = process.env.MQTT5_EVIDENCE_DIR ??
  fs.mkdtempSync(path.join(os.tmpdir(), 'moonbit-mqtt5-'))
fs.mkdirSync(evidenceRoot, { recursive: true })
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
const freePort = () => new Promise((resolve, reject) => {
  const server = net.createServer()
  server.once('error', reject)
  server.listen(0, '127.0.0.1', () => {
    const port = server.address().port
    server.close(() => resolve(port))
  })
})
const connectClient = (port, options) => connectAt('mqtt://127.0.0.1:' + port, options)
const closeClient = client => new Promise(resolve => client.end(false, {}, resolve))
const connectAt = (url, options) => new Promise((resolve, reject) => {
  const client = mqtt.connect(url, {
    protocolVersion: 5,
    reconnectPeriod: 0,
    connectTimeout: 5000,
    ...options
  })
  const timer = setTimeout(() => {
    client.destroy()
    reject(new Error('CONNECT timeout: ' + options.clientId))
  }, 7000)
  client.once('error', error => {
    clearTimeout(timer)
    reject(error)
  })
  client.once('connect', packet => {
    clearTimeout(timer)
    resolve([client, packet])
  })
})
const subscribe = (client, topic, options) => new Promise((resolve, reject) => {
  client.subscribe(topic, options, (error, granted) =>
    error ? reject(error) : resolve(granted))
})
const publish = (client, topic, payload, options) => new Promise((resolve, reject) => {
  client.publish(topic, payload, options, error =>
    error ? reject(error) : resolve())
})
const nextMessage = (client, timeoutMs = 5000) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('PUBLISH timeout')), timeoutMs)
  client.once('message', (topic, payload, packet) => {
    clearTimeout(timer)
    resolve({ topic, payload: payload.toString(), packet })
  })
})
async function startBroker(mode, port, dataDir, logPath, commandArgs = null) {
  const args = commandArgs ?? [
    brokerPath,
    '--listen', '127.0.0.1:' + port,
    '--mqtt5-enabled', 'true',
    '--persistence-mode', mode
  ]
  if (commandArgs === null && mode !== 'off') args.push('--data-dir', dataDir)
  const child = spawn('stdbuf', ['-oL', '-eL', ...args], {
    stdio: ['ignore', 'pipe', 'pipe']
  })
  const log = fs.createWriteStream(logPath, { flags: 'a' })
  let output = ''
  child.stdout.on('data', chunk => {
    output += chunk.toString()
    log.write(chunk)
  })
  child.stderr.on('data', chunk => {
    output += chunk.toString()
    log.write(chunk)
  })
  const started = Date.now()
  while (!output.includes('broker_listening')) {
    if (child.exitCode !== null) throw new Error('broker exited: ' + output)
    if (Date.now() - started > 8000) {
      child.kill('SIGKILL')
      throw new Error('broker start timeout: ' + output)
    }
    await sleep(20)
  }
  return { child, log, output: () => output }
}
async function stopBroker(running) {
  const { child, log } = running
  const closed = new Promise(resolve => child.once('close', resolve))
  child.kill('SIGTERM')
  const timer = setTimeout(() => child.kill('SIGKILL'), 7000)
  const status = await closed
  clearTimeout(timer)
  await new Promise(resolve => log.end(resolve))
  assert.equal(status, 0, 'broker shutdown failed: ' + running.output())
}
function rawPacket(port, frame) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1')
    const parser = mqttPacket.parser({ protocolVersion: 5 })
    const timer = setTimeout(() => {
      socket.destroy()
      reject(new Error('raw packet timeout'))
    }, 5000)
    socket.once('connect', () => socket.write(frame))
    socket.on('data', bytes => parser.parse(bytes))
    socket.once('error', reject)
    parser.once('packet', packet => {
      clearTimeout(timer)
      socket.destroy()
      resolve(packet)
    })
  })
}
async function checkMalformedConnect(port) {
  const malformed = Buffer.from('101100044d5154540502000003210000000161', 'hex')
  const reply = await rawPacket(port, malformed)
  assert.equal(reply.cmd, 'connack')
  assert.equal(reply.reasonCode, 0x82)
  console.log('M-T01 malformed MQTT5 CONNECT => CONNACK 82')
}
async function checkSharedUnavailable(port) {
  const socket = net.connect(port, '127.0.0.1')
  const parser = mqttPacket.parser({ protocolVersion: 5 })
  const queue = []
  let waiter = null
  socket.on('data', bytes => parser.parse(bytes))
  parser.on('packet', packet => {
    if (waiter) {
      const resolve = waiter
      waiter = null
      resolve(packet)
    } else queue.push(packet)
  })
  const receive = () => queue.length
    ? Promise.resolve(queue.shift())
    : new Promise(resolve => { waiter = resolve })
  try {
    await new Promise(resolve => socket.once('connect', resolve))
    socket.write(mqttPacket.generate({
      cmd: 'connect', protocolVersion: 5, clientId: 'mqtt5-shared-check',
      clean: true, keepalive: 10, properties: {}
    }, { protocolVersion: 5 }))
    const ack = await Promise.race([
      receive(),
      sleep(5000).then(() => { throw new Error('shared CONNECT timeout') })
    ])
    assert.equal(ack.reasonCode, 0)
    socket.write(mqttPacket.generate({
      cmd: 'subscribe', messageId: 7,
      subscriptions: [{ topic: '$share/demo/mqtt5/#', qos: 1 }],
      properties: {}
    }, { protocolVersion: 5 }))
    const suback = await Promise.race([
      receive(),
      sleep(5000).then(() => { throw new Error('shared SUBACK timeout') })
    ])
    assert.equal(suback.cmd, 'suback')
    assert.deepEqual(suback.granted, [0x9e])
    console.log('M-T02 shared unavailable => SUBACK 9E')
  } finally {
    socket.destroy()
  }
}
async function checkPubSub(port, mode) {
  const [subscriber] = await connectClient(port, {
    clientId: 'mqtt5-sub-' + mode
  })
  const [publisher] = await connectClient(port, {
    clientId: 'mqtt5-pub-' + mode
  })
  try {
    const granted = await subscribe(subscriber, 'mqtt5/core', {
      qos: 2, nl: true, rap: true, rh: 2,
      properties: { subscriptionIdentifier: 7 }
    })
    assert.equal(granted[0].qos, 2)
    const message = nextMessage(subscriber)
    await publish(publisher, 'mqtt5/core', 'payload', {
      qos: 2, retain: true,
      properties: {
        contentType: 'text/plain',
        userProperties: { k: 'v' }
      }
    })
    const received = await message
    assert.equal(received.topic, 'mqtt5/core')
    assert.equal(received.payload, 'payload')
    assert.equal(received.packet.retain, true)
    assert.equal(received.packet.properties.contentType, 'text/plain')
    assert.equal(received.packet.properties.userProperties.k, 'v')
    assert.equal(received.packet.properties.subscriptionIdentifier, 7)
    let selfReceived = false
    subscriber.once('message', () => { selfReceived = true })
    await publish(subscriber, 'mqtt5/core', 'self', { qos: 1 })
    await sleep(150)
    assert.equal(selfReceived, false)
    console.log('M-T03 ' + mode + ' QoS2 metadata NoLocal RAP RH SID')
  } finally {
    await closeClient(publisher)
    await closeClient(subscriber)
  }
}
async function checkSession(port, mode) {
  const options = {
    clientId: 'mqtt5-session-' + mode,
    clean: false,
    properties: { sessionExpiryInterval: 30 }
  }
  let [client, ack] = await connectClient(port, options)
  assert.equal(ack.sessionPresent, false)
  await subscribe(client, 'mqtt5/session', { qos: 1 })
  await closeClient(client)
  ;[client, ack] = await connectClient(port, options)
  assert.equal(ack.sessionPresent, true)
  await closeClient(client)
  console.log('M-T04 ' + mode + ' persistent Session resumes')
}
async function checkRetained(port, mode) {
  const [client] = await connectClient(port, {
    clientId: 'mqtt5-retained-' + mode
  })
  try {
    const message = nextMessage(client)
    await subscribe(client, 'mqtt5/core', { qos: 1 })
    const received = await message
    assert.equal(received.payload, 'payload')
    assert.equal(received.packet.retain, true)
    assert.equal(received.packet.properties.contentType, 'text/plain')
    console.log('M-T05 ' + mode + ' retained metadata replay')
  } finally {
    await closeClient(client)
  }
}
async function checkCrossVersion(port, mode) {
  const legacy = () => connectClient(port, {
    protocolVersion: 4, clientId: 'mqtt5-cross-' + mode, clean: false
  })
  let [client, ack] = await legacy()
  assert.equal(ack.sessionPresent, false)
  await subscribe(client, 'mqtt5/cross', { qos: 1 })
  await closeClient(client)
  ;[client, ack] = await connectClient(port, {
    clientId: 'mqtt5-cross-' + mode, clean: false,
    properties: { sessionExpiryInterval: 30 }
  })
  assert.equal(ack.sessionPresent, true)
  await closeClient(client)
  ;[client, ack] = await legacy()
  assert.equal(ack.sessionPresent, true)
  await closeClient(client)
  console.log('M-T06 ' + mode + ' MQTT3.1.1/MQTT5 Session crossover')
}
async function runMode(mode) {
  const port = await freePort()
  const dir = path.join(evidenceRoot, mode)
  fs.mkdirSync(dir, { recursive: true })
  const dataDir = path.join(dir, 'data')
  const logPath = path.join(dir, 'broker.log')
  let running = await startBroker(mode, port, dataDir, logPath)
  try {
    await checkMalformedConnect(port)
    await checkSharedUnavailable(port)
    await checkPubSub(port, mode)
    await checkSession(port, mode)
    await checkCrossVersion(port, mode)
    if (mode !== 'off') {
      await stopBroker(running)
      running = await startBroker(mode, port, dataDir, logPath)
      const [, sessionAck] = await connectClient(port, {
        clientId: 'mqtt5-session-' + mode, clean: false,
        properties: { sessionExpiryInterval: 30 }
      }).then(async ([client, ack]) => {
        await closeClient(client)
        return [client, ack]
      })
      assert.equal(sessionAck.sessionPresent, true)
      console.log('M-T07 ' + mode + ' persistent Session survives restart')
    }
    await checkRetained(port, mode)
  } finally {
    if (running.child.exitCode === null) await stopBroker(running)
  }
}
async function runTransportMatrix() {
  const dir = path.join(evidenceRoot, 'transports')
  fs.mkdirSync(dir, { recursive: true })
  const ports = {
    tcp: await freePort(), tls: await freePort(),
    ws: await freePort(), wss: await freePort()
  }
  const cert = path.join(dir, 'server.crt')
  const key = path.join(dir, 'server.key')
  const generated = spawnSync('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-sha256', '-nodes',
    '-days', '1', '-subj', '/CN=localhost',
    '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
    '-keyout', key, '-out', cert
  ], { stdio: 'ignore' })
  assert.equal(generated.status, 0, 'TLS certificate generation failed')
  const config = path.join(dir, 'config.toml')
  const lines = [
    '[persistence]', 'mode = "strict"',
    'data_dir = ' + JSON.stringify(path.join(dir, 'data')),
    '[server]', 'max_connections = 128',
    '[protocol]', 'mqtt5_enabled = true'
  ]
  for (const transport of ['tcp', 'tls', 'ws', 'wss']) {
    lines.push('[[listeners]]')
    lines.push('id = ' + JSON.stringify(transport))
    lines.push('transport = ' + JSON.stringify(transport))
    lines.push('listen = ' + JSON.stringify('127.0.0.1:' + ports[transport]))
    lines.push('max_connections = 32')
    if (transport === 'tls' || transport === 'wss') {
      lines.push('tls_cert = ' + JSON.stringify(cert))
      lines.push('tls_key = ' + JSON.stringify(key))
    }
  }
  fs.writeFileSync(config, lines.join('\n') + '\n')
  const running = await startBroker(
    'strict', ports.tcp, path.join(dir, 'data'),
    path.join(dir, 'broker.log'), [brokerPath, '--config', config]
  )
  const ca = fs.readFileSync(cert)
  const urls = {
    tcp: 'mqtt://127.0.0.1:' + ports.tcp,
    tls: 'mqtts://127.0.0.1:' + ports.tls,
    ws: 'ws://127.0.0.1:' + ports.ws + '/mqtt',
    wss: 'wss://127.0.0.1:' + ports.wss + '/mqtt'
  }
  const pairs = [['tcp', 'tls'], ['tls', 'ws'], ['ws', 'wss'], ['wss', 'tcp']]
  try {
    for (let index = 0; index < pairs.length; index++) {
      const [subscriberTransport, publisherTransport] = pairs[index]
      const opts = transport => ({
        clientId: 'mqtt5-transport-' + transport + '-' + index,
        ...(transport === 'tls' || transport === 'wss'
          ? { ca, rejectUnauthorized: true } : {})
      })
      const [subscriber] = await connectAt(
        urls[subscriberTransport], opts(subscriberTransport)
      )
      const [publisher] = await connectAt(
        urls[publisherTransport], opts(publisherTransport)
      )
      try {
        const topic = 'mqtt5/transports/' + index
        await subscribe(subscriber, topic, { qos: 1 })
        const message = nextMessage(subscriber)
        await publish(publisher, topic, 'across', {
          qos: 1, properties: { contentType: 'text/plain' }
        })
        const received = await message
        assert.equal(received.payload, 'across')
        assert.equal(received.packet.properties.contentType, 'text/plain')
        console.log('M-T08 MQTT5 ' + publisherTransport + ' -> ' + subscriberTransport)
      } finally {
        await closeClient(publisher)
        await closeClient(subscriber)
      }
    }
  } finally {
    if (running.child.exitCode === null) await stopBroker(running)
  }
}
try {
  for (const mode of ['off', 'snapshot', 'strict']) await runMode(mode)
  await runTransportMatrix()
  console.log('MQTT5 integration matrix passed')
  console.log('MQTT5_EVIDENCE_DIR=' + evidenceRoot)
} catch (error) {
  console.error(error)
  console.error('MQTT5_EVIDENCE_DIR=' + evidenceRoot)
  process.exitCode = 1
}
