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
async function openRawV5(port, clientId, properties = {}, clean = true) {
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
  const next = () => Promise.race([
    queue.length ? Promise.resolve(queue.shift()) :
      new Promise(resolve => { waiter = resolve }),
    sleep(5000).then(() => { throw new Error('raw MQTT5 timeout: ' + clientId) })
  ])
  await new Promise(resolve => socket.once('connect', resolve))
  const send = packet => socket.write(mqttPacket.generate(
    packet, { protocolVersion: 5 }
  ))
  send({
    cmd: 'connect', protocolVersion: 5, clientId, clean,
    keepalive: 10, properties
  })
  const ack = await next()
  assert.equal(ack.cmd, 'connack')
  assert.equal(ack.reasonCode, 0)
  return { socket, parser, queue, next, send, ack }
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
    console.log('M-T11/M-T26 shared unavailable => SUBACK 9E')
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
        userProperties: { k: ['v1', 'v2'] }
      }
    })
    const received = await message
    assert.equal(received.topic, 'mqtt5/core')
    assert.equal(received.payload, 'payload')
    assert.equal(received.packet.retain, true)
    assert.equal(received.packet.properties.contentType, 'text/plain')
    assert.deepEqual(received.packet.properties.userProperties.k, ['v1', 'v2'])
    assert.equal(received.packet.properties.subscriptionIdentifier, 7)
    let selfReceived = false
    subscriber.once('message', () => { selfReceived = true })
    await publish(subscriber, 'mqtt5/core', 'self', { qos: 1 })
    await sleep(150)
    assert.equal(selfReceived, false)
    console.log('M-T06/M-T09/M-T10/M-T12 ' + mode + ' QoS2 metadata NoLocal RAP RH SID')
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
  console.log('M-T07/M-T13 ' + mode + ' persistent Session resumes')
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
    assert.deepEqual(received.packet.properties.userProperties.k, ['v1', 'v2'])
    console.log('M-T12/M-T13 ' + mode + ' retained metadata replay')
  } finally {
    await closeClient(client)
  }
}
async function checkSmallPeer(port, mode) {
  const id = 'mqtt5-small-' + mode
  const options = maximumPacketSize => ({
    clientId: id,
    clean: false,
    properties: { sessionExpiryInterval: 30, maximumPacketSize }
  })
  let [subscriber, ack] = await connectClient(port, options(40))
  assert.equal(ack.sessionPresent, false)
  let received = 0
  subscriber.on('message', () => { received++ })
  await subscribe(subscriber, 'mqtt5/small', { qos: 1 })
  const [publisher] = await connectClient(port, {
    clientId: 'mqtt5-small-pub-' + mode
  })
  try {
    await publish(publisher, 'mqtt5/small', 'x'.repeat(120), { qos: 1 })
    await sleep(200)
    assert.equal(received, 0)
    assert.equal(subscriber.connected, true)
    await closeClient(subscriber)
    ;[subscriber, ack] = await connectClient(port, options(1000))
    assert.equal(ack.sessionPresent, true)
    subscriber.on('message', () => { received++ })
    await sleep(200)
    assert.equal(received, 0)
    console.log('M-T19 ' + mode + ' oversized fresh copy discarded')
  } finally {
    await closeClient(subscriber)
    await closeClient(publisher)
  }
}
async function checkReplayTooLarge(port) {
  async function rawSubscriber(maximumPacketSize) {
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
    const next = () => Promise.race([
      queue.length ? Promise.resolve(queue.shift()) :
        new Promise(resolve => { waiter = resolve }),
      sleep(5000).then(() => { throw new Error('replay packet timeout') })
    ])
    await new Promise(resolve => socket.once('connect', resolve))
    const send = packet => socket.write(mqttPacket.generate(
      packet, { protocolVersion: 5 }
    ))
    send({
      cmd: 'connect', protocolVersion: 5,
      clientId: 'mqtt5-replay-small', clean: false, keepalive: 10,
      properties: { sessionExpiryInterval: 30, maximumPacketSize }
    })
    const ack = await next()
    assert.equal(ack.cmd, 'connack')
    assert.equal(ack.reasonCode, 0)
    return { socket, next, send, ack }
  }
  let subscriber = await rawSubscriber(1000)
  assert.equal(subscriber.ack.sessionPresent, false)
  subscriber.send({
    cmd: 'subscribe', messageId: 1,
    subscriptions: [{ topic: 'mqtt5/replay-size', qos: 1 }],
    properties: {}
  })
  assert.equal((await subscriber.next()).cmd, 'suback')
  const [publisher] = await connectClient(port, {
    clientId: 'mqtt5-replay-publisher'
  })
  try {
    const first = subscriber.next()
    await publish(publisher, 'mqtt5/replay-size', 'y'.repeat(120), {
      qos: 1
    })
    const original = await first
    assert.equal(original.cmd, 'publish')
    assert.equal(original.dup, false)
    subscriber.socket.destroy()
    await sleep(100)
    subscriber = await rawSubscriber(40)
    assert.equal(subscriber.ack.sessionPresent, true)
    const denied = await subscriber.next()
    assert.equal(denied.cmd, 'disconnect')
    assert.equal(denied.reasonCode, 0x95)
    subscriber.socket.destroy()
    await sleep(100)
    subscriber = await rawSubscriber(1000)
    assert.equal(subscriber.ack.sessionPresent, true)
    const replay = await subscriber.next()
    assert.equal(replay.cmd, 'publish')
    assert.equal(replay.dup, true)
    assert.equal(replay.messageId, original.messageId)
    assert.equal(replay.payload.toString(), original.payload.toString())
    subscriber.send({
      cmd: 'puback', messageId: replay.messageId,
      reasonCode: 0, properties: {}
    })
    subscriber.socket.destroy()
    console.log('M-T19 strict oversized inflight closes 95 and replays')
  } finally {
    subscriber.socket.destroy()
    await closeClient(publisher)
  }
}
async function checkPayloadFormat(port) {
  const source = await openRawV5(port, 'mqtt5-pfi-invalid')
  source.send({
    cmd: 'publish', topic: 'mqtt5/pfi',
    payload: Buffer.from([0xff]), qos: 1, messageId: 1,
    properties: { payloadFormatIndicator: true }
  })
  const negative = await source.next()
  assert.equal(negative.cmd, 'puback')
  assert.equal(negative.reasonCode, 0x99)
  source.send({
    cmd: 'publish', topic: 'mqtt5/pfi',
    payload: Buffer.from([0xff]), qos: 2, messageId: 2,
    properties: { payloadFormatIndicator: true }
  })
  const negativeQos2 = await source.next()
  assert.equal(negativeQos2.cmd, 'pubrec')
  assert.equal(negativeQos2.reasonCode, 0x99)
  source.send({
    cmd: 'pubrel', messageId: 2,
    reasonCode: 0, properties: {}
  })
  const unknown = await source.next()
  assert.equal(unknown.cmd, 'pubcomp')
  assert.equal(unknown.reasonCode, 0x92)
  source.send({
    cmd: 'publish', topic: 'mqtt5/pfi',
    payload: Buffer.from([0xff]), qos: 0,
    properties: { payloadFormatIndicator: true }
  })
  const closed = await source.next()
  assert.equal(closed.cmd, 'disconnect')
  assert.equal(closed.reasonCode, 0x99)
  source.socket.destroy()
  const badWill = await rawPacket(port, mqttPacket.generate({
    cmd: 'connect', protocolVersion: 5,
    clientId: 'mqtt5-pfi-will', clean: true, keepalive: 10,
    properties: {},
    will: {
      topic: 'mqtt5/pfi-will', payload: Buffer.from([0xff]),
      qos: 0, properties: { payloadFormatIndicator: true }
    }
  }, { protocolVersion: 5 }))
  assert.equal(badWill.cmd, 'connack')
  assert.equal(badWill.reasonCode, 0x99)
  console.log('M-T12 malformed UTF-8 payload and Will return 99')
}
async function checkAssignedIdAndConnackBudget(port) {
  const assigned = async () => rawPacket(port, mqttPacket.generate({
    cmd: 'connect', protocolVersion: 5, clientId: '',
    clean: true, keepalive: 10, properties: {}
  }, { protocolVersion: 5 }))
  const first = await assigned()
  const second = await assigned()
  assert.equal(first.reasonCode, 0)
  assert.equal(second.reasonCode, 0)
  assert.match(first.properties.assignedClientIdentifier, /^mb5-[0-9a-f]{32}$/)
  assert.notEqual(
    first.properties.assignedClientIdentifier,
    second.properties.assignedClientIdentifier
  )
  const old = await openRawV5(
    port, 'mqtt5-budget-preserved',
    { sessionExpiryInterval: 30 }, false
  )
  const rejected = await rawPacket(port, mqttPacket.generate({
    cmd: 'connect', protocolVersion: 5,
    clientId: 'mqtt5-budget-preserved',
    clean: true, keepalive: 10,
    properties: { maximumPacketSize: 5 }
  }, { protocolVersion: 5 }))
  assert.equal(rejected.cmd, 'connack')
  assert.equal(rejected.reasonCode, 0x88)
  old.send({ cmd: 'pingreq' })
  assert.equal((await old.next()).cmd, 'pingresp')
  old.socket.destroy()
  console.log('M-T04/M-T19 assigned ID and CONNACK preflight preserve owner')
}
async function checkSubackBudget(port) {
  async function open(maximumPacketSize) {
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
    const next = () => Promise.race([
      queue.length ? Promise.resolve(queue.shift()) :
        new Promise(resolve => { waiter = resolve }),
      sleep(5000).then(() => { throw new Error('SUBACK budget timeout') })
    ])
    await new Promise(resolve => socket.once('connect', resolve))
    const send = packet => socket.write(mqttPacket.generate(
      packet, { protocolVersion: 5 }
    ))
    send({
      cmd: 'connect', protocolVersion: 5,
      clientId: 'mqtt5-suback-small', clean: false, keepalive: 10,
      properties: { sessionExpiryInterval: 30, maximumPacketSize }
    })
    const ack = await next()
    assert.equal(ack.reasonCode, 0)
    return { socket, parser, next, send, ack }
  }
  let subscriber = await open(26)
  assert.equal(subscriber.ack.sessionPresent, false)
  subscriber.send({
    cmd: 'subscribe', messageId: 1,
    subscriptions: Array.from({ length: 24 },
      (_, index) => ({ topic: 'mqtt5/suback/' + index, qos: 1 })),
    properties: {}
  })
  const rejection = await subscriber.next()
  assert.equal(rejection.cmd, 'disconnect')
  assert.equal(rejection.reasonCode, 0x95)
  subscriber.socket.destroy()
  subscriber = await open(1000)
  assert.equal(subscriber.ack.sessionPresent, true)
  let delivered = 0
  subscriber.parser.on('packet', packet => {
    if (packet.cmd === 'publish') delivered++
  })
  const [publisher] = await connectClient(port, {
    clientId: 'mqtt5-suback-publisher'
  })
  try {
    await publish(publisher, 'mqtt5/suback/0', 'unsubscribed', { qos: 1 })
    await sleep(200)
    assert.equal(delivered, 0)
    subscriber.send({
      cmd: 'subscribe', messageId: 2,
      subscriptions: Array.from({ length: 24 },
        (_, index) => ({ topic: 'mqtt5/suback/' + index, qos: 1 })),
      properties: {}
    })
    const accepted = await subscriber.next()
    assert.equal(accepted.cmd, 'suback')
    assert.equal(accepted.granted.length, 24)
    subscriber.socket.destroy()
    subscriber = await open(26)
    assert.equal(subscriber.ack.sessionPresent, true)
    subscriber.send({
      cmd: 'unsubscribe', messageId: 3,
      unsubscriptions: Array.from({ length: 24 },
        (_, index) => 'mqtt5/suback/' + index),
      properties: {}
    })
    const unsubscribeDenied = await subscriber.next()
    assert.equal(unsubscribeDenied.cmd, 'disconnect')
    assert.equal(unsubscribeDenied.reasonCode, 0x95)
    subscriber.socket.destroy()
    subscriber = await open(1000)
    assert.equal(subscriber.ack.sessionPresent, true)
    const stillSubscribed = subscriber.next()
    await publish(publisher, 'mqtt5/suback/0', 'still-subscribed', { qos: 1 })
    const deliveredPacket = await stillSubscribed
    assert.equal(deliveredPacket.cmd, 'publish')
    assert.equal(deliveredPacket.payload.toString(), 'still-subscribed')
    subscriber.send({
      cmd: 'puback', messageId: deliveredPacket.messageId,
      reasonCode: 0, properties: {}
    })
    console.log('M-T19 strict oversized SUBACK/UNSUBACK are atomic')
  } finally {
    subscriber.socket.destroy()
    await closeClient(publisher)
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
  console.log('M-T08/M-T13 ' + mode + ' MQTT3.1.1/MQTT5 Session crossover')
}
async function checkMessageExpiry(port, mode) {
  const [publisher] = await connectClient(port, {
    clientId: 'mqtt5-expiry-publisher-' + mode
  })
  const topic = 'mqtt5/expiry-retained/' + mode
  try {
    await publish(publisher, topic, 'old', { qos: 1, retain: true })
    await publish(publisher, topic, 'expired', {
      qos: 1, retain: true,
      properties: { messageExpiryInterval: 0 }
    })
    const [fresh] = await connectClient(port, {
      clientId: 'mqtt5-expiry-fresh-' + mode
    })
    let retained = 0
    fresh.on('message', () => { retained++ })
    await subscribe(fresh, topic, { qos: 1 })
    await sleep(150)
    assert.equal(retained, 0)
    await closeClient(fresh)
    const offline = await openRawV5(
      port, 'mqtt5-expiry-offline-' + mode,
      { sessionExpiryInterval: 30 }, false
    )
    offline.send({
      cmd: 'subscribe', messageId: 1,
      subscriptions: [{ topic: 'mqtt5/expiry-queue/' + mode, qos: 1 }],
      properties: {}
    })
    assert.equal((await offline.next()).cmd, 'suback')
    offline.socket.destroy()
    await sleep(100)
    await publish(
      publisher, 'mqtt5/expiry-queue/' + mode, 'short',
      { qos: 1, properties: { messageExpiryInterval: 1 } }
    )
    await publish(
      publisher, 'mqtt5/expiry-natural/' + mode, 'retained',
      { qos: 1, retain: true, properties: { messageExpiryInterval: 1 } }
    )
    await sleep(1300)
    const resumed = await openRawV5(
      port, 'mqtt5-expiry-offline-' + mode,
      { sessionExpiryInterval: 30 }, false
    )
    assert.equal(resumed.ack.sessionPresent, true)
    await sleep(150)
    assert.equal(resumed.queue.some(packet => packet.cmd === 'publish'), false)
    resumed.socket.destroy()
    const [late] = await connectClient(port, {
      clientId: 'mqtt5-expiry-late-' + mode
    })
    let natural = 0
    late.on('message', () => { natural++ })
    await subscribe(late, 'mqtt5/expiry-natural/' + mode, { qos: 1 })
    await sleep(150)
    assert.equal(natural, 0)
    await closeClient(late)
    console.log('M-T14/M-T15 ' + mode + ' message expiry and retained cleanup')
  } finally {
    await closeClient(publisher)
  }
}
async function checkAlias(port, mode) {
  const topic = 'mqtt5/alias'
  const [subscriber] = await connectClient(port, {
    clientId: 'mqtt5-alias-listener-' + mode
  })
  await subscribe(subscriber, topic, { qos: 1 })
  const inbound = await openRawV5(port, 'mqtt5-alias-source-' + mode)
  try {
    let message = nextMessage(subscriber)
    inbound.send({
      cmd: 'publish', topic, payload: Buffer.from('first'),
      qos: 0, properties: { topicAlias: 1 }
    })
    assert.equal((await message).payload, 'first')
    message = nextMessage(subscriber)
    inbound.send({
      cmd: 'publish', topic: '', payload: Buffer.from('second'),
      qos: 0, properties: { topicAlias: 1 }
    })
    assert.equal((await message).payload, 'second')
    inbound.send({
      cmd: 'publish', topic: '', payload: Buffer.from('bad'),
      qos: 0, properties: { topicAlias: 2 }
    })
    const bad = await inbound.next()
    assert.equal(bad.cmd, 'disconnect')
    assert.equal(bad.reasonCode, 0x94)
  } finally {
    inbound.socket.destroy()
    await closeClient(subscriber)
  }
  const outbound = await openRawV5(
    port, 'mqtt5-alias-out-' + mode, { topicAliasMaximum: 1 }
  )
  outbound.send({
    cmd: 'subscribe', messageId: 1,
    subscriptions: [{ topic, qos: 1 }], properties: {}
  })
  assert.equal((await outbound.next()).cmd, 'suback')
  const [publisher] = await connectClient(port, {
    clientId: 'mqtt5-alias-pub-' + mode
  })
  try {
    await publish(publisher, topic, 'define', { qos: 1 })
    const first = await outbound.next()
    assert.equal(first.cmd, 'publish')
    assert.equal(first.topic, topic)
    assert.equal(first.properties.topicAlias, 1)
    outbound.send({
      cmd: 'puback', messageId: first.messageId,
      reasonCode: 0, properties: {}
    })
    await publish(publisher, topic, 'reuse', { qos: 1 })
    const second = await outbound.next()
    assert.equal(second.cmd, 'publish')
    assert.equal(second.topic, '')
    assert.equal(second.properties.topicAlias, 1)
    outbound.send({
      cmd: 'puback', messageId: second.messageId,
      reasonCode: 0, properties: {}
    })
    console.log('M-T20 ' + mode + ' inbound/outbound Topic Alias')
  } finally {
    outbound.socket.destroy()
    await closeClient(publisher)
  }
}
async function checkTxWindow(port, mode) {
  const subscriber = await openRawV5(
    port, 'mqtt5-tx-' + mode, { receiveMaximum: 1 }
  )
  subscriber.send({
    cmd: 'subscribe', messageId: 1,
    subscriptions: [{ topic: 'mqtt5/window', qos: 1 }],
    properties: {}
  })
  assert.equal((await subscriber.next()).cmd, 'suback')
  const [publisher] = await connectClient(port, {
    clientId: 'mqtt5-tx-publisher-' + mode
  })
  let received = 0
  subscriber.parser.on('packet', packet => {
    if (packet.cmd === 'publish') received++
  })
  try {
    const first = subscriber.next()
    const publications = [
      publish(publisher, 'mqtt5/window', 'one', { qos: 1 }),
      publish(publisher, 'mqtt5/window', 'two', { qos: 1 })
    ]
    const packet = await first
    assert.equal(packet.cmd, 'publish')
    await sleep(200)
    assert.equal(received, 1)
    subscriber.send({
      cmd: 'puback', messageId: packet.messageId,
      reasonCode: 0, properties: {}
    })
    const second = await subscriber.next()
    assert.equal(second.cmd, 'publish')
    subscriber.send({
      cmd: 'puback', messageId: second.messageId,
      reasonCode: 0, properties: {}
    })
    await Promise.all(publications)
    console.log('M-T17/M-T18 ' + mode + ' peer Receive Maximum 1')
  } finally {
    subscriber.socket.destroy()
    await closeClient(publisher)
  }
}
async function checkFiniteExpiry(port, mode) {
  const options = {
    clientId: 'mqtt5-expiring-' + mode, clean: false,
    properties: { sessionExpiryInterval: 1 }
  }
  let [client, ack] = await connectClient(port, options)
  assert.equal(ack.sessionPresent, false)
  await subscribe(client, 'mqtt5/expiry', { qos: 1 })
  await closeClient(client)
  ;[client, ack] = await connectClient(port, options)
  assert.equal(ack.sessionPresent, true)
  await closeClient(client)
  await sleep(1300)
  ;[client, ack] = await connectClient(port, options)
  assert.equal(ack.sessionPresent, false)
  await closeClient(client)
  console.log('M-T07/M-T14 ' + mode + ' finite Session Expiry')
}
async function checkDisconnectExpiry(port, mode) {
  const invalid = await openRawV5(
    port, 'mqtt5-expiry-invalid-' + mode,
    { sessionExpiryInterval: 0 }, false
  )
  invalid.send({
    cmd: 'disconnect', reasonCode: 0,
    properties: { sessionExpiryInterval: 1 }
  })
  const rejected = await invalid.next()
  assert.equal(rejected.cmd, 'disconnect')
  assert.equal(rejected.reasonCode, 0x82)
  invalid.socket.destroy()
  const id = 'mqtt5-expiry-override-' + mode
  const finite = await openRawV5(
    port, id, { sessionExpiryInterval: 30 }, false
  )
  finite.send({
    cmd: 'disconnect', reasonCode: 0,
    properties: { sessionExpiryInterval: 1 }
  })
  await sleep(150)
  finite.socket.destroy()
  await sleep(1300)
  const resumed = await openRawV5(
    port, id, { sessionExpiryInterval: 30 }, false
  )
  assert.equal(resumed.ack.sessionPresent, false)
  resumed.socket.destroy()
  console.log('M-T08 ' + mode + ' DISCONNECT Session Expiry override')
}
async function checkWillDelay(port) {
  const [subscriber] = await connectClient(port, {
    clientId: 'mqtt5-will-observer'
  })
  await subscribe(subscriber, 'mqtt5/will', { qos: 1 })
  const [source] = await connectClient(port, {
    clientId: 'mqtt5-will-source', clean: false,
    properties: { sessionExpiryInterval: 5 },
    will: {
      topic: 'mqtt5/will', payload: 'offline', qos: 1,
      properties: { willDelayInterval: 1, contentType: 'text/plain' }
    }
  })
  const started = Date.now()
  const delivered = nextMessage(subscriber, 4000)
  source.stream.destroy()
  await sleep(350)
  const received = await delivered
  assert.equal(received.payload, 'offline')
  assert.equal(received.packet.properties.contentType, 'text/plain')
  assert.ok(Date.now() - started >= 800)
  await closeClient(subscriber)
  console.log('M-T21/M-T22/M-T23 strict delayed Will')
}
async function checkWillCancellation(port) {
  const topic = 'mqtt5/will-cancel'
  const [observer] = await connectClient(port, {
    clientId: 'mqtt5-will-cancel-observer'
  })
  let received = 0
  observer.on('message', () => { received++ })
  await subscribe(observer, topic, { qos: 1 })
  const will = delay => ({
    topic, payload: 'must-not-publish', qos: 1,
    properties: { willDelayInterval: delay }
  })
  try {
    const [normal] = await connectClient(port, {
      clientId: 'mqtt5-will-normal', clean: false,
      properties: { sessionExpiryInterval: 5 },
      will: will(1)
    })
    await closeClient(normal)
    await sleep(1200)
    assert.equal(received, 0)
    const [abnormal] = await connectClient(port, {
      clientId: 'mqtt5-will-resumed', clean: false,
      properties: { sessionExpiryInterval: 5 },
      will: will(2)
    })
    abnormal.stream.destroy()
    await sleep(350)
    const [resumed, ack] = await connectClient(port, {
      clientId: 'mqtt5-will-resumed', clean: false,
      properties: { sessionExpiryInterval: 5 }
    })
    assert.equal(ack.sessionPresent, true)
    await sleep(2200)
    assert.equal(received, 0)
    await closeClient(resumed)
    console.log('M-T21/M-T22 normal and resumed Will cancellation')
  } finally {
    await closeClient(observer)
  }
}
async function checkWillTakeoverAndDisconnect04(port) {
  const [observer] = await connectClient(port, {
    clientId: 'mqtt5-will-special-observer'
  })
  await subscribe(observer, 'mqtt5/will-special/#', { qos: 1 })
  try {
    const takeoverMessage = nextMessage(observer)
    const [old] = await connectClient(port, {
      clientId: 'mqtt5-will-takeover', clean: false,
      properties: { sessionExpiryInterval: 5 },
      will: {
        topic: 'mqtt5/will-special/takeover',
        payload: 'old', qos: 1,
        properties: { willDelayInterval: 0 }
      }
    })
    const [replacement, ack] = await connectClient(port, {
      clientId: 'mqtt5-will-takeover', clean: false,
      properties: { sessionExpiryInterval: 5 }
    })
    assert.equal(ack.sessionPresent, true)
    const first = await takeoverMessage
    assert.equal(first.topic, 'mqtt5/will-special/takeover')
    assert.equal(first.payload, 'old')
    old.stream.destroy()
    await closeClient(replacement)
    const disconnectMessage = nextMessage(observer)
    const [source] = await connectClient(port, {
      clientId: 'mqtt5-will-disconnect04', clean: false,
      properties: { sessionExpiryInterval: 5 },
      will: {
        topic: 'mqtt5/will-special/disconnect04',
        payload: 'requested', qos: 1,
        properties: { willDelayInterval: 0 }
      }
    })
    source.stream.write(mqttPacket.generate({
      cmd: 'disconnect', reasonCode: 0x04, properties: {}
    }, { protocolVersion: 5 }))
    const second = await disconnectMessage
    assert.equal(second.topic, 'mqtt5/will-special/disconnect04')
    assert.equal(second.payload, 'requested')
    source.stream.destroy()
    console.log('M-T21/M-T22 takeover and DISCONNECT 04 trigger Will')
  } finally {
    await closeClient(observer)
  }
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
    await checkMessageExpiry(port, mode)
    if (mode !== 'snapshot') await checkAlias(port, mode)
    await checkTxWindow(port, mode)
    await checkSmallPeer(port, mode)
    if (mode === 'strict') {
      await checkReplayTooLarge(port)
      await checkPayloadFormat(port)
      await checkAssignedIdAndConnackBudget(port)
      await checkSubackBudget(port)
    }
    await checkSession(port, mode)
    await checkFiniteExpiry(port, mode)
    await checkDisconnectExpiry(port, mode)
    await checkCrossVersion(port, mode)
    if (mode === 'strict') {
      await checkWillDelay(port)
      await checkWillCancellation(port)
      await checkWillTakeoverAndDisconnect04(port)
    }
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
      console.log('M-T07/M-T13 ' + mode + ' persistent Session survives restart')
    }
    await checkRetained(port, mode)
  } finally {
    if (running.child.exitCode === null) await stopBroker(running)
  }
}
async function runReceiveLimit() {
  const port = await freePort()
  const dir = path.join(evidenceRoot, 'receive-limit')
  fs.mkdirSync(dir, { recursive: true })
  const running = await startBroker(
    'off', port, '', path.join(dir, 'broker.log'),
    [brokerPath, '--listen', '127.0.0.1:' + port,
      '--mqtt5-enabled', 'true',
      '--mqtt5-server-receive-maximum', '1',
      '--mqtt5-server-keep-alive', '0']
  )
  const packet = id => ({
    cmd: 'publish', topic: 'mqtt5/receive', payload: Buffer.from('x'),
    qos: 1, messageId: id, properties: {}
  })
  try {
    const sequential = await openRawV5(port, 'mqtt5-receive-sequential')
    assert.equal(sequential.ack.properties.receiveMaximum, 1)
    assert.equal(sequential.ack.properties.serverKeepAlive, 0)
    sequential.send(packet(1))
    const first = await sequential.next()
    assert.equal(first.cmd, 'puback')
    assert.equal(first.messageId, 1)
    sequential.send(packet(2))
    const second = await sequential.next()
    assert.equal(second.cmd, 'puback')
    assert.equal(second.messageId, 2)
    sequential.socket.destroy()
    const overrun = await openRawV5(port, 'mqtt5-receive-overrun')
    overrun.socket.write(Buffer.concat([
      mqttPacket.generate(packet(1), { protocolVersion: 5 }),
      mqttPacket.generate(packet(2), { protocolVersion: 5 })
    ]))
    let rejected = false
    for (let index = 0; index < 3; index++) {
      const answer = await overrun.next()
      if (answer.cmd === 'disconnect' && answer.reasonCode === 0x93) {
        rejected = true
        break
      }
    }
    assert.equal(rejected, true)
    overrun.socket.destroy()
    console.log('M-T17/M-T18 server Receive Maximum 1 and coalesced 93')
  } finally {
    await stopBroker(running)
  }
}
async function runAuthentication() {
  const port = await freePort()
  const dir = path.join(evidenceRoot, 'authentication')
  fs.mkdirSync(dir, { recursive: true })
  const hashed = spawnSync('argon2', [
    'mqtt5-auth-salt1', '-id', '-e', '-t', '2', '-m', '12', '-p', '1'
  ], { input: 'mqtt5-secret', encoding: 'utf8' })
  assert.equal(hashed.status, 0, 'Argon2 fixture failed')
  const passwordFile = path.join(dir, 'passwords')
  fs.writeFileSync(passwordFile, 'alice:' + hashed.stdout.trim() + '\n', {
    mode: 0o600
  })
  const running = await startBroker(
    'off', port, '', path.join(dir, 'broker.log'),
    [brokerPath, '--listen', '127.0.0.1:' + port,
      '--mqtt5-enabled', 'true', '--allow-anonymous', 'false',
      '--password-file', passwordFile]
  )
  try {
    const [client] = await connectClient(port, {
      clientId: 'mqtt5-auth-success',
      username: 'alice', password: 'mqtt5-secret'
    })
    await closeClient(client)
    await assert.rejects(connectClient(port, {
      clientId: 'mqtt5-auth-wrong',
      username: 'alice', password: 'wrong'
    }), error => error.code === 0x86)
    await assert.rejects(connectClient(port, {
      clientId: 'mqtt5-auth-anonymous'
    }), error => error.code === 0x87)
    const unsupported = await rawPacket(port, mqttPacket.generate({
      cmd: 'connect', protocolVersion: 5,
      clientId: 'mqtt5-auth-method', clean: true, keepalive: 10,
      properties: { authenticationMethod: 'unsupported' }
    }, { protocolVersion: 5 }))
    assert.equal(unsupported.cmd, 'connack')
    assert.equal(unsupported.reasonCode, 0x8c)
    console.log('M-T05/M-T26 MQTT5 password and Enhanced Auth boundary')
  } finally {
    await stopBroker(running)
  }
}
async function runWillCrashRecovery() {
  const port = await freePort()
  const dir = path.join(evidenceRoot, 'will-crash')
  fs.mkdirSync(dir, { recursive: true })
  const dataDir = path.join(dir, 'data')
  const logPath = path.join(dir, 'broker.log')
  let running = await startBroker('strict', port, dataDir, logPath)
  try {
    const [source] = await connectClient(port, {
      clientId: 'mqtt5-crash-will-source',
      clean: false,
      properties: { sessionExpiryInterval: 5 },
      will: {
        topic: 'mqtt5/crash-will',
        payload: 'offline', qos: 1, retain: true,
        properties: { willDelayInterval: 1, contentType: 'text/plain' }
      }
    })
    const crashed = running
    running = null
    const closed = new Promise(resolve => crashed.child.once('close', resolve))
    crashed.child.kill('SIGKILL')
    await closed
    await new Promise(resolve => crashed.log.end(resolve))
    source.stream.destroy()
    running = await startBroker('strict', port, dataDir, logPath)
    await sleep(600)
    const pending = running
    running = null
    const pendingClosed = new Promise(resolve => pending.child.once('close', resolve))
    pending.child.kill('SIGKILL')
    await pendingClosed
    await new Promise(resolve => pending.log.end(resolve))
    running = await startBroker('strict', port, dataDir, logPath)
    const secondRestartAt = Date.now()
    await sleep(550)
    const [observer] = await connectClient(port, {
      clientId: 'mqtt5-crash-will-observer'
    })
    const delivered = nextMessage(observer)
    await subscribe(observer, 'mqtt5/crash-will', { qos: 1 })
    const message = await delivered
    assert.equal(message.payload, 'offline')
    assert.equal(message.packet.retain, true)
    assert.equal(message.packet.properties.contentType, 'text/plain')
    assert.ok(
      Date.now() - secondRestartAt < 900,
      'pending Will deadline restarted after a second crash'
    )
    await closeClient(observer)
    console.log('M-T23 strict armed/pending Will survives repeated SIGKILL')
  } finally {
    if (running && running.child.exitCode === null) await stopBroker(running)
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
        console.log('M-T01/M-T15 MQTT5 ' + publisherTransport + ' -> ' + subscriberTransport)
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
  await runReceiveLimit()
  await runAuthentication()
  await runWillCrashRecovery()
  console.log('MQTT5 integration matrix passed')
  console.log('MQTT5_EVIDENCE_DIR=' + evidenceRoot)
} catch (error) {
  console.error(error)
  console.error('MQTT5_EVIDENCE_DIR=' + evidenceRoot)
  process.exitCode = 1
}
