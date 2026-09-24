///|
fn BrokerRuntime::strict_auth_decision(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  packet : @protocol.ConnectPacket,
  received_at_ms : Int64,
  decision : @security.ConnectAuthentication,
  generations : Map[@session.ClientId, Int64],
  proposed_generation : Int64,
) -> StrictPacketPlan {
  match decision {
    Accepted(principal) =>
      self.prepare_strict_accepted_connect(
        connection_id, packet, received_at_ms, principal, generations, proposed_generation,
      )
    BadCredentials => {
      self.metrics.record_authentication_failure()
      self.metrics.record_auth_bad_credentials()
      StrictImmediate(self.reject_connect(connection_id, BadUsernameOrPassword))
    }
    NotAuthorized => {
      self.metrics.record_authentication_failure()
      StrictImmediate(self.reject_connect(connection_id, NotAuthorized))
    }
  }
}

///|
pub fn BrokerRuntime::prepare_strict_connect_packet(
  self : BrokerRuntime,
  event : PacketReceivedEvent,
  generations : Map[@session.ClientId, Int64],
  proposed_generation : Int64,
) -> StrictPacketPlan {
  let packet = match event.packet {
    Connect(value) => value
    _ => return StrictClose(event.connection_id, ProtocolError)
  }
  if !packet.clean_session && packet.client_id == "" {
    return StrictImmediate(
      self.reject_connect(event.connection_id, IdentifierRejected),
    )
  }
  if packet.username is Some(_) &&
    packet.password is Some(_) &&
    self.security.has_passwords() {
    self.metrics.record_auth_request()
    if !self.admission.admit_auth(event.connection_id) {
      self.metrics.record_auth_resource_rejection()
      return StrictImmediate(
        self.reject_connect(event.connection_id, ServerUnavailable),
      )
    }
  }
  if !self.async_auth {
    return match self.authenticate_bounded(packet, event.connection_id) {
      Ok(decision) =>
        self.strict_auth_decision(
          event.connection_id,
          packet,
          event.received_at_ms,
          decision,
          generations,
          proposed_generation,
        )
      Err(_) => {
        self.metrics.record_auth_resource_rejection()
        StrictImmediate(
          self.reject_connect(event.connection_id, ServerUnavailable),
        )
      }
    }
  }
  match self.security.prepare_authentication(packet.username, packet.password) {
    Immediate(decision) =>
      self.strict_auth_decision(
        event.connection_id,
        packet,
        event.received_at_ms,
        decision,
        generations,
        proposed_generation,
      )
    HashRequired(request) =>
      StrictImmediate(
        self.begin_async_authentication(
          event.connection_id,
          packet,
          event.received_at_ms,
          request,
        ),
      )
  }
}

///|
pub fn BrokerRuntime::prepare_strict_auth_completion(
  self : BrokerRuntime,
  event : AuthenticationCompletedEvent,
  generations : Map[@session.ClientId, Int64],
  proposed_generation : Int64,
) -> StrictPacketPlan {
  self.auth_submissions.remove(event.request_id)
  let task = match self.auth_tasks.get(event.request_id) {
    Some(value) => value
    None => {
      self.metrics.record_auth_late_result()
      return StrictImmediate([])
    }
  }
  self.auth_tasks.remove(event.request_id)
  task.ticket.release().unwrap()
  match self.connections.get(task.connection_id) {
    Some({ phase: Authenticating(active), .. }) if active == event.request_id =>
      ()
    _ => {
      self.metrics.record_auth_late_result()
      return StrictImmediate([])
    }
  }
  if task.policy_epoch != self.policy_epoch {
    self.metrics.record_auth_late_result()
    return StrictImmediate(
      self.reject_connect(task.connection_id, ServerUnavailable),
    )
  }
  if event.completed_at_ms >= task.deadline_ms {
    self.metrics.record_auth_deadline_rejection()
    return StrictClose(task.connection_id, ConnectTimeout)
  }
  match event.outcome {
    HashMatched => {
      let decision = task.candidate.complete_connect(true)
      if decision is Accepted(_) {
        self.metrics.record_auth_success()
      }
      self.strict_auth_decision(
        task.connection_id,
        task.packet,
        event.completed_at_ms,
        decision,
        generations,
        proposed_generation,
      )
    }
    HashMismatched =>
      self.strict_auth_decision(
        task.connection_id,
        task.packet,
        event.completed_at_ms,
        task.candidate.complete_connect(false),
        generations,
        proposed_generation,
      )
    AuthBackendUnavailable
    | AuthInternalFailure
    | AuthCancelledBeforeRun
    | AuthFinishedAfterCancel => {
      self.metrics.record_auth_resource_rejection()
      StrictImmediate(
        self.reject_connect(task.connection_id, ServerUnavailable),
      )
    }
  }
}
