///|
pub(all) enum RuntimePolicyResult {
  PolicyApplied(Array[RuntimeAction])
  PolicyStale
  PolicyFailed
}

///|
/// The off/snapshot cleanup path runs one already discovered issue at a
/// serialized driver boundary. It does not depend on management indexes.
pub fn BrokerRuntime::apply_policy_issue_runtime(
  self : BrokerRuntime,
  issue : @router.PolicyIssue,
) -> RuntimePolicyResult {
  let (client_id, incarnation) = match issue {
    EvictSession(id, version) => (id, version)
    DropFilter(id, version, _, _) => (id, version)
    DropPending(id, version, _, _, _, _, _) => (id, version)
  }
  if self.broker_state.policy_session_incarnation(client_id) !=
    Some(incarnation) {
    return PolicyStale
  }
  match issue {
    EvictSession(_, _) => {
      let actions : Array[RuntimeAction] = []
      if self.active_by_client.get(client_id) is Some(connection_id) {
        actions.append(self.terminate(connection_id, PolicyRevoked))
      }
      if self.broker_state.has_session(client_id) {
        match self.broker_state.apply(@router.RemoveSession(client_id)) {
          Ok(broker_actions) =>
            actions.append(self.map_broker_actions(broker_actions))
          Err(_) => return PolicyFailed
        }
      }
      PolicyApplied(actions)
    }
    DropFilter(_, _, subscription_id, filter) => {
      if self.broker_state.policy_subscription_identity(client_id, filter) !=
        Some(subscription_id) {
        return PolicyStale
      }
      self.apply_one_policy_change_runtime(
        client_id,
        @router.DropSubscription(filter.value()),
      )
    }
    DropPending(_, _, revision, index, topic, qos, bytes) => {
      if self.broker_state.policy_session_revision(client_id) != Some(revision) {
        return PolicyStale
      }
      self.apply_one_policy_change_runtime(
        client_id,
        @router.DropPendingAt(index, topic, qos, bytes),
      )
    }
  }
}

///|
fn BrokerRuntime::apply_one_policy_change_runtime(
  self : BrokerRuntime,
  client_id : @session.ClientId,
  change : @router.DurablePolicyChange,
) -> RuntimePolicyResult {
  let plan = match
    self.broker_state.prepare_durable_reconcile(
      client_id,
      change,
      1L,
      require_persistent=false,
    ) {
    Ok(value) => value
    Err(@router.InvalidSessionState(_))
    | Err(@router.SessionNotFound(_))
    | Err(@router.InvariantViolation(_)) => return PolicyStale
    Err(_) => return PolicyFailed
  }
  self.broker_state.begin_action_scope()
  let result = plan.commit()
  self.broker_state.end_action_scope()
  match result {
    Ok(actions) => PolicyApplied(self.map_broker_actions(actions))
    Err(_) => {
      plan.cancel()
      PolicyFailed
    }
  }
}
