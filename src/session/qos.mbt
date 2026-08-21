///|
pub(all) enum DeliveryQoS {
  QoS0
  QoS1
} derive(Eq, Hash, Debug)

///|
pub fn min_qos(left : DeliveryQoS, right : DeliveryQoS) -> DeliveryQoS {
  match left {
    QoS0 => QoS0
    QoS1 => right
  }
}

///|
pub fn max_qos(left : DeliveryQoS, right : DeliveryQoS) -> DeliveryQoS {
  match left {
    QoS1 => QoS1
    QoS0 => right
  }
}
