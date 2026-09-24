///|
pub(all) enum StrictPolicyIssueResult {
  PolicyIssueSubmitted
  PolicyClosePending
  PolicyIssueBusy
  PolicyIssueStale
  PolicyIssueFailed
} derive(Eq, Debug)

///|
/// A single issue is prepared against current core identity and sent through
/// the existing strict writer. The discovery cursor advances only after the
/// committed apply callback acknowledges it.
pub fn RouterDriver::apply_policy_issue_strict(
  self : RouterDriver,
  issue : @router.PolicyIssue,
  reconciler : @router.PolicyReconciler,
) -> StrictPolicyIssueResult {
  let coordinator = match self.strict {
    Some(value) if !self.strict_fenced && !value.is_fenced() => value
    _ => return PolicyIssueFailed
  }
  let (client_id, incarnation) = match issue {
    @router.EvictSession(id, version) => (id, version)
    @router.DropFilter(id, version, _, _) => (id, version)
    @router.DropPending(id, version, _, _, _, _, _) => (id, version)
  }
  let broker = self.runtime.broker_state()
  if broker.policy_session_incarnation(client_id) != Some(incarnation) {
    ignore(reconciler.complete_issue(issue))
    return PolicyIssueStale
  }
  if coordinator.has_pending() ||
    self.strict_checkpoint_cursor is Some(_) ||
    self.strict_checkpoint_inflight {
    return PolicyIssueBusy
  }
  match issue {
    @router.EvictSession(_, _) => {
      if self.runtime.active_connection(client_id) is Some(connection_id) {
        if self.sinks.get(connection_id) is Some(sink) {
          sink.try_close(PolicyRevoked)
        }
        return PolicyClosePending
      }
      if broker.session_attached(client_id) == Some(true) {
        return PolicyClosePending
      }
      if !broker.has_session(client_id) {
        ignore(reconciler.complete_issue(issue))
        return PolicyIssueStale
      }
      let generation = match self.strict_generations.get(client_id) {
        Some(value) => value
        None => {
          // Clean Sessions have no durable identity or replay obligations.
          if broker.session_mode(client_id) == Some(@session.Clean) {
            match broker.apply(@router.RemoveSession(client_id)) {
              Ok(_) => {
                ignore(reconciler.complete_issue(issue))
                return PolicyIssueSubmitted
              }
              Err(_) => return PolicyIssueFailed
            }
          }
          return PolicyIssueFailed
        }
      }
      let plan = match
        broker.prepare_durable_lifecycle(client_id, generation, @router.Delete) {
        Ok(value) => value
        Err(_) => return PolicyIssueFailed
      }
      match
        coordinator.submit(Lifecycle(plan), _ => {
          ignore(reconciler.complete_issue(issue))
          []
        }) {
        Ok(_) => PolicyIssueSubmitted
        Err(CommitBusy) => PolicyIssueBusy
        Err(_) => PolicyIssueFailed
      }
    }
    @router.DropFilter(_, _, subscription_id, filter) => {
      if broker.policy_subscription_identity(client_id, filter) !=
        Some(subscription_id) {
        ignore(reconciler.complete_issue(issue))
        return PolicyIssueStale
      }
      self.submit_policy_local_change(
        client_id,
        @router.DropSubscription(filter.value()),
        issue,
        reconciler,
        coordinator,
      )
    }
    @router.DropPending(_, _, revision, index, topic, qos, bytes) => {
      if broker.policy_session_revision(client_id) != Some(revision) {
        ignore(reconciler.complete_issue(issue))
        return PolicyIssueStale
      }
      self.submit_policy_local_change(
        client_id,
        @router.DropPendingAt(index, topic, qos, bytes),
        issue,
        reconciler,
        coordinator,
      )
    }
  }
}

///|
fn RouterDriver::submit_policy_local_change(
  self : RouterDriver,
  client_id : @session.ClientId,
  change : @router.DurablePolicyChange,
  issue : @router.PolicyIssue,
  reconciler : @router.PolicyReconciler,
  coordinator : CommitCoordinator,
) -> StrictPolicyIssueResult {
  let broker = self.runtime.broker_state()
  if broker.session_mode(client_id) == Some(@session.Clean) {
    let plan = match
      broker.prepare_durable_reconcile(
        client_id,
        change,
        1L,
        require_persistent=false,
      ) {
      Ok(value) => value
      Err(@router.InvalidSessionState(_))
      | Err(@router.SessionNotFound(_))
      | Err(@router.InvariantViolation(_)) => return PolicyIssueStale
      Err(_) => return PolicyIssueFailed
    }
    broker.begin_action_scope()
    let result = plan.commit()
    broker.end_action_scope()
    match result {
      Ok(_) => {
        ignore(reconciler.complete_issue(issue))
        PolicyIssueSubmitted
      }
      Err(_) => {
        plan.cancel()
        PolicyIssueFailed
      }
    }
  } else {
    let generation = match self.strict_generations.get(client_id) {
      Some(value) => value
      None => return PolicyIssueFailed
    }
    let plan = match
      broker.prepare_durable_reconcile(client_id, change, generation) {
      Ok(value) => value
      Err(@router.InvalidSessionState(_))
      | Err(@router.SessionNotFound(_))
      | Err(@router.InvariantViolation(_)) => return PolicyIssueStale
      Err(_) => return PolicyIssueFailed
    }
    match
      coordinator.submit(PolicyReconcile(plan), _ => {
        ignore(reconciler.complete_issue(issue))
        []
      }) {
      Ok(_) => PolicyIssueSubmitted
      Err(CommitBusy) => PolicyIssueBusy
      Err(_) => PolicyIssueFailed
    }
  }
}
