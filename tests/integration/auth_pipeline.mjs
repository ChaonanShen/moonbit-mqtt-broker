import fs from 'node:fs'
import tls from 'node:tls'
import mqttPacket from 'mqtt-packet'

const [portText, caPath, username, password] = process.argv.slice(2)
if (!portText || !caPath || !username || !password) {
  throw new Error('usage: node auth_pipeline.mjs PORT CA USERNAME PASSWORD')
}

const port = Number(portText)
const parser = mqttPacket.parser({ protocolVersion: 4 })
const observed = []
let settled = false

const socket = tls.connect({
  host: 'localhost',
  port,
  servername: 'localhost',
  ca: fs.readFileSync(caPath),
  rejectUnauthorized: true
})

const finish = error => {
  if (settled) return
  settled = true
  clearTimeout(timeout)
  socket.destroy()
  if (error) {
    console.error(error.stack ?? error)
    process.exitCode = 1
  } else {
    console.log('AUTH PIPELINE CONNECT+PUBLISH preserved CONNACK-before-PUBACK ordering')
  }
}

const timeout = setTimeout(
  () => finish(new Error(`pipeline timeout; observed=${JSON.stringify(observed)}`)),
  5000
)

parser.on('packet', packet => {
  observed.push(packet.cmd)
  if (packet.cmd === 'connack') {
    if (packet.returnCode !== 0) {
      finish(new Error(`expected accepted CONNACK, got ${packet.returnCode}`))
    }
    return
  }
  if (packet.cmd === 'puback') {
    if (packet.messageId !== 7) {
      finish(new Error(`unexpected PUBACK id ${packet.messageId}`))
      return
    }
    if (observed[0] !== 'connack') {
      finish(new Error(`business packet overtook CONNACK: ${observed.join(',')}`))
      return
    }
    finish()
  }
})
parser.on('error', finish)
socket.on('error', finish)
socket.on('data', chunk => parser.parse(chunk))
socket.on('secureConnect', () => {
  const connect = mqttPacket.generate({
    cmd: 'connect',
    protocolId: 'MQTT',
    protocolVersion: 4,
    clean: true,
    clientId: 'auth-pipeline-client',
    keepalive: 10,
    username,
    password: Buffer.from(password)
  })
  const publish = mqttPacket.generate({
    cmd: 'publish',
    qos: 1,
    dup: false,
    retain: false,
    topic: 'allowed/pipeline',
    messageId: 7,
    payload: Buffer.from('pipelined-after-connect')
  })
  socket.write(Buffer.concat([connect, publish]))
})
