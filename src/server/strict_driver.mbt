///|
fn RouterDriver::strict_held_connection(
  self : RouterDriver,
  event : RuntimeEvent,
) -> Unit {
  let id = match event {
    PacketReceived(packet) => Some(packet.connection_id)
    Mqtt5PacketReceived(packet) => Some(packet.connection_id)
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
    Mqtt5PacketReceived(packet) => Some(packet.connection_id)
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
  if self.strict_reload_pending is Some(pending) {
    pending.candidate.release()
    self.strict_reload_pending = None
  }
  self.runtime.logger.log(
    @observability.LogRecord::new(
      @async.now(),
      @observability.Error,
      "wal_fenced",
      reason~,
      message="strict durability stopped business admission",
    ),
  )
  if self.management is Some(active) {
    let persistence = active.persistence
    let sample = self.capture_observation(
      @budget.monotonic_ms(),
      @async.now(),
      active.context,
      persistence?,
    )
    ignore(active.cache.publish(sample))
  }
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
  for ;; {
    match self.strict_management_held.pop_front() {
      Some(event) => self.handle_strict_management_command(event)
      None => break
    }
  }
}

///|
fn RouterDriver::poll_strict_completion(self : RouterDriver) -> Unit {
  let coordinator = match self.strict {
    Some(value) => value
    None => return
  }
  match coordinator.poll() {
    NoCommitCompletion =>
      if self.strict_checkpoint_inflight && coordinator.checkpoint_active() {
        self.drain_strict_queues()
      }
    CommitFencedResult(reason) => self.strict_fence(reason)
    CommitPolicyCapabilityReady => ()
    CommitCheckpointPublished(lsn, _) =>
      if !self.strict_checkpoint_inflight || lsn != self.strict_checkpoint_lsn {
        self.strict_fence("checkpoint-completion-mismatch")
      } else {
        self.strict_checkpoint_inflight = false
        self.strict_checkpoint_degraded = false
        self.strict_checkpoint_next_ms = @async.now() + 60000L
        self.drain_strict_queues()
      }
    CommitCheckpointFailed(reason, fatal) => {
      self.strict_checkpoint_inflight = false
      if fatal {
        self.strict_fence("checkpoint-" + reason)
      } else {
        self.strict_checkpoint_degraded = reason != "preempted"
        self.strict_checkpoint_next_ms = @async.now() + 1000L
        self.drain_strict_queues()
      }
    }
    CommitReleased(actions, deltas, connections) => {
      for index in 0..<deltas.length() {
        let delta = deltas[index]
        for deletion in delta.session_deletes {
          let id = @session.ClientId::new(deletion.client_id).unwrap()
          self.strict_generations.remove(id)
        }
        for put in delta.session_puts {
          let id = @session.ClientId::new(put.session.client_id).unwrap()
          self.strict_generations.set(id, put.generation)
        }
        if connections[index] is Some(connection_id) &&
          self.management_closing.get(connection_id) is Some(watch) &&
          !self.runtime.strict_pending_wills.contains(connection_id) {
          watch.durable_done = true
        }
      }
      self.dispatch(actions)
      self.drain_strict_queues()
    }
  }
}

///|
fn RouterDriver::drain_strict_queues(self : RouterDriver) -> Unit {
  let coordinator = match self.strict {
    Some(value) => value
    None => return
  }
  // A handler may defer an event again when its admission state changes.
  // Visit each item present at entry at most once in this turn.
  let mut remaining_runtime = self.strict_held.length()
  while remaining_runtime > 0 &&
        !coordinator.has_submitted() &&
        !self.strict_fenced &&
        !self.reload_barrier &&
        (!self.strict_checkpoint_inflight || coordinator.checkpoint_active()) &&
        self.strict_checkpoint_cursor is None {
    remaining_runtime -= 1
    let queued = match self.strict_held.pop_front() {
      Some(value) => value
      None => break
    }
    let (event, ticket) = queued
    self.strict_released_connection(event)
    self.handle_strict_runtime_event(event, ticket)
  }
  let mut remaining_management = self.strict_management_held.length()
  while remaining_management > 0 &&
        !coordinator.has_submitted() &&
        !self.strict_fenced &&
        !self.reload_barrier &&
        (!self.strict_checkpoint_inflight || coordinator.checkpoint_active()) &&
        self.strict_checkpoint_cursor is None {
    remaining_management -= 1
    match self.strict_management_held.pop_front() {
      Some(event) => self.handle_strict_management_command(event)
      None => break
    }
  }
}

///|
fn RouterDriver::strict_submit_packet_plan(
  self : RouterDriver,
  connection_id : ConnectionId,
  plan : StrictPacketPlan,
) -> Bool {
  match plan {
    StrictImmediate(actions) => {
      self.dispatch(actions)
      true
    }
    StrictClose(id, reason) => {
      if self.sinks.get(id) is Some(sink) {
        sink.resolve_handshake(false)
        sink.try_close(reason)
      }
      true
    }
    StrictPrepared(mutation, after) => {
      let coordinator = self.strict.unwrap()
      match coordinator.submit(mutation, after, connection_id~) {
        Ok(_) => true
        Err(CommitBusy) => false
        Err(CommitEncoding) | Err(CommitBudget) => {
          if self.sinks.get(connection_id) is Some(sink) {
            sink.resolve_handshake(false)
            sink.try_close(ResourceExhausted)
          }
          true
        }
        Err(_) => {
          self.strict_fence("commit-submit")
          true
        }
      }
    }
  }
}

///|
fn RouterDriver::enqueue_strict_event(
  self : RouterDriver,
  event : RuntimeEvent,
  ticket : @budget.Ticket?,
) -> Bool {
  if self.strict_held.length() >=
    self.runtime.config.max_runtime_events() +
    self.runtime.config.max_connections() {
    return false
  }
  self.strict_held_connection(event)
  self.strict_held.push_back((event, ticket))
  true
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
  let mut transferred = false
  defer (if !transferred { release_optional(ticket) })
  if self.strict_fenced || coordinator.is_fenced() {
    self.strict_fence("writer-fenced")
    return
  }
  if event is PacketReceived(packet) &&
    packet.packet is Pingreq &&
    !coordinator.contains_connection(packet.connection_id) &&
    self.strict_held_connections.get(packet.connection_id).unwrap_or(0) == 0 &&
    self.runtime.connections.get(packet.connection_id)
    is Some({ phase: Active(_), .. }) {
    self.dispatch([
      SendPacket({ connection_id: packet.connection_id, packet: Pingresp }),
    ])
    return
  }
  let collecting_blocks = if coordinator.is_collecting() {
    match event {
      PacketReceived(packet) if !coordinator.contains_connection(
          packet.connection_id,
        ) =>
        match packet.packet {
          Publish(_) | Puback(_) | Pubrec(_) | Pubrel(_) | Pubcomp(_) => false
          _ => true
        }
      AuthenticationPollDue(_) | EmitSystemMetrics(_) => false
      _ => true
    }
  } else {
    false
  }
  if coordinator.has_submitted() ||
    self.reload_barrier ||
    collecting_blocks ||
    self.strict_checkpoint_cursor is Some(_) ||
    (self.strict_checkpoint_inflight && !coordinator.checkpoint_active()) {
    if coordinator.is_collecting() && !coordinator.flush() {
      self.strict_fence("group-commit-submit")
      return
    }
    if self.enqueue_strict_event(event, ticket) {
      transferred = true
    } else {
      self.strict_fence("commit-queue-limit")
    }
    return
  }
  match event {
    Mqtt5PacketReceived(packet) => {
      if packet.packet is @protocol.PacketV5::Connect5(_) &&
        self.runtime.connections.get(packet.connection_id)
        is Some({ phase: AwaitConnect, .. }) {
        if self.sinks.get(packet.connection_id) is Some(sink) &&
          !sink.prepare_handshake(
            self.runtime.config
            .broker_config()
            .resources()
            .get("control_reserve_bytes"),
            frame_bytes=5L,
            scratch_bytes=10L,
          ) {
          self.dispatch(
            self.transport_failed(packet.connection_id, ResourceExhausted),
          )
          return
        }
      }
      self.dispatch(self.runtime.apply(Mqtt5PacketReceived(packet)))
    }
    PacketReceived(packet) => {
      if packet.packet is Connect(_) &&
        self.management_closing.contains(packet.connection_id) {
        return
      }
      if packet.packet is Connect(_) &&
        self.runtime.connections.get(packet.connection_id)
        is Some({ phase: AwaitConnect, .. }) {
        if self.sinks.get(packet.connection_id) is Some(sink) &&
          !sink.prepare_handshake(
            self.runtime.config
            .broker_config()
            .resources()
            .get("control_reserve_bytes"),
          ) {
          ignore(
            self.strict_submit_packet_plan(
              packet.connection_id,
              StrictClose(packet.connection_id, ResourceExhausted),
            ),
          )
          return
        }
      }
      if self.runtime
        .broker_state()
        .admit_action_input(
          packet_cost(packet.packet) * 2L,
          control=control_packet(packet.packet),
        )
        is Err(_) {
        ignore(
          self.strict_submit_packet_plan(
            packet.connection_id,
            StrictClose(packet.connection_id, ResourceExhausted),
          ),
        )
        return
      }
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
      if !self.strict_submit_packet_plan(packet.connection_id, plan) {
        if !coordinator.flush() {
          self.strict_fence("group-commit-submit")
        } else if self.enqueue_strict_event(event, ticket) {
          transferred = true
        } else {
          self.strict_fence("commit-queue-limit")
        }
      }
    }
    AuthenticationCompleted(completed) => {
      let connection_id = self.runtime.auth_tasks
        .get(completed.request_id)
        .map(task => task.connection_id)
        .unwrap_or(ConnectionId::new(0L))
      if !self.strict_submit_packet_plan(
          connection_id,
          self.runtime.prepare_strict_auth_completion(
            completed,
            self.strict_generations,
            coordinator.committed_lsn() + 1L,
          ),
        ) {
        self.strict_fence("unexpected-commit-busy")
      }
    }
    TransportOpened(_) | AuthenticationSubmitFailed(_) | EmitSystemMetrics(_) =>
      self.dispatch(self.runtime.apply(event))
    AuthenticationPollDue(_) => ()
    TransportClosed(closed) => {
      if self.management_closing.get(closed.connection_id) is Some(watch) {
        watch.terminal_seen = true
      }
      if !self.strict_submit_packet_plan(
          closed.connection_id,
          self.runtime.prepare_strict_termination(
            closed,
            self.strict_generations,
          ),
        ) {
        self.strict_fence("unexpected-commit-busy")
      }
    }
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
            ignore(
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
              ),
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
              ignore(
                self.strict_submit_packet_plan(
                  ConnectionId::new(0L),
                  StrictPrepared(Ack(value), actions => {
                    self.runtime.map_broker_actions(actions)
                  }),
                ),
              )
            }
          }
        }
      }
    }
  }
}

///|
fn RouterDriver::poll_strict_checkpoint(self : RouterDriver) -> Unit {
  let coordinator = match self.strict {
    Some(value) => value
    None => return
  }
  if self.strict_fenced ||
    coordinator.is_fenced() ||
    self.reload_barrier ||
    self.reload_reconciler is Some(_) ||
    self.strict_checkpoint_inflight {
    return
  }
  let now_ms = @async.now()
  if self.strict_checkpoint_cursor is None {
    if coordinator.has_pending() ||
      now_ms < self.strict_checkpoint_next_ms ||
      self.strict_held.length() > 0 ||
      self.strict_management_held.length() > 0 {
      return
    }
    self.strict_checkpoint_lsn = coordinator.applied_lsn()
    self.strict_checkpoint_cursor = Some(
      self.runtime.broker_state().start_snapshot_export(self.strict_generations),
    )
  }
  let cursor = self.strict_checkpoint_cursor.unwrap()
  let finished = match cursor.step(16, 4194304L) {
    Ok(value) => value
    Err(_) => {
      self.strict_checkpoint_cursor = None
      self.strict_checkpoint_degraded = true
      self.strict_checkpoint_next_ms = now_ms + 1000L
      self.drain_strict_queues()
      return
    }
  }
  if !finished {
    return
  }
  let (snapshot, generations) = match cursor.finish() {
    Ok(value) => value
    Err(_) => {
      self.strict_checkpoint_cursor = None
      self.strict_checkpoint_degraded = true
      self.strict_checkpoint_next_ms = now_ms + 1000L
      self.drain_strict_queues()
      return
    }
  }
  let identities : Array[@persistence.WalSessionIdentity] = []
  for index in 0..<snapshot.sessions.length() {
    identities.push({
      client_id: snapshot.sessions[index].client_id,
      generation: generations[index],
    })
  }
  let checkpoint : @persistence.WalCheckpoint = {
    generation: coordinator.checkpoint_generation() + 1L,
    lsn: self.strict_checkpoint_lsn,
    identities,
    policy: coordinator.policy_state(),
    snapshot,
  }
  if coordinator.submit_checkpoint(checkpoint) {
    self.strict_checkpoint_cursor = None
    self.strict_checkpoint_inflight = true
  } else {
    self.strict_checkpoint_cursor = None
    self.strict_checkpoint_degraded = true
    self.strict_checkpoint_next_ms = now_ms + 1000L
    self.drain_strict_queues()
  }
}

///|
pub async fn RouterDriver::shutdown_strict(self : RouterDriver) -> Unit {
  let coordinator = match self.strict {
    Some(value) => value
    None => return
  }
  let ids : Array[ConnectionId] = []
  for id, _ in self.runtime.connections {
    ids.push(id)
  }
  for id in ids {
    self.handle(
      Runtime(
        TransportClosed({
          connection_id: id,
          reason: ServerShutdown,
          observed_at_ms: @async.now(),
        }),
      ),
    )
  }
  for ;; {
    if coordinator.is_collecting() && !coordinator.flush() {
      self.strict_fence("shutdown-submit")
    }
    self.handle(WalCompletionDue)
    if self.strict_fenced || coordinator.is_fenced() {
      return
    }
    if !coordinator.has_pending() &&
      self.strict_held.length() == 0 &&
      self.strict_management_held.length() == 0 &&
      self.runtime.connection_count() == 0 &&
      !self.strict_checkpoint_inflight &&
      self.strict_checkpoint_cursor is None {
      return
    }
    @async.sleep(2)
  }
}
