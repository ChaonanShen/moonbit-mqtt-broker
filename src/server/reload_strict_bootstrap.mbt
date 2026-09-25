///|
pub(all) struct StrictPolicyBootstrap {
  committed_lsn : Int64
  identities : Array[@persistence.WalSessionIdentity]
  policy : @persistence.WalPolicyState
}

///|
async fn append_policy_payload(
  store : @persistence.WalStore,
  payload : Bytes,
) -> Unit {
  let previous = store.committed_lsn()
  let expected = previous + 1L
  match
    store.append_batch({
      previous_lsn: previous,
      transactions: [{ lsn: expected, delta: payload }],
    }) {
    Ok(value) if value == expected => ()
    _ => raise ResourceStartupFailure("policy WAL commit unavailable")
  }
}

///|
/// Before any MQTT listener binds, migrate an old WAL directory to the policy
/// capability, compare the committed fingerprint, and finish idempotent
/// security cleanup from the current recovered state.
pub async fn bootstrap_strict_policy(
  store : @persistence.WalStore,
  broker : @router.BrokerState,
  identities : Array[@persistence.WalSessionIdentity],
  policy : @security.SecurityPolicy,
  fingerprint : Bytes,
  max_items : Int,
  max_bytes : Int64,
) -> StrictPolicyBootstrap {
  if fingerprint.length() != 32 {
    raise ResourceStartupFailure("policy fingerprint invalid")
  }
  if broker.enable_policy_index() is Err(_) ||
    !broker.set_security_policy(policy) {
    raise ResourceStartupFailure("policy index budget unavailable")
  }
  if !store.manifest().policy_required {
    if store.require_policy_capability() is Err(_) {
      raise ResourceStartupFailure("policy WAL capability migration failed")
    }
  }
  let mut state = store.policy_state()
  if state is None {
    let record : @persistence.WalPolicyRecord = {
      transition: @persistence.PolicyActivated,
      sequence: 1L,
      fingerprint,
    }
    let encoded = match @persistence.encode_wal_policy_record(record) {
      Ok(value) => value
      Err(_) => raise ResourceStartupFailure("policy bootstrap encode failed")
    }
    append_policy_payload(store, encoded)
    state = store.policy_state()
  }
  let committed = match state {
    Some(value) => value
    None => raise ResourceStartupFailure("policy WAL metadata missing")
  }
  if committed.fingerprint != fingerprint {
    raise ResourceStartupFailure("PolicySourceMismatch")
  }
  let generations : Map[@session.ClientId, Int64] = Map([])
  for entry in identities {
    let id = @session.ClientId::new(entry.client_id).unwrap()
    generations.set(id, entry.generation)
  }
  if committed.reconcile_pending {
    let scan = match
      @router.PolicyReconciler::new(
        policy,
        committed.sequence,
        max_items,
        max_bytes,
      ) {
      Some(value) => value
      None => raise ResourceStartupFailure("invalid policy reconcile budget")
    }
    for ;; {
      match scan.next(broker) {
        @router.PolicyScanProgress => @async.sleep(1)
        @router.PolicyScanWaiting =>
          raise ResourceStartupFailure("policy startup scan stalled")
        @router.PolicyScanUnavailable =>
          raise ResourceStartupFailure("policy startup index unavailable")
        @router.PolicyScanDone => break
        @router.PolicyScanIssue(issue) => {
          match issue {
            @router.EvictSession(id, incarnation) => {
              if broker.policy_session_incarnation(id) != Some(incarnation) {
                ignore(scan.complete_issue(issue))
                continue
              }
              let generation = match generations.get(id) {
                Some(value) => value
                None =>
                  raise ResourceStartupFailure(
                    "policy eviction identity missing",
                  )
              }
              let plan = match
                broker.prepare_durable_lifecycle(
                  id,
                  generation,
                  @router.Delete,
                  cancel_wills=true,
                ) {
                Ok(value) => value
                Err(_) =>
                  raise ResourceStartupFailure("policy eviction prepare failed")
              }
              errdefer plan.cancel()
              let encoded = if store.uses_v5_schema() {
                let delta = match
                  plan.delta_v5(@budget.monotonic_ms(), @async.now()) {
                  Ok(value) => value
                  Err(_) =>
                    raise ResourceStartupFailure(
                      "policy eviction V5 delta failed",
                    )
                }
                match @persistence.encode_durable_delta_v5(delta) {
                  Ok(value) => value
                  Err(_) =>
                    raise ResourceStartupFailure(
                      "policy eviction encode failed",
                    )
                }
              } else {
                match @persistence.encode_durable_delta(plan.delta()) {
                  Ok(value) => value
                  Err(_) =>
                    raise ResourceStartupFailure(
                      "policy eviction encode failed",
                    )
                }
              }
              append_policy_payload(store, encoded)
              broker.begin_action_scope()
              let result = plan.commit()
              broker.end_action_scope()
              if result is Err(_) {
                raise ResourceStartupFailure("policy eviction apply failed")
              }
              generations.remove(id)
            }
            @router.DropFilter(id, incarnation, subscription_id, filter) => {
              if broker.policy_session_incarnation(id) != Some(incarnation) ||
                broker.policy_subscription_identity(id, filter) !=
                Some(subscription_id) {
                ignore(scan.complete_issue(issue))
                continue
              }
              bootstrap_local_policy_change(
                store,
                broker,
                generations,
                id,
                @router.DropSubscription(filter.value()),
              )
            }
            @router.DropPending(
              id,
              incarnation,
              revision,
              index,
              topic,
              qos,
              size
            ) => {
              if broker.policy_session_incarnation(id) != Some(incarnation) ||
                broker.policy_session_revision(id) != Some(revision) {
                ignore(scan.complete_issue(issue))
                continue
              }
              bootstrap_local_policy_change(
                store,
                broker,
                generations,
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
    let finished : @persistence.WalPolicyRecord = {
      transition: @persistence.PolicyReconciled,
      sequence: committed.sequence,
      fingerprint,
    }
    let encoded = @persistence.encode_wal_policy_record(finished).unwrap()
    append_policy_payload(store, encoded)
  }
  let final_policy = store.policy_state().unwrap()
  let result : Array[@persistence.WalSessionIdentity] = []
  for id, generation in generations {
    result.push({ client_id: id.value(), generation })
  }
  {
    committed_lsn: store.committed_lsn(),
    identities: result,
    policy: final_policy,
  }
}

///|
async fn bootstrap_local_policy_change(
  store : @persistence.WalStore,
  broker : @router.BrokerState,
  generations : Map[@session.ClientId, Int64],
  id : @session.ClientId,
  change : @router.DurablePolicyChange,
) -> Unit {
  let generation = match generations.get(id) {
    Some(value) => value
    None => raise ResourceStartupFailure("policy cleanup identity missing")
  }
  let plan = match broker.prepare_durable_reconcile(id, change, generation) {
    Ok(value) => value
    Err(_) => raise ResourceStartupFailure("policy cleanup prepare failed")
  }
  errdefer plan.cancel()
  let encoded = if store.uses_v5_schema() {
    let delta = match plan.delta_v5(@budget.monotonic_ms(), @async.now()) {
      Ok(value) => value
      Err(_) => raise ResourceStartupFailure("policy cleanup V5 delta failed")
    }
    match @persistence.encode_durable_delta_v5(delta) {
      Ok(value) => value
      Err(_) => raise ResourceStartupFailure("policy cleanup encode failed")
    }
  } else {
    match @persistence.encode_wal_reconcile(plan.delta()) {
      Ok(value) => value
      Err(_) => raise ResourceStartupFailure("policy cleanup encode failed")
    }
  }
  append_policy_payload(store, encoded)
  broker.begin_action_scope()
  let result = plan.commit()
  broker.end_action_scope()
  if result is Err(_) {
    raise ResourceStartupFailure("policy cleanup apply failed")
  }
}

///|
/// Keep startup error categories visible across the opaque server package
/// boundary without leaking paths, credentials, or WAL payloads.
pub async fn bootstrap_strict_policy_checked(
  store : @persistence.WalStore,
  broker : @router.BrokerState,
  identities : Array[@persistence.WalSessionIdentity],
  policy : @security.SecurityPolicy,
  fingerprint : Bytes,
  max_items : Int,
  max_bytes : Int64,
) -> Result[StrictPolicyBootstrap, String] {
  Ok(
    bootstrap_strict_policy(
      store, broker, identities, policy, fingerprint, max_items, max_bytes,
    ),
  ) catch {
    ResourceStartupFailure(message) => Err(message)
    _ => Err("policy_bootstrap_failed")
  }
}
