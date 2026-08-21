///|
pub struct BrokerState {
  config : BrokerConfig
  priv sessions : Map[@session.ClientId, @session.ClientSession]
  priv subscriptions : SubscriptionIndex
  priv retained : RetainedStore
}

///|
pub fn BrokerState::new(config : BrokerConfig) -> BrokerState {
  {
    config,
    sessions: Map([]),
    subscriptions: SubscriptionIndex::new(),
    retained: RetainedStore::new(),
  }
}

///|
pub fn BrokerState::session_count(self : BrokerState) -> Int {
  self.sessions.length()
}

///|
pub fn BrokerState::subscription_count(self : BrokerState) -> Int {
  self.subscriptions.subscription_count()
}

///|
pub fn BrokerState::retained_count(self : BrokerState) -> Int {
  self.retained.count()
}

///|
pub fn BrokerState::has_session(
  self : BrokerState,
  client_id : @session.ClientId,
) -> Bool {
  self.sessions.get(client_id) is Some(_)
}

///|
pub fn BrokerState::subscription_qos(
  self : BrokerState,
  client_id : @session.ClientId,
  filter : @topic.TopicFilter,
) -> @session.DeliveryQoS? {
  self.subscriptions.qos(client_id, filter)
}

///|
pub fn BrokerState::retained_message(
  self : BrokerState,
  topic : @topic.TopicName,
) -> RetainedMessage? {
  self.retained.get(topic)
}

///|
fn BrokerState::deliveries(
  self : BrokerState,
  input : PublishInput,
  retain : Bool,
) -> Array[BrokerAction] {
  let actions : Array[BrokerAction] = []
  for subscription in self.subscriptions.matches(input.topic) {
    actions.push(
      Deliver({
        recipient: subscription.client_id,
        topic: input.topic,
        payload: copy_bytes(input.payload),
        qos: @session.min_qos(input.qos, subscription.qos),
        retain,
      }),
    )
  }
  actions
}

///|
pub fn BrokerState::apply(
  self : BrokerState,
  event : BrokerEvent,
) -> Result[Array[BrokerAction], RouterError] {
  match event {
    CreateSession(client_id) => {
      if self.sessions.get(client_id) is Some(_) {
        return Err(SessionAlreadyExists(client_id))
      }
      self.sessions.set(client_id, @session.ClientSession::new(client_id))
      Ok([SessionCreated(client_id)])
    }
    RemoveSession(client_id) => {
      if self.sessions.get(client_id) is None {
        return Err(SessionNotFound(client_id))
      }
      ignore(self.subscriptions.remove_all(client_id))
      self.sessions.remove(client_id)
      Ok([SessionRemoved(client_id)])
    }
    Subscribe(request) => {
      let client_id = request.client_id
      let entries = request.entries
      if self.sessions.get(client_id) is None {
        return Err(SessionNotFound(client_id))
      }
      if entries.length() == 0 {
        return Err(EmptySubscriptionRequest)
      }
      let results : Array[SubscribeResult] = []
      let successful : Array[@topic.TopicFilter] = []
      for entry in entries {
        let existing = self.subscriptions.qos(client_id, entry.filter)
        if existing is None &&
          self.subscriptions.subscription_count_for(client_id) >=
          self.config.max_subscriptions_per_session {
          results.push(RejectedLimit(SubscriptionsPerSession))
        } else if existing is None &&
          self.subscriptions.subscription_count() >=
          self.config.max_subscriptions_total {
          results.push(RejectedLimit(SubscriptionsTotal))
        } else {
          ignore(self.subscriptions.put(client_id, entry.filter, entry.qos))
          results.push(Granted(entry.qos))
          successful.push(entry.filter)
        }
      }
      let actions : Array[BrokerAction] = [
        SubscriptionsApplied({ client_id, results }),
      ]
      for message in self.retained.matching(successful) {
        for subscription in self.subscriptions.matches(message.topic) {
          if subscription.client_id == client_id {
            actions.push(
              Deliver({
                recipient: client_id,
                topic: message.topic,
                payload: message.payload,
                qos: @session.min_qos(message.qos, subscription.qos),
                retain: true,
              }),
            )
          }
        }
      }
      Ok(actions)
    }
    Unsubscribe(request) => {
      let client_id = request.client_id
      let filters = request.filters
      if self.sessions.get(client_id) is None {
        return Err(SessionNotFound(client_id))
      }
      if filters.length() == 0 {
        return Err(EmptyUnsubscriptionRequest)
      }
      let removed : Array[Bool] = []
      for filter in filters {
        removed.push(self.subscriptions.remove(client_id, filter))
      }
      Ok([UnsubscriptionsApplied({ client_id, removed })])
    }
    Publish(input) => {
      if input.retain &&
        input.payload.length() > 0 &&
        self.retained.get(input.topic) is None &&
        self.retained.count() >= self.config.max_retained_messages {
        return Err(RetainedLimitReached(self.config.max_retained_messages))
      }
      if input.retain {
        if input.payload.length() == 0 {
          self.retained.remove(input.topic)
        } else {
          ignore(
            self.retained.put(
              input.topic,
              input.payload,
              input.qos,
              self.config.max_retained_messages,
            ),
          )
        }
      }
      Ok(self.deliveries(input, false))
    }
  }
}

///|
pub fn BrokerState::check_invariants(
  self : BrokerState,
) -> Result[Unit, RouterError] {
  if !self.subscriptions.check_invariants() {
    return Err(InvariantViolation("subscription index is inconsistent"))
  }
  if self.subscriptions.subscription_count() >
    self.config.max_subscriptions_total ||
    self.retained.count() > self.config.max_retained_messages {
    return Err(InvariantViolation("resource limit exceeded"))
  }
  Ok(())
}
