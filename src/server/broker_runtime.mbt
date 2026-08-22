///|
pub struct BrokerRuntime {
  config : ServerConfig
  broker_state : @router.BrokerState
  connections : Map[ConnectionId, ConnectionMeta]
  active_by_client : Map[@session.ClientId, ConnectionId]
}

///|
pub fn BrokerRuntime::new(
  config : ServerConfig,
  initial_state : @router.BrokerState,
) -> BrokerRuntime {
  {
    config,
    broker_state: initial_state,
    connections: Map([]),
    active_by_client: Map([]),
  }
}

///|
pub fn BrokerRuntime::connection_count(self : BrokerRuntime) -> Int {
  self.connections.length()
}

///|
pub fn BrokerRuntime::broker_state(self : BrokerRuntime) -> @router.BrokerState {
  self.broker_state
}

///|
pub fn BrokerRuntime::check_invariants(
  self : BrokerRuntime,
) -> Result[Unit, ServerError] {
  if self.connections.length() > self.config.max_connections() {
    return Err(RuntimeInvariantViolation("connection limit exceeded"))
  }
  match self.broker_state.check_invariants() {
    Err(_) =>
      return Err(RuntimeInvariantViolation("broker state is inconsistent"))
    Ok(_) => ()
  }
  for client_id, connection_id in self.active_by_client {
    match self.connections.get(connection_id) {
      Some({ phase: Active(bound_client), .. }) if bound_client == client_id =>
        ()
      _ =>
        return Err(
          RuntimeInvariantViolation("active client index is inconsistent"),
        )
    }
    if !self.broker_state.has_session(client_id) {
      return Err(RuntimeInvariantViolation("active client has no session"))
    }
  }
  for connection_id, meta in self.connections {
    if meta.id != connection_id {
      return Err(RuntimeInvariantViolation("connection id/key mismatch"))
    }
    match meta.phase {
      AwaitConnect =>
        if meta.keep_alive_seconds != 0 || meta.will is Some(_) {
          return Err(
            RuntimeInvariantViolation("await-connect metadata is active"),
          )
        }
      Active(client_id) => {
        if self.active_by_client.get(client_id) != Some(connection_id) {
          return Err(
            RuntimeInvariantViolation("connection index is inconsistent"),
          )
        }
        if !self.broker_state.has_session(client_id) {
          return Err(
            RuntimeInvariantViolation("active connection has no session"),
          )
        }
      }
    }
  }
  Ok(())
}
