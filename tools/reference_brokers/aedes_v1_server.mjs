import net from 'node:net'
import { Aedes } from 'aedes'

const [host = '127.0.0.1', portArg = '0'] = process.argv.slice(2)
const port = Number(portArg)
if (!Number.isInteger(port) || port < 0 || port > 65535) {
  throw new Error(`invalid port: ${portArg}`)
}

const broker = await Aedes.createBroker()
const server = net.createServer(broker.handle)
server.on('error', error => {
  console.error(`aedes server: ${error.message}`)
  process.exitCode = 1
})
server.listen(port, host, () => {
  const address = server.address()
  console.log(`AEDES_READY=${address.port}`)
})

let closing = false
const close = () => {
  if (closing) return
  closing = true
  server.close(() => broker.close(() => process.exit(process.exitCode ?? 0)))
  setTimeout(() => process.exit(1), 5000).unref()
}

process.on('SIGINT', close)
process.on('SIGTERM', close)
