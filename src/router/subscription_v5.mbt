///|
fn BrokerState::subscribe_v5(
  self : BrokerState,
  request : SubscribeV5Request,
) -> Result[Array[BrokerAction], RouterError] {
  let client_id = request.client_id
  if self.sessions.get(client_id) is None {
    return Err(SessionNotFound(client_id))
  }
  if request.entries.is_empty() {
    return Err(EmptySubscriptionRequest)
  }
  let original_usage = self.resources.owners.get(client_id).unwrap().usage
  let originals : Map[@topic.TopicFilter, SubscriptionBinding?] = Map([])
  let results : Array[SubscribeResult] = []
  let replay_filters : Array[@topic.TopicFilter] = []
  let persistent = self.session_is_persistent(client_id)
  let mut changed = false
  for entry in request.entries {
    if entry.filter.value().has_prefix("$share/") {
      results.push(RejectedSharedUnsupported)
      continue
    }
    let existing = self.subscriptions.binding(client_id, entry.filter)
    if originals.get(entry.filter) is None {
      originals.set(entry.filter, existing)
    }
    if existing is None &&
      self.subscriptions.subscription_count_for(client_id) >=
      self.config.max_subscriptions_per_session() {
      results.push(RejectedLimit(SubscriptionsPerSession))
      continue
    }
    if existing is None &&
      self.subscriptions.subscription_count() >=
      self.config.max_subscriptions_total() {
      results.push(RejectedLimit(SubscriptionsTotal))
      continue
    }
    if existing is None {
      let usage = self.resources.owners.get(client_id).unwrap().usage
      let next = {
        ..usage,
        subscriptions: usage.subscriptions +
        @budget.subscription_cost(entry.filter.value()),
      }
      if self.resources.set_usages(Map([(client_id, next)])) is Err(_) {
        results.push(RejectedLimit(Bytes))
        continue
      }
    }
    let prior = existing
    ignore(
      self.subscriptions.put_v5(
        client_id,
        entry.filter,
        entry.qos,
        entry.no_local,
        entry.retain_as_published,
        entry.retain_handling,
        entry.subscription_identifier,
      ),
    )
    if prior != self.subscriptions.binding(client_id, entry.filter) {
      changed = true
    }
    results.push(Granted(entry.qos))
    if entry.retain_handling == 0 ||
      (entry.retain_handling == 1 && existing is None) {
      replay_filters.push(entry.filter)
    }
  }
  let candidates : Array[DeliveryCandidate] = []
  for message in self.retained.matching_for_router(replay_filters) {
    for
      match_item in self.subscriptions.matches_v5(
        message.topic,
        message.metadata.publisher_client_id,
        true,
        retained_replay=true,
      ) {
      if match_item.client_id == client_id {
        candidates.push({
          recipient: client_id,
          topic: message.topic,
          payload: message.payload,
          qos: @session.min_qos(message.qos, match_item.qos),
          retain: true,
          metadata: message.metadata.copy(),
          subscription_identifiers: match_item.subscription_identifiers.copy(),
        })
      }
    }
  }
  let prepared = match self.preflight_deliveries(candidates, true) {
    Ok(planned) => self.prepare_deliveries(planned)
    Err(error) => Err(error)
  }
  let prepared = match prepared {
    Ok(value) => value
    Err(error) => {
      for filter, prior in originals {
        match prior {
          Some(binding) =>
            self.subscriptions.restore_binding(client_id, binding)
          None => ignore(self.subscriptions.remove(client_id, filter))
        }
      }
      ignore(self.resources.set_usages(Map([(client_id, original_usage)])))
      return Err(error)
    }
  }
  let actions : Array[BrokerAction] = [
    SubscriptionsApplied({ client_id, results }),
  ]
  let delivery_changed = prepared.inflight_added > 0 ||
    prepared.pending_added > 0
  actions.append(self.install_deliveries(prepared))
  if self.admin_sessions is Some(index) {
    for filter, prior in originals {
      if prior is None && self.subscriptions.qos(client_id, filter) is Some(_) {
        index.register_subscription(client_id, filter)
      }
    }
  }
  if changed {
    self.sessions.get(client_id).unwrap().subscription_changed()
  }
  if persistent && (changed || delivery_changed) {
    self.mark_snapshot_dirty()
  }
  Ok(actions)
}
