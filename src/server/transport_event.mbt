///|
pub(all) struct RegisterTransportEvent {
  connection_id : ConnectionId
  sink : TransportSink
  accepted_at_ms : Int64
}

///|
pub(all) enum DriverEvent {
  Accounted(RuntimeEvent, @budget.Ticket)
  RegisterTransport(RegisterTransportEvent)
  Runtime(RuntimeEvent)
  ObservationDue
  WalCompletionDue
  WalFlushDue
  ManagementQuery(ManagementQueryEvent)
  ManagementCommand(ManagementCommandEvent)
  ManagementMaintenance
  UnregisterTransport(ConnectionId)
}
