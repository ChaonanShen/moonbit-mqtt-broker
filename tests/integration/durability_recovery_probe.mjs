import assert from 'node:assert/strict'
import mqtt from 'mqtt'

const [mode, url, expected = 'committed-marker'] = process.argv.slice(2)
assert.ok(['seed', 'verify'].includes(mode) && url)
const client = mqtt.connect(url, {
  clientId: 'durability-perf-recovery-' + mode, clean: true,
  protocolVersion: 4, reconnectPeriod: 0, connectTimeout: 5000
})
const timeout = setTimeout(() => {
  console.error('PERFORMANCE_RECOVERY_TIMEOUT')
  process.exit(124)
}, 10000)
try {
  await new Promise((resolve, reject) => {
    client.once('connect', resolve)
    client.once('error', reject)
  })
  if (mode === 'seed') {
    await new Promise((resolve, reject) => client.publish(
      'durability/performance/recovery', expected,
      { qos: 1, retain: true }, error => error ? reject(error) : resolve()))
  } else {
    const message = new Promise((resolve, reject) => client.once(
      'message', (topic, payload) => {
        try {
          assert.equal(topic, 'durability/performance/recovery')
          assert.equal(payload.toString(), expected)
          resolve()
        } catch (error) { reject(error) }
      }))
    await new Promise((resolve, reject) => client.subscribe(
      'durability/performance/recovery', { qos: 1 },
      error => error ? reject(error) : resolve()))
    await message
  }
  console.log('PERFORMANCE_RECOVERY_' + mode.toUpperCase() + '_PASS')
} finally {
  clearTimeout(timeout)
  client.end(true)
}
