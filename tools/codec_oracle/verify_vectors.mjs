import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import mqttPacket from 'mqtt-packet'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const lines = (await readFile(path.join(root, 'tests/fixtures/codec/valid-vectors.jsonl'), 'utf8')).trim().split('\n')

function parse(buffer) {
  return new Promise((resolve, reject) => {
    const parser = mqttPacket.parser({ protocolVersion: 4 })
    parser.once('packet', resolve)
    parser.once('error', reject)
    parser.parse(buffer)
  })
}

for (const line of lines) {
  const vector = JSON.parse(line)
  const packet = await parse(Buffer.from(vector.hex, 'hex'))
  if (packet.cmd !== vector.packet_type) throw new Error(`${vector.id}: expected ${vector.packet_type}, got ${packet.cmd}`)
  const regenerated = mqttPacket.generate(packet, { protocolVersion: 4 }).toString('hex')
  if (regenerated !== vector.hex) throw new Error(`${vector.id}: non-canonical round trip`)
}
if (lines.length !== 1000) throw new Error(`expected 1000 vectors, got ${lines.length}`)
console.log(`verified ${lines.length} mqtt-packet@9.0.2 oracle vectors`)
