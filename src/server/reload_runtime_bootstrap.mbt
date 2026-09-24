///|
/// Off/snapshot startup applies the current policy to restored Sessions
/// before accepting or replaying any MQTT connection. Snapshot durability
/// remains the existing asynchronous checkpoint contract.
pub async fn bootstrap_runtime_policy(
  broker : @router.BrokerState,
  policy : @security.SecurityPolicy,
  policy_epoch : Int64,
  max_items : Int,
  max_bytes : Int64,
) -> Unit {
  if broker.enable_policy_index() is Err(_) ||
    !broker.set_security_policy(policy) {
    raise ResourceStartupFailure("policy startup budget unavailable")
  }
  let scan = match
    @router.PolicyReconciler::new(policy, policy_epoch, max_items, max_bytes) {
    Some(value) => value
    None => raise ResourceStartupFailure("invalid policy startup bounds")
  }
  for ;; {
    match scan.next(broker) {
      @router.PolicyScanProgress => @async.sleep(1)
      @router.PolicyScanWaiting =>
        raise ResourceStartupFailure("policy startup scan stalled")
      @router.PolicyScanUnavailable =>
        raise ResourceStartupFailure("policy startup index unavailable")
      @router.PolicyScanDone => return
      @router.PolicyScanIssue(issue) => {
        let (id, incarnation) = match issue {
          @router.EvictSession(value, version) => (value, version)
          @router.DropFilter(value, version, _, _) => (value, version)
          @router.DropPending(value, version, _, _, _, _, _) => (value, version)
        }
        if broker.policy_session_incarnation(id) != Some(incarnation) {
          ignore(scan.complete_issue(issue))
          continue
        }
        match issue {
          @router.EvictSession(_, _) =>
            if broker.apply(@router.RemoveSession(id)) is Err(_) {
              raise ResourceStartupFailure("policy startup eviction failed")
            }
          @router.DropFilter(_, _, subscription_id, filter) => {
            if broker.policy_subscription_identity(id, filter) !=
              Some(subscription_id) {
              ignore(scan.complete_issue(issue))
              continue
            }
            bootstrap_runtime_change(
              broker,
              id,
              @router.DropSubscription(filter.value()),
            )
          }
          @router.DropPending(_, _, revision, index, topic, qos, size) => {
            if broker.policy_session_revision(id) != Some(revision) {
              ignore(scan.complete_issue(issue))
              continue
            }
            bootstrap_runtime_change(
              broker,
              id,
              @router.DropPendingAt(index, topic, qos, size),
            )
          }
        }
        ignore(scan.complete_issue(issue))
        @async.sleep(1)
      }
    }
  }
}

///|
fn bootstrap_runtime_change(
  broker : @router.BrokerState,
  id : @session.ClientId,
  change : @router.DurablePolicyChange,
) -> Unit raise ResourceStartupFailure {
  let plan = match
    broker.prepare_durable_reconcile(id, change, 1L, require_persistent=false) {
    Ok(value) => value
    Err(_) =>
      raise ResourceStartupFailure("policy startup cleanup prepare failed")
  }
  broker.begin_action_scope()
  let result = plan.commit()
  broker.end_action_scope()
  if result is Err(_) {
    plan.cancel()
    raise ResourceStartupFailure("policy startup cleanup apply failed")
  }
}
