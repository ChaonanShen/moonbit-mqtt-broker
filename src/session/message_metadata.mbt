///|
pub(all) struct MessageMetadata {
  payload_format : Int?
  content_type : String?
  response_topic : @topic.TopicName?
  correlation_data : Bytes?
  user_properties : Array[(String, String)]
  publisher_client_id : ClientId?
  expiry : Deadline?
} derive(Eq, Debug)

///|
pub fn MessageMetadata::empty() -> MessageMetadata {
  {
    payload_format: None,
    content_type: None,
    response_topic: None,
    correlation_data: None,
    user_properties: [],
    publisher_client_id: None,
    expiry: None,
  }
}

///|
pub fn MessageMetadata::copy(self : MessageMetadata) -> MessageMetadata {
  {
    payload_format: self.payload_format,
    content_type: self.content_type,
    response_topic: self.response_topic,
    correlation_data: self.correlation_data.map(value => {
      copy_session_bytes(value)
    }),
    user_properties: self.user_properties.copy(),
    publisher_client_id: self.publisher_client_id,
    expiry: self.expiry,
  }
}

///|
pub fn MessageMetadata::cost(self : MessageMetadata) -> Int64 {
  let mut cost = 0L
  if self.payload_format is Some(_) {
    cost += 8L
  }
  if self.content_type is Some(value) {
    cost = @budget.checked_add(cost, 32L + @budget.utf8_bytes(value) * 2L).unwrap()
  }
  if self.response_topic is Some(value) {
    cost = @budget.checked_add(
      cost,
      32L + @budget.utf8_bytes(value.value()) * 2L,
    ).unwrap()
  }
  if self.correlation_data is Some(value) {
    cost = @budget.checked_add(cost, 24L + value.length().to_int64()).unwrap()
  }
  if self.user_properties.length() > 0 {
    cost = @budget.checked_add(
      cost,
      24L + self.user_properties.length().to_int64() * 8L,
    ).unwrap()
    for entry in self.user_properties {
      let (key, value) = entry
      cost = @budget.checked_add(
        cost,
        32L +
        (32L + @budget.utf8_bytes(key) * 2L) +
        (32L + @budget.utf8_bytes(value) * 2L),
      ).unwrap()
    }
  }
  if self.publisher_client_id is Some(value) {
    cost = @budget.checked_add(
      cost,
      32L + @budget.utf8_bytes(value.value()) * 2L,
    ).unwrap()
  }
  if self.expiry is Some(_) {
    cost = @budget.checked_add(cost, 96L).unwrap()
  }
  cost
}

///|
pub fn MessageMetadata::is_empty(self : MessageMetadata) -> Bool {
  self.payload_format is None &&
  self.content_type is None &&
  self.response_topic is None &&
  self.correlation_data is None &&
  self.user_properties.is_empty() &&
  self.publisher_client_id is None &&
  self.expiry is None
}
