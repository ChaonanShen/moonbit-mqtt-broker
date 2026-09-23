import assert from 'node:assert/strict'
import net from 'node:net'
import http from 'node:http'
import { performance } from 'node:perf_hooks'
import mqtt from 'mqtt'
import { generate, parser as createParser } from 'mqtt-packet'

const [mode, mqttPortText, adminPortText, warmText = '10', measureText = '60'] = process.argv.slice(2)
const managed = mode === 'managed' || mode === 'overload'
assert.ok(['base', 'managed', 'overload'].includes(mode))
const mqttPort = Number(mqttPortText), adminPort = Number(adminPortText)
const warmMs = Number(warmText) * 1000, measureMs = Number(measureText) * 1000
const token = process.env.PERF_TOKEN || ''
const clients = []
const slowSockets = new Set()
const pingLatencies = [], ackLatencies = []
const pingsByWindow = Array(Math.ceil(measureMs / 5000)).fill(0)
let published = 0, delivered = 0, mgmtOk = 0, mgmtErrors = 0, rejected = 0, publishErrors = 0
let measureStart = Infinity, measureEnd = Infinity, stop = false
const waits = []
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
function percentile(values, p) {
  const sorted = [...values].sort((a,b) => a-b)
  return sorted.length ? sorted[Math.min(sorted.length-1, Math.floor(p*(sorted.length-1)))] : null
}
function connect(id) {
  return new Promise((resolve,reject) => {
    const client = mqtt.connect(`mqtt://127.0.0.1:${mqttPort}`, {
      clientId: `perf-${id}`, protocolVersion:4, clean:true, keepalive:30,
      reconnectPeriod:0, connectTimeout:3000
    })
    clients.push(client)
    client.once('connect', () => resolve(client))
    client.once('error', reject)
  })
}
function request(path, bearer) {
  return new Promise((resolve,reject) => {
    const req = http.get({ host:'127.0.0.1', port:adminPort, path,
      agent:false, timeout:2000,
      headers: bearer ? { Authorization:`Bearer ${bearer}` } : {}
    }, res => {
      res.resume()
      res.on('end', () => resolve(res.statusCode))
    })
    req.on('timeout', () => req.destroy(new Error('HTTP timeout')))
    req.on('error', reject)
  })
}
async function sendManagement(path, bearer) {
  try {
    const status = await request(path,bearer)
    if (status===200) mgmtOk++
    else if (status===401 || status===429) rejected++
    else mgmtErrors++
  } catch { mgmtErrors++ }
}
function slowReader() {
  if (stop) return
  const socket = net.createConnection(adminPort,'127.0.0.1')
  slowSockets.add(socket)
  socket.on('connect', () => socket.write('GET /health/live HTTP/1.1\r\nHost: '))
  socket.on('error', () => {})
  socket.on('close', () => {
    slowSockets.delete(socket)
    if (!stop) setTimeout(slowReader,100)
  })
}
function rawPinger() {
  return new Promise((resolve,reject) => {
    const socket = net.createConnection(mqttPort,'127.0.0.1')
    const parser = createParser()
    let pending = null
    let connected = false
    parser.on('packet', packet => {
      if (packet.cmd==='connack') { connected=true; resolve({ socket, ping() {
        if (pending!==null) return
        pending=performance.now()
        socket.write(generate({cmd:'pingreq'}))
      }}) }
      if (packet.cmd==='pingresp' && pending!==null) {
        const now=performance.now()
        if (now>=measureStart && now<measureEnd) {
          pingLatencies.push(now-pending)
          const bin=Math.floor((now-measureStart)/5000)
          if (bin>=0 && bin<pingsByWindow.length) pingsByWindow[bin]++
        }
        pending=null
      }
    })
    socket.on('data', chunk => parser.parse(chunk))
    socket.on('error', reject)
    socket.on('connect', () => socket.write(generate({
      cmd:'connect',protocolId:'MQTT',protocolVersion:4,clean:true,
      keepalive:30,clientId:'perf-ping'
    })))
    setTimeout(() => { if (!connected) reject(new Error('ping CONNACK timeout')) },3000).unref()
  })
}
let operationBusy = false, operationSequence = 0
function adminRequest(method,path,headers={}) {
  return new Promise((resolve,reject) => {
    const req=http.request({host:'127.0.0.1',port:adminPort,path,method,
      agent:false,timeout:2000,headers:{
        Authorization:'Bearer '+token,
        ...((method==='DELETE')?{'Content-Length':0}:{}),...headers
      }},res=>{
        const chunks=[]
        res.on('data',chunk=>chunks.push(chunk))
        res.on('end',()=>resolve({status:res.statusCode,body:Buffer.concat(chunks).toString()}))
      })
    req.on('timeout',()=>req.destroy(new Error('admin timeout')))
    req.on('error',reject);req.end()
  })
}
async function adminOperation() {
  operationBusy=true
  const name='perf-admin-'+operationSequence++
  try {
    const client=mqtt.connect('mqtt://127.0.0.1:'+mqttPort,{
      clientId:name,protocolVersion:4,clean:false,reconnectPeriod:0,connectTimeout:2000
    })
    await new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{
        client.end(true)
        reject(new Error('admin fixture MQTT connect timeout'))
      },2500)
      client.once('connect',()=>{clearTimeout(timer);resolve()})
      client.once('error',error=>{clearTimeout(timer);reject(error)})
    })
    await Promise.race([
      new Promise(resolve=>client.end(false,resolve)),
      delay(2500).then(()=>{throw new Error('admin fixture MQTT end timeout')})
    ])
    let row
    for(let i=0;i<20;i++){
      const result=await adminRequest('GET','/v1/sessions?attached=false&limit=100')
      if(result.status!==200) throw new Error('session query '+result.status)
      row=JSON.parse(result.body).items.find(item=>item.client_id===name)
      if(row) break
      await delay(10)
    }
    if(!row) throw new Error('offline session missing')
    const key='PerfDelete_'+String(operationSequence).padStart(10,'0')
    const accepted=await adminRequest('DELETE','/v1/sessions/'+row.handle,{
      'If-Match':row.etag,'Idempotency-Key':key
    })
    if(accepted.status!==202) throw new Error('delete '+accepted.status)
    const id=JSON.parse(accepted.body).operation_id
    let completed=false
    for(let i=0;i<100;i++){
      const response=await adminRequest('GET','/v1/operations/'+id)
      if(response.status!==200) throw new Error('operation '+response.status)
      const op=JSON.parse(response.body)
      if(op.state==='succeeded'){completed=true;break}
      if(op.state==='failed') throw new Error('operation failed')
      await delay(10)
    }
    if(!completed) throw new Error('operation timeout')
    mgmtOk++
  } catch {
    mgmtErrors++
  } finally {
    operationBusy=false
  }
}
const timeout = setTimeout(() => { console.error('performance timed out'); process.exit(1) }, warmMs+measureMs+30000)
try {
  const subscribers = await Promise.all(Array.from({length:9},(_,i) => connect(`sub-${i}`)))
  await Promise.all(subscribers.map(client => new Promise((resolve,reject) =>
    client.subscribe('perf/traffic',{qos:2},error => error ? reject(error):resolve()))))
  subscribers.forEach(client => client.on('message', () => { delivered++ }))
  const publishers = await Promise.all(Array.from({length:10},(_,i) => connect(`pub-${i}`)))
  const pinger = await rawPinger()
  const pingTimer=setInterval(() => pinger.ping(),1000)
  function publishLoop(client,index,sequence=0) {
    if (stop) return
    const qos=sequence%3
    const before=performance.now()
    client.publish('perf/traffic',`p${index}-${sequence}`,{qos}, error => {
      if (error) { if (!stop) publishErrors++; return }
      const now=performance.now()
      if (now>=measureStart && now<measureEnd) {
        published++
        if (qos===1) ackLatencies.push(now-before)
      }
      if (!stop) setTimeout(() => publishLoop(client,index,sequence+1),20)
    })
  }
  publishers.forEach((client,i) => publishLoop(client,i))
  let managementTimer, pageTimer, operationTimer, badTimer, queryFloodTimer, operationFloodTimer
  managementTimer=setInterval(() => {
    waits.push(sendManagement('/metrics',token))
  },1000)
  if (managed) {
    pageTimer=setInterval(() => {
      waits.push(sendManagement('/v1/sessions?limit=10',token))
    },200)
    operationTimer=setInterval(() => {
      if (!operationBusy) waits.push(adminOperation())
    },1000)
    if (mode==='overload') {
      for(let i=0;i<16;i++) slowReader()
      badTimer=setInterval(() => {
        waits.push(sendManagement('/metrics','bad.'+'f'.repeat(64)))
      },5)
      queryFloodTimer=setInterval(() => {
        waits.push(sendManagement('/v1/sessions?limit=1',token))
      },5)
      operationFloodTimer=setInterval(() => {
        if (!operationBusy) waits.push(adminOperation())
      },100)
    }
  }
  await delay(warmMs)
  published=0; delivered=0; mgmtOk=0; mgmtErrors=0; rejected=0
  pingLatencies.length=0; ackLatencies.length=0; pingsByWindow.fill(0)
  measureStart=performance.now(); measureEnd=measureStart+measureMs
  await delay(measureMs)
  stop=true
  clearInterval(pingTimer)
  if (managementTimer) clearInterval(managementTimer)
  if (pageTimer) clearInterval(pageTimer)
  if (operationTimer) clearInterval(operationTimer)
  if (badTimer) clearInterval(badTimer)
  if (queryFloodTimer) clearInterval(queryFloodTimer)
  if (operationFloodTimer) clearInterval(operationFloodTimer)
  for (const socket of slowSockets) socket.destroy()
  pinger.socket.end(generate({cmd:'disconnect'}))
  await Promise.allSettled(waits)
  assert.ok(published>0 && delivered>0)
  assert.equal(publishErrors,0)
  assert.ok(pingLatencies.length>0 && ackLatencies.length>0)
  if (mode==='overload') assert.ok(pingsByWindow.every(value => value>0), 'missing ping in 5s window')
  if (mode==='managed') assert.equal(mgmtErrors,0,'admin pagination/operation errors')
  console.log(JSON.stringify({mode,warmup_ms:warmMs,measure_ms:measureMs,
    published,delivered,throughput_per_sec:published/(measureMs/1000),
    ping_p99_ms:percentile(pingLatencies,0.99),
    puback_p99_ms:percentile(ackLatencies,0.99),
    ping_by_5s:pingsByWindow,management_ok:mgmtOk,
    management_rejected:rejected,management_errors:mgmtErrors}))
} finally {
  stop=true
  for(const socket of slowSockets) socket.destroy()
  await Promise.all(clients.map(client => new Promise(resolve => client.end(true,resolve))))
  clearTimeout(timeout)
}
