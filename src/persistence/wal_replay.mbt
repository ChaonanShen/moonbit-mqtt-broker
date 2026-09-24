///|
pub struct WalRecoveredState {
  state : @router.BrokerState
  identities : Array[WalSessionIdentity]
  policy : WalPolicyState?
  policy_required : Bool
  committed_lsn : Int64
}

///|
pub fn WalRecoveredState::state(
  self : WalRecoveredState,
) -> @router.BrokerState {
  self.state
}

///|
pub fn WalRecoveredState::identities(
  self : WalRecoveredState,
) -> Array[WalSessionIdentity] {
  self.identities.copy()
}

///|
pub fn WalRecoveredState::committed_lsn(self : WalRecoveredState) -> Int64 {
  self.committed_lsn
}

///|
pub fn WalRecoveredState::policy(self : WalRecoveredState) -> WalPolicyState? {
  self.policy
}

///|
pub fn WalRecoveredState::policy_required(self : WalRecoveredState) -> Bool {
  self.policy_required
}

///|
pub fn WalRecovery::restore_state(
  self : WalRecovery,
  broker_config : @router.BrokerConfig,
  limits : SnapshotDecodeLimits,
  max_delta_bytes? : Int = 4194304,
) -> Result[WalRecoveredState, PersistenceError] {
  let initial = self.checkpoint
  let generations = initial.identities.map(item => item.generation)
  let accumulator = match
    @router.DurableAccumulator::new(
      broker_config,
      initial.snapshot,
      generations,
    ) {
    Ok(value) => value
    Err(_) => return Err(SnapshotImport("invalid WAL checkpoint state"))
  }
  let mut expected_lsn = initial.lsn
  let mut policy = initial.policy
  for batch in self.batches {
    if batch.previous_lsn != expected_lsn {
      return Err(InvalidValue(field="wal-replay-lsn", offset=0))
    }
    for transaction in batch.transactions {
      if expected_lsn == 9223372036854775807L ||
        transaction.lsn != expected_lsn + 1L {
        return Err(InvalidValue(field="wal-replay-lsn", offset=0))
      }
      if is_wal_policy_record(transaction.delta) {
        if !self.policy_required {
          return Err(InvalidValue(field="wal-policy-capability", offset=0))
        }
        let record = match decode_wal_policy_record(transaction.delta) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        policy = match apply_policy_record(policy, record) {
          Ok(value) => Some(value)
          Err(error) => return Err(error)
        }
      } else {
        let delta = match
          decode_durable_delta(
            transaction.delta,
            limits,
            max_bytes=max_delta_bytes,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        match accumulator.apply(delta) {
          Ok(_) => ()
          Err(_) => return Err(SnapshotImport("invalid WAL delta state"))
        }
      }
      expected_lsn = transaction.lsn
    }
  }
  if expected_lsn != self.committed_lsn {
    return Err(InvalidValue(field="wal-replay-final-lsn", offset=0))
  }
  let (snapshot, generations) = accumulator.export_snapshot()
  let identities : Array[WalSessionIdentity] = []
  for index in 0..<snapshot.sessions.length() {
    identities.push({
      client_id: snapshot.sessions[index].client_id,
      generation: generations[index],
    })
  }
  let state = match
    @router.BrokerState::from_snapshot(broker_config, snapshot) {
    Ok(value) => value
    Err(_) => return Err(SnapshotImport("WAL state exceeds configured limits"))
  }
  Ok({
    state,
    identities,
    policy,
    policy_required: self.policy_required,
    committed_lsn: expected_lsn,
  })
}
