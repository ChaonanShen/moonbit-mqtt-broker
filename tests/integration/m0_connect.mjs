import mqtt from 'mqtt'

const url = process.argv[2]
if (!url) throw new Error('usage: node m0_connect.mjs mqtt://HOST:PORT')

await new Promise((resolve, reject) => {
  const client = mqtt.connect(url, {
    clientId: 'm0-mqttjs-smoke',
    protocolVersion: 4,
    clean: true,
    keepalive: 5,
    reconnectPeriod: 0,
    connectTimeout: 3000
  })
  const timer = setTimeout(() => {
    client.destroy()
    reject(new Error('MQTT.js CONNECT smoke timed out'))
  }, 5000)
  client.once('error', error => {
    clearTimeout(timer)
    reject(error)
  })
  client.once('connect', packet => {
    if (packet.returnCode !== 0) {
      clearTimeout(timer)
      client.destroy()
      reject(new Error(`unexpected CONNACK return code ${packet.returnCode}`))
      return
    }
    client.end(false, {}, () => {
      clearTimeout(timer)
      resolve()
    })
  })
})

console.log('MQTT.js received accepted MQTT 3.1.1 CONNACK')
