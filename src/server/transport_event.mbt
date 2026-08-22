///|
pub(all) struct RegisterTransportEvent {
  connection_id : ConnectionId
  sink : TransportSink
  accepted_at_ms : Int64
}

///|
pub(all) enum DriverEvent {
  RegisterTransport(RegisterTransportEvent)
  Runtime(RuntimeEvent)
  UnregisterTransport(ConnectionId)
}
