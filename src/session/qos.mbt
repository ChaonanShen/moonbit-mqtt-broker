///|
pub(all) enum DeliveryQoS {
  QoS0
  QoS1
  QoS2
} derive(Eq, Hash, Debug)

///|
pub fn min_qos(left : DeliveryQoS, right : DeliveryQoS) -> DeliveryQoS {
  match (left, right) {
    (QoS0, _) | (_, QoS0) => QoS0
    (QoS1, _) | (_, QoS1) => QoS1
    (QoS2, QoS2) => QoS2
  }
}

///|
pub fn max_qos(left : DeliveryQoS, right : DeliveryQoS) -> DeliveryQoS {
  match (left, right) {
    (QoS2, _) | (_, QoS2) => QoS2
    (QoS1, _) | (_, QoS1) => QoS1
    (QoS0, QoS0) => QoS0
  }
}
