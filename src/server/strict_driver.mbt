///|
fn RouterDriver::strict_held_connection(
  self : RouterDriver,
  event : RuntimeEvent,
) -> Unit {
  let id = match event {
    PacketReceived(packet) => Some(packet.connection_id)
    TransportClosed(closed) => Some(closed.connection_id)
    _ => None
  }
  if id is Some(value) {
    self.strict_held_connections.set(
      value,
      self.strict_held_connections.get(value).unwrap_or(0) + 1,
    )
  }
}

///|
fn RouterDriver::strict_released_connection(
  self : RouterDriver,
  event : RuntimeEvent,
) -> Unit {
  let id = match event {
    PacketReceived(packet) => Some(packet.connection_id)
    TransportClosed(closed) => Some(closed.connection_id)
    _ => None
  }
  if id is Some(value) {
    let count = self.strict_held_connections.get(value).unwrap_or(0)
    if count <= 1 {
      self.strict_held_connections.remove(value)
    } else {
      self.strict_held_connections.set(value, count - 1)
    }
  }
}

///|
fn RouterDriver::strict_fence(self : RouterDriver, reason : String) -> Unit {
  if self.strict_fenced {
    return
  }
  self.strict_fenced = true
  self.runtime.logger.log(
    @observability.LogRecord::new(
      @async.now(),
      @observability.Error,
      "wal_fenced",
      reason~,
      message="strict durability stopped business admission",
    ),
  )
  for _, sink in self.sinks {
    sink.resolve_handshake(false)
    sink.try_close(ServerShutdown)
  }
  for ;; {
    match self.strict_held.pop_front() {
      Some((_, ticket)) => release_optional(ticket)
      None => break
    }
  }
  self.strict_held_connections.clear()
}

///|
fn RouterDriver::poll_strict_completion(self : RouterDriver) -> Unit {
  let coordinator = match self.strict {
    Some(value) => value
    None => return
  }
  match coordinator.poll() {
    NoCommitCompletion => ()
    CommitFencedResult(reason) => self.strict_fence(reason)
    CommitReleased(actions, delta) => {
      for deletion in delta.session_deletes {
        let id = @session.ClientId::new(deletion.client_id).unwrap()
        self.strict_generations.remove(id)
      }
      for put in delta.session_puts {
        let id = @session.ClientId::new(put.session.client_id).unwrap()
        self.strict_generations.set(id, put.generation)
      }
      self.strict_pending_connection = None
      self.dispatch(actions)
      while !coordinator.has_pending() && !self.strict_fenced {
        let queued = match self.strict_held.pop_front() {
          Some(value) => value
          None => break
        }
        let (event, ticket) = queued
        self.strict_released_connection(event)
        self.handle_strict_runtime_event(event, ticket)
      }
    }
  }
}

///|
fn RouterDriver::strict_submit_packet_plan(
  self : RouterDriver,
  connection_id : ConnectionId,
  plan : StrictPacketPlan,
) -> Unit {
  match plan {
    StrictImmediate(actions) => self.dispatch(actions)
    StrictClose(id, reason) =>
      if self.sinks.get(id) is Some(sink) {
        sink.resolve_handshake(false)
        sink.try_close(reason)
      }
    StrictPrepared(mutation, after) => {
      let coordinator = self.strict.unwrap()
      match coordinator.submit(mutation, after) {
        Ok(_) => self.strict_pending_connection = Some(connection_id)
        Err(_) => self.strict_fence("commit-submit")
      }
    }
  }
}

///|
fn RouterDriver::handle_strict_runtime_event(
  self : RouterDriver,
  event : RuntimeEvent,
  ticket : @budget.Ticket?,
) -> Unit {
  let coordinator = match self.strict {
    Some(value) => value
    None => {
      release_optional(ticket)
      return
    }
  }
  if self.strict_fenced || coordinator.is_fenced() {
    release_optional(ticket)
    self.strict_fence("writer-fenced")
    return
  }
  if coordinator.has_pending() {
    if event is PacketReceived(packet) &&
      packet.packet is Pingreq &&
      self.strict_pending_connection != Some(packet.connection_id) &&
      self.strict_held_connections.get(packet.connection_id).unwrap_or(0) == 0 &&
      self.runtime.connections.get(packet.connection_id)
      is Some({ phase: Active(_), .. }) {
      release_optional(ticket)
      self.dispatch([
        SendPacket({ connection_id: packet.connection_id, packet: Pingresp }),
      ])
      return
    }
    if self.strict_held.length() >=
      self.runtime.config.max_runtime_events() +
      self.runtime.config.max_connections() {
      release_optional(ticket)
      self.strict_fence("commit-queue-limit")
      return
    }
    self.strict_held_connection(event)
    self.strict_held.push_back((event, ticket))
    return
  }
  defer release_optional(ticket)
  match event {
    PacketReceived(packet) => {
      let plan = match self.runtime.connections.get(packet.connection_id) {
        Some({ phase: AwaitConnect, .. }) =>
          self.runtime.prepare_strict_connect_packet(
            packet,
            self.strict_generations,
            coordinator.committed_lsn() + 1L,
          )
        Some({ phase: Active(_), .. }) =>
          self.runtime.prepare_strict_active_packet(
            packet,
            self.strict_generations,
          )
        _ => StrictClose(packet.connection_id, ProtocolError)
      }
      self.strict_submit_packet_plan(packet.connection_id, plan)
    }
    AuthenticationCompleted(completed) => {
      let connection_id = self.runtime.auth_tasks
        .get(completed.request_id)
        .map(task => task.connection_id)
        .unwrap_or(ConnectionId::new(0L))
      self.strict_submit_packet_plan(
        connection_id,
        self.runtime.prepare_strict_auth_completion(
          completed,
          self.strict_generations,
          coordinator.committed_lsn() + 1L,
        ),
      )
    }
    TransportOpened(_) | AuthenticationSubmitFailed(_) | EmitSystemMetrics(_) =>
      self.dispatch(self.runtime.apply(event))
    AuthenticationPollDue(_) => ()
    TransportClosed(closed) =>
      self.strict_submit_packet_plan(
        closed.connection_id,
        self.runtime.prepare_strict_termination(closed, self.strict_generations),
      )
    CheckDeadlines(now_ms) => {
      self.runtime.admission.cleanup_ips((self.runtime.admission.clock)())
      self.runtime.admission.prune_publishers(self.runtime.broker_state())
      for closed in self.runtime.strict_due_closures(now_ms) {
        self.handle_strict_runtime_event(TransportClosed(closed), None)
      }
      if !coordinator.has_pending() && !self.strict_fenced {
        match self.runtime.broker_state().next_durable_expiration(now_ms) {
          None => ()
          Some((client_id, kind)) => {
            let generation = match self.strict_generations.get(client_id) {
              Some(value) => value
              None => {
                self.strict_fence("expiry-generation-missing")
                return
              }
            }
            let plan = match
              self.runtime
              .broker_state()
              .prepare_durable_lifecycle(client_id, generation, kind) {
              Ok(value) => value
              Err(_) => {
                self.strict_fence("expiry-prepare")
                return
              }
            }
            self.strict_submit_packet_plan(
              ConnectionId::new(0L),
              StrictPrepared(Lifecycle(plan), actions => {
                let mapped = self.runtime.map_broker_actions(actions)
                if kind is @router.Delete {
                  ignore(
                    self.runtime.map_broker_actions([
                      @router.SessionExpired(client_id),
                    ]),
                  )
                }
                mapped
              }),
            )
          }
        }
      }
      if !coordinator.has_pending() && !self.strict_fenced {
        match self.runtime.broker_state().next_durable_promotion() {
          None => ()
          Some(client_id) => {
            let generation = self.strict_generations
              .get(client_id)
              .unwrap_or(1L)
            let plan = match
              self.runtime
              .broker_state()
              .prepare_durable_ack(
                client_id,
                @session.SessionPacketId::new(1).unwrap(),
                @router.DurableAckKind::PendingPromotion,
                generation,
              ) {
              Ok(value) => Some(value)
              Err(_) => None
            }
            if plan is Some(value) {
              self.strict_submit_packet_plan(
                ConnectionId::new(0L),
                StrictPrepared(Ack(value), actions => {
                  self.runtime.map_broker_actions(actions)
                }),
              )
            }
          }
        }
      }
    }
  }
}
