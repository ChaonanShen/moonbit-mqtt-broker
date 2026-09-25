///|
fn mqtt5_will_template(
  will : @protocol.WillV5,
  client_id : @session.ClientId,
) -> Result[@router.Mqtt5WillTemplate, Int] {
  let topic = match @topic.TopicName::new(will.topic) {
    Ok(value) => value
    Err(_) => return Err(0x82)
  }
  let mut payload_format : Int? = None
  let mut content_type : String? = None
  let mut response_topic : @topic.TopicName? = None
  let mut correlation_data : Bytes? = None
  let user_properties : Array[(String, String)] = []
  let mut delay_seconds = 0U
  let mut message_expiry_seconds : UInt? = None
  for property in will.properties {
    match (property.id, property.value) {
      (0x01, @protocol.ByteValue(value)) => payload_format = Some(value)
      (0x02, @protocol.FourByteValue(value)) =>
        message_expiry_seconds = Some(value)
      (0x03, @protocol.StringValue(value)) => content_type = Some(value)
      (0x08, @protocol.StringValue(value)) =>
        match @topic.TopicName::new(value) {
          Ok(topic) => response_topic = Some(topic)
          Err(_) => return Err(0x82)
        }
      (0x09, @protocol.BinaryValue(value)) => correlation_data = Some(value)
      (0x18, @protocol.FourByteValue(value)) => delay_seconds = value
      (0x26, @protocol.StringPair(key, value)) =>
        user_properties.push((key, value))
      _ => ()
    }
  }
  let metadata : @session.MessageMetadata = {
    payload_format,
    content_type,
    response_topic,
    correlation_data,
    user_properties,
    publisher_client_id: Some(client_id),
    expiry: None,
  }
  Ok({
    topic,
    payload: Bytes::from_array(will.payload.to_array()),
    qos: match will.qos {
      QoS0 => @session.QoS0
      QoS1 => @session.QoS1
      QoS2 => @session.QoS2
    },
    retain: will.retain,
    metadata,
    delay_seconds,
    message_expiry_seconds,
  })
}

///|
fn BrokerRuntime::prepare_v5_will(
  self : BrokerRuntime,
  plan : PreparedMqtt5Connect,
  client_id : @session.ClientId,
  principal : @security.Principal,
) -> Result[@router.PreparedMqtt5Will?, Int] {
  let will = match plan.will {
    None => return Ok(None)
    Some(value) => value
  }
  let template = match mqtt5_will_template(will, client_id) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  if !self.security.can_write_topic(principal, template.topic) {
    self.metrics.record_acl_denial()
    return Err(0x87)
  }
  match
    self.broker_state.prepare_mqtt5_will(
      client_id,
      principal,
      template,
      self.config.protocol_config().max_delayed_wills,
      self.policy_epoch,
    ) {
    Ok(value) => Ok(Some(value))
    Err(_) => Err(0x97)
  }
}
