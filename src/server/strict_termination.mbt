///|
fn BrokerRuntime::finish_strict_transport_close(
  self : BrokerRuntime,
  event : TransportClosedEvent,
) -> Array[RuntimeAction] {
  let meta = match self.connections.get(event.connection_id) {
    Some(value) => value
    None => return []
  }
  self.connections.remove(event.connection_id)
  self.v5_active.remove(event.connection_id)
  self.v5_pending.remove(event.connection_id)
  self.inbound_aliases.remove(event.connection_id)
  self.v5_will_ids.remove(event.connection_id)
  if meta.phase is Active(_) {
    self.release_policy_epoch(meta.policy_epoch)
  }
  let actions : Array[RuntimeAction] = []
  match meta.phase {
    Active(client_id) => {
      if self.active_by_client.get(client_id) == Some(event.connection_id) {
        self.active_by_client.remove(client_id)
      }
      let publish_will = event.reason != NormalDisconnect &&
        event.reason != ConnectRejected &&
        event.reason != ServerShutdown
      if publish_will &&
        meta.will is Some(will) &&
        meta.principal is Some(principal) &&
        self.security.allows_principal(principal) &&
        self.security.can_write_topic(principal, will.topic) {
        self.strict_pending_wills.set(event.connection_id, (client_id, will))
        actions.push(StartDurableWill(event.connection_id))
      } else {
        let ticket = self.will_tickets.get(event.connection_id)
        self.will_tickets.remove(event.connection_id)
        release_optional(ticket)
      }
      self.admission.prune_publishers(self.broker_state)
    }
    Authenticating(request_id) =>
      actions.push(CancelAuthentication({ request_id, }))
    AwaitConnect => ()
  }
  actions.push(
    CloseTransport({ connection_id: event.connection_id, reason: event.reason }),
  )
  actions
}

///|
fn BrokerRuntime::take_strict_pending_will(
  self : BrokerRuntime,
  connection_id : ConnectionId,
) -> (@session.ClientId, StoredWill, @budget.Ticket?)? {
  let pending = self.strict_pending_wills.get(connection_id)
  self.strict_pending_wills.remove(connection_id)
  match pending {
    Some((client_id, will)) => {
      let ticket = self.will_tickets.get(connection_id)
      self.will_tickets.remove(connection_id)
      Some((client_id, will, ticket))
    }
    None => None
  }
}

///|
pub fn BrokerRuntime::prepare_strict_termination(
  self : BrokerRuntime,
  event : TransportClosedEvent,
  generations : Map[@session.ClientId, Int64],
  v5_retention_override? : @session.Retention,
) -> StrictPacketPlan {
  let meta = match self.connections.get(event.connection_id) {
    Some(value) => value
    None => return StrictImmediate([])
  }
  match meta.phase {
    AwaitConnect | Authenticating(_) =>
      StrictImmediate(self.apply(TransportClosed(event)))
    Active(client_id) => {
      if self.active_by_client.get(client_id) != Some(event.connection_id) {
        return StrictImmediate(self.finish_strict_transport_close(event))
      }
      let kind = if v5_retention_override == Some(@session.DropOnClose) {
        @router.DurableLifecycleKind::Delete
      } else {
        match self.broker_state.session_mode(client_id) {
          Some(@session.Persistent) =>
            @router.DurableLifecycleKind::DetachAt(
              if event.observed_at_ms > 0L {
                event.observed_at_ms
              } else {
                meta.last_control_at_ms
              },
            )
          Some(@session.Clean) => @router.DurableLifecycleKind::Delete
          None => return StrictClose(event.connection_id, ResourceExhausted)
        }
      }
      let generation = generations.get(client_id).unwrap_or(1L)
      let prepared = match v5_retention_override {
        Some(value) =>
          self.broker_state.prepare_durable_lifecycle(
            client_id,
            generation,
            kind,
            v5_retention_override=value,
          )
        None =>
          self.broker_state.prepare_durable_lifecycle(
            client_id, generation, kind,
          )
      }
      let plan = match prepared {
        Ok(value) => value
        Err(_) => return StrictClose(event.connection_id, ResourceExhausted)
      }
      let will_plan = match self.v5_will_ids.get(event.connection_id) {
        None => None
        Some(id) =>
          if event.reason == NormalDisconnect ||
            event.reason == ConnectRejected ||
            event.reason == ServerShutdown {
            match self.broker_state.prepare_durable_will_cancel(id) {
              Ok(value) => Some(value)
              Err(_) =>
                return StrictClose(event.connection_id, ResourceExhausted)
            }
          } else {
            match
              self.broker_state.prepare_durable_will_trigger(
                id,
                @budget.monotonic_ms(),
                event.observed_at_ms,
                v5_retention_override.unwrap_or_else(() => {
                  self.broker_state
                  .session_retention(client_id)
                  .unwrap_or(@session.DropOnClose)
                }),
              ) {
              Ok(value) => Some(value)
              Err(_) =>
                return StrictClose(event.connection_id, ResourceExhausted)
            }
          }
      }
      let mutation = match will_plan {
        Some(value) => LifecycleWithV5Will(plan, value)
        None => Lifecycle(plan)
      }
      StrictPrepared(mutation, _ => self.finish_strict_transport_close(event))
    }
  }
}

///|
fn BrokerRuntime::strict_due_closures(
  self : BrokerRuntime,
  now_ms : Int64,
) -> Array[TransportClosedEvent] {
  let result : Array[TransportClosedEvent] = []
  for connection_id, meta in self.connections {
    let reason : CloseReason? = match meta.phase {
      AwaitConnect =>
        if now_ms >=
          meta.accepted_at_ms + self.config.connect_timeout_ms().to_int64() {
          Some(ConnectTimeout)
        } else {
          None
        }
      Authenticating(request_id) => {
        let deadline = match self.auth_tasks.get(request_id) {
          Some(task) => task.deadline_ms
          None => meta.accepted_at_ms
        }
        if now_ms >= deadline {
          Some(ConnectTimeout)
        } else {
          None
        }
      }
      Active(_) =>
        if meta.keep_alive_seconds > 0 &&
          now_ms >=
          meta.last_control_at_ms + meta.keep_alive_seconds.to_int64() * 1500L {
          Some(KeepAliveTimeout)
        } else {
          None
        }
    }
    if reason is Some(value) {
      result.push({ connection_id, reason: value, observed_at_ms: now_ms })
    }
  }
  result
}
