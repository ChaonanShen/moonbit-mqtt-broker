import { mkdir, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import mqttPacket from 'mqtt-packet'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const fixtureDir = path.join(root, 'tests/fixtures/codec')

function hex(packet) {
  return mqttPacket.generate(packet, { protocolVersion: 4 }).toString('hex')
}

function valid(id, direction, packetType, packet) {
  return JSON.stringify({ id, direction, packet_type: packetType, hex: hex(packet) })
}

const vectors = []
for (let i = 0; i < 150; i++) {
  const withAuth = i % 3 === 0
  const withWill = i % 4 === 0
  vectors.push(valid(`connect-${i}`, 'client_to_server', 'connect', {
    cmd: 'connect', protocolId: 'MQTT', protocolVersion: 4,
    clean: i % 2 === 0, clientId: `client-${i}`, keepalive: i % 121,
    ...(withAuth ? { username: `user-${i % 7}`, password: Buffer.from([i & 255, 0, 255]) } : {}),
    ...(withWill ? { will: { topic: `will/${i % 11}`, payload: Buffer.from(`offline-${i}`), qos: i % 2, retain: i % 5 === 0 } } : {})
  }))
}
for (let i = 0; i < 100; i++) {
  vectors.push(valid(`connack-${i}`, 'server_to_client', 'connack', {
    cmd: 'connack', sessionPresent: i % 2 === 0, returnCode: 0
  }))
}
for (let i = 0; i < 250; i++) {
  const qos = i % 2
  vectors.push(valid(`publish-${i}`, i % 2 ? 'client_to_server' : 'server_to_client', 'publish', {
    cmd: 'publish', topic: `sensors/${i % 23}`, payload: Buffer.from([i & 255, (i >> 8) & 255, 0, 255]),
    qos, messageId: qos ? i + 1 : undefined, dup: qos === 1 && i % 3 === 0, retain: i % 7 === 0
  }))
}
for (let i = 0; i < 75; i++) {
  vectors.push(valid(`subscribe-${i}`, 'client_to_server', 'subscribe', {
    cmd: 'subscribe', messageId: i + 1, subscriptions: [
      { topic: `sensors/${i % 9}/+`, qos: 0 }, { topic: `alerts/${i % 5}/#`, qos: 1 }
    ]
  }))
}
for (let i = 0; i < 75; i++) {
  vectors.push(valid(`suback-${i}`, 'server_to_client', 'suback', {
    cmd: 'suback', messageId: i + 1, granted: [0, 1, 128]
  }))
}
for (let i = 0; i < 50; i++) {
  vectors.push(valid(`unsubscribe-${i}`, 'client_to_server', 'unsubscribe', {
    cmd: 'unsubscribe', messageId: i + 1, unsubscriptions: [`sensors/${i}/+`, `alerts/${i}/#`]
  }))
}
for (let i = 0; i < 50; i++) {
  vectors.push(valid(`unsuback-${i}`, 'server_to_client', 'unsuback', { cmd: 'unsuback', messageId: i + 1 }))
}
for (let i = 0; i < 100; i++) {
  vectors.push(valid(`puback-${i}`, i % 2 ? 'client_to_server' : 'server_to_client', 'puback', { cmd: 'puback', messageId: i + 1 }))
}
for (const [cmd, direction] of [['pingreq', 'client_to_server'], ['pingresp', 'server_to_client'], ['disconnect', 'client_to_server']]) {
  for (let i = 0; i < 50; i++) vectors.push(valid(`${cmd}-${i}`, direction, cmd, { cmd }))
}

if (vectors.length !== 1000) throw new Error(`expected 1000 vectors, got ${vectors.length}`)

const malformed = [
  ['truncated-header', 'c0', 'invalid_packet_shape'],
  ['remaining-length-five-bytes', '308080808000', 'invalid_remaining_length'],
  ['remaining-length-non-minimal', 'c08000', 'invalid_remaining_length'],
  ['pingreq-invalid-flags', 'c100', 'invalid_flags'],
  ['pingreq-trailing', 'c00000', 'trailing_bytes'],
  ['puback-zero-id', '40020000', 'invalid_packet_id'],
  ['puback-truncated-id', '400100', 'invalid_packet_shape'],
  ['connect-bad-protocol-name', '100c000358515404020000000161', 'invalid_protocol_name'],
  ['connect-bad-level', '100d00044d51545405020000000161', 'invalid_protocol_level'],
  ['connect-reserved-flag', '100d00044d51545404030000000161', 'invalid_flags'],
  ['connect-password-without-user', '101200044d51545404420000000161000378797a', 'invalid_flags'],
  ['connack-invalid-flags', '20020200', 'invalid_flags'],
  ['connack-bad-length', '200100', 'invalid_packet_shape'],
  ['publish-zero-id', '32050001610000', 'invalid_packet_id'],
  ['publish-qos2', '34050001610001', 'unsupported_qos'],
  ['publish-invalid-qos-bits', '3603000161', 'unsupported_qos'],
  ['publish-invalid-utf8', '30030001ff', 'invalid_utf8'],
  ['publish-nul-topic', '30050003610062', 'invalid_utf8'],
  ['publish-truncated-topic', '3003000261', 'invalid_packet_shape'],
  ['publish-wildcard-topic', '30050003612f23', 'invalid_packet_shape'],
  ['subscribe-empty', '82020001', 'invalid_packet_shape'],
  ['subscribe-zero-id', '8206000000016100', 'invalid_packet_id'],
  ['subscribe-invalid-flags', '80020001', 'invalid_flags'],
  ['subscribe-qos2', '8206000100016102', 'unsupported_qos'],
  ['suback-qos2', '9003000102', 'unsupported_qos'],
  ['unsubscribe-empty', 'a2020001', 'invalid_packet_shape'],
  ['unsubscribe-zero-id', 'a2050000000161', 'invalid_packet_id'],
  ['unsubscribe-invalid-flags', 'a0020001', 'invalid_flags'],
  ['unsupported-pubrec', '50020001', 'unsupported_packet_type']
].map(([id, bytes, expected_category]) => JSON.stringify({ id, hex: bytes, expected_category }))

await mkdir(fixtureDir, { recursive: true })
await writeFile(path.join(fixtureDir, 'valid-vectors.jsonl'), `${vectors.join('\n')}\n`)
await writeFile(path.join(fixtureDir, 'malformed-vectors.jsonl'), `${malformed.join('\n')}\n`)
