import assert from 'node:assert/strict'
import fs from 'node:fs'
import http from 'node:http'

const token = fs.readFileSync('/artifact/management-client-token', 'utf8').trim()
assert.match(token, /^[A-Za-z0-9_-]+\.[0-9a-f]{64}$/)
const deadline = setTimeout(() => {
  console.error('management runtime smoke timed out')
  process.exit(1)
}, 15000)
function get(path, bearer) {
  return new Promise((resolve, reject) => {
    const req = http.get({
      host: '127.0.0.1', port: 9091, path,
      timeout: 2000, agent: false,
      headers: bearer ? { Authorization: `Bearer ${bearer}` } : {}
    }, res => {
      const chunks = []
      res.on('data', chunk => chunks.push(chunk))
      res.on('end', () => resolve({ status: res.statusCode,
        headers: res.headers, body: Buffer.concat(chunks).toString() }))
    })
    req.on('timeout', () => req.destroy(new Error('management timeout')))
    req.on('error', reject)
  })
}
try {
  let live
  for (let i = 0; i < 50; i++) {
    try {
      live = await get('/health/live')
      if (live.status === 200) break
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 100))
  }
  assert.equal(live?.status, 200)
  assert.equal((await get('/health/ready')).status, 200)
  const unauthorized = await get('/metrics')
  assert.equal(unauthorized.status, 401)
  assert.match(unauthorized.headers['www-authenticate'], /Bearer/)
  assert.equal((await get('/metrics', 'wrong.' + 'f'.repeat(64))).status, 401)
  const metrics = await get('/metrics', token)
  assert.equal(metrics.status, 200)
  assert.match(metrics.headers['content-type'], /^text\/plain; version=0\.0\.4/)
  assert.match(metrics.body, /moonbit_mqtt_broker_build_info\{version="0.3.0",target="native"\} 1/)
  const status = await get('/v1/status', token)
  assert.equal(status.status, 200)
  assert.equal(JSON.parse(status.body).api_version, '1')
  assert.ok(!status.body.includes(token))
  console.log('DISTRIBUTION management live/read/metrics smoke passed')
} finally {
  clearTimeout(deadline)
}
